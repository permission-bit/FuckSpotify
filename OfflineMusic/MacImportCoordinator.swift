import Foundation
import SwiftData
import Combine

struct MacImportSummary: Identifiable {
    let id: String
    let title: String
    let imported: Int
    let reused: Int
    let pending: Int
    let failed: Int
    let remoteFailed: Int
    let running: Bool
    let message: String?
}

@MainActor final class MacImportCoordinator: ObservableObject {
    @Published private(set) var automatic = true
    @Published private(set) var target: MacImportTarget = .automatic
    @Published private(set) var summaries: [MacImportSummary] = []
    @Published private(set) var isBusy = false
    @Published private(set) var currentTitle: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String?
    private let api: any MacTransferNetworking
    private let journal: MacImportJournal
    private var settings = MacImportSettings()
    private var readableState = true
    private var context: ModelContext?
    private var credentials: MacCredentials?
    private var active = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var currentFileKey: String?

    init(api: any MacTransferNetworking = MacCompanionAPI(), directory: URL? = nil) {
        self.api = api
        journal = MacImportJournal(directory: directory ?? LibraryStore.musicURL.appendingPathComponent(".mac-transfers", isDirectory: true))
        do { settings = try journal.load(); automatic = settings.automatic; target = settings.target }
        catch { readableState = false; message = error.localizedDescription }
    }
    func attach(_ container: ModelContainer) {
        guard context == nil else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        self.context = context
        refreshSummaries(); restart()
    }
    func setConnection(_ value: MacCredentials?) {
        guard credentials != value else { return }
        stop(); credentials = value; refreshSummaries(); restart()
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value; if value { restart() } else { stop() }
    }
    func setAutomatic(_ value: Bool) {
        var updated = settings; updated.automatic = value
        do { try journal.save(updated); settings = updated; automatic = value; if value { restart() } else { stop() } }
        catch { message = error.localizedDescription }
    }
    func setTarget(_ value: MacImportTarget) {
        var updated = settings; updated.target = value
        do { try journal.save(updated); settings = updated; target = value }
        catch { message = error.localizedDescription }
    }
    func refresh() { restart(manual: true) }
    func prepareSubmission(_ requestID: UUID, target: MacImportTarget) throws {
        guard readableState else { throw MacImportError.stateUnavailable }
        var updated = settings
        var requests = updated.requestedTargets ?? [:]; requests[requestID.uuidString] = target
        updated.requestedTargets = requests
        try journal.save(updated); settings = updated
    }
    private var scope: String? {
        credentials.map { MacFingerprint.hash(Data(($0.fingerprint + ":" + $0.deviceID.uuidString).utf8)) }
    }
    private func stop() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false; currentTitle = nil; currentFileKey = nil; progress = 0
    }
    private func restart(manual: Bool = false) {
        guard readableState, active, let credentials, let scope, context != nil, automatic || manual else { return }
        stop()
        let generation = generation
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.active, self.generation == generation else { return }
            repeat {
                self.isBusy = true
                do { try await self.synchronize(credentials, scope: scope, generation: generation); self.message = nil }
                catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.message = self.describe(error)
                }
                guard !Task.isCancelled, self.generation == generation else { return }
                self.isBusy = false; self.currentTitle = nil; self.progress = 0; self.refreshSummaries()
                guard self.automatic else { return }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            } while self.active && self.generation == generation
        }
    }

    private func synchronize(_ credentials: MacCredentials, scope: String, generation: UUID) async throws {
        guard let container = context?.container else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        self.context = context
        // At most 50 new files per pass. The durable cursor advances only after
        // their SwiftData receipts have committed, including partial Mac jobs.
        for _ in 0..<5 {
            let cursor = settings.cursors[scope] ?? 0
            let page = try await api.deliveries(credentials, after: cursor)
            try check(generation)
            do { try MacImportLibrary.accept(page, scope: scope, target: target, context: context, requestedTargets: settings.requestedTargets ?? [:]) }
            catch { context.rollback(); throw error }
            var updated = settings; updated.cursors[scope] = page.next_after
            for delivery in page.deliveries {
                if let id = delivery.job.request_id { updated.requestedTargets?.removeValue(forKey: id.uuidString) }
            }
            try journal.save(updated); settings = updated
            if !page.has_more { break }
        }
        let songs = try context.fetch(FetchDescriptor<Song>())
        let lookup = MacDuplicateLookup(inputs: songs.map { song in
            DuplicateSongInput(id: song.id, title: song.title, artist: song.artist, album: song.album, duration: song.duration,
                fileName: song.fileName, path: LibraryStore.musicURL.appendingPathComponent(song.fileName).path)
        })
        let batches = try context.fetch(FetchDescriptor<MacImportBatch>(predicate: #Predicate { $0.scope == scope }, sortBy: [SortDescriptor(\.updatedAt)]))
        for batch in batches {
            try check(generation)
            if batch.job?.isRunning == true {
                let latest = try await api.jobInfo(credentials, jobID: batch.jobID)
                try check(generation)
                batch.jobData = try JSONEncoder().encode(latest); try context.save()
            }
            let batchKey = batch.key
            let receipts = try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.batchKey == batchKey && $0.state == "pending" }, sortBy: [SortDescriptor(\.position)]))
            for receipt in receipts {
                try check(generation)
                do { try await importFile(receipt, batch: batch, credentials: credentials, lookup: lookup, generation: generation) }
                catch {
                    if Task.isCancelled || self.generation != generation { throw CancellationError() }
                    let key = receipt.key
                    context.rollback()
                    let retryable = error as? MacConnectionError == .unavailable || error as? MacConnectionError == .server(429)
                    if let stored = try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.key == key })).first {
                        stored.state = retryable ? "pending" : "failed"; stored.message = describe(error); try context.save()
                    }
                    refreshSummaries()
                    // Stop on network/auth/storage failure instead of failing
                    // every remaining title or hammering an unavailable server.
                    if retryable || error as? MacConnectionError == .identity || error as? MacConnectionError == .unauthorized || isNoSpace(error) { throw error }
                }
            }
        }
    }

    private func importFile(_ receipt: MacImportedFile, batch: MacImportBatch, credentials: MacCredentials,
                            lookup: MacDuplicateLookup, generation: UUID) async throws {
        guard let context, let item = receipt.item, let manifest = item.result else { throw MacImportError.invalidManifest }
        try manifest.validate()
        currentTitle = manifest.metadata["title"] ?? item.title ?? "Musikdatei"; progress = 0
        let fileKey = receipt.key
        currentFileKey = fileKey
        let staged = try journal.stagingURL(receipt.stagingName)
        var verified = false
        if FileManager.default.fileExists(atPath: staged.path) {
            do { try await AudioMetadata.validateTransfer(at: staged, size: manifest.size, sha256: manifest.sha256, duration: manifest.duration); verified = true }
            catch {
                try check(generation)
                try FileManager.default.removeItem(at: staged) // Only this owned, unpublished download.
            }
        }
        if !verified {
            try MacImportLibrary.freeSpace(for: manifest, at: journal.directory)
            try await api.download(credentials, jobID: batch.jobID, itemID: item.id, manifest: manifest, destination: staged) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.currentFileKey == fileKey else { return }
                    self.progress = value
                }
            }
            try check(generation)
            try await AudioMetadata.validateTransfer(at: staged, size: manifest.size, sha256: manifest.sha256, duration: manifest.duration)
        }
        try check(generation)
        let incoming = DuplicateSongRecord(id: UUID(), title: manifest.metadata["title"] ?? item.title ?? "",
            artist: manifest.metadata["artist"] ?? "", album: manifest.metadata["album"] ?? "", duration: manifest.duration,
            fileName: staged.lastPathComponent, path: staged.path, fileSize: manifest.size, fileFormat: "MP3")
        let (duplicateID, possible) = try await lookup.match(manifest, incoming: incoming)
        try check(generation)
        var existing: Song?
        if let id = duplicateID { existing = try context.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.id == id })).first }
        let song: Song
        let reused: Bool
        if let existing { song = existing; reused = true }
        else {
            let filename = "mac-\(manifest.sha256).mp3"
            let alreadyExists = try context.fetchCount(FetchDescriptor<Song>(predicate: #Predicate { $0.fileName == filename })) > 0
            song = try await Importer.stageAndImport(staged, context: context, fileName: filename, expectedSHA256: manifest.sha256,
                expectedSize: manifest.size, expectedDuration: manifest.duration, metadata: manifest.metadata)
            reused = alreadyExists
        }
        try check(generation)
        // Read the latest saved playlist immediately before the synchronous
        // commit. A context retained across network awaits can contain an old
        // song order after a user has edited the playlist in another view.
        let transaction = ModelContext(context.container); transaction.autosaveEnabled = false
        let songID = song.id, receiptKey = receipt.key, batchKey = batch.key
        guard let savedSong = try transaction.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.id == songID })).first,
              let savedReceipt = try transaction.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.key == receiptKey })).first,
              let savedBatch = try transaction.fetch(FetchDescriptor<MacImportBatch>(predicate: #Predicate { $0.key == batchKey })).first else { throw MacImportError.stateUnavailable }
        try MacImportLibrary.attach(savedSong, receipt: savedReceipt, batch: savedBatch, context: transaction)
        savedReceipt.songID = savedSong.id; savedReceipt.state = reused ? "reused" : "imported"
        savedReceipt.message = possible && !reused ? "Mögliche Dublette erhalten. Du kannst die Versionen unter Bibliothek → Duplikate prüfen." : nil
        try transaction.save()
        progress = 1
        let path = LibraryStore.musicURL.appendingPathComponent(song.fileName)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        await lookup.add(DuplicateSongRecord(id: song.id, title: song.title, artist: song.artist, album: song.album,
            duration: song.duration, fileName: song.fileName, path: path.path, fileSize: manifest.size, fileFormat: "MP3", modifiedAt: modified), checksum: manifest.sha256)
        try? FileManager.default.removeItem(at: staged)
        refreshSummaries()
        // Stay below the companion's 120 requests/minute even for tiny tracks.
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func retry(batchKey: String) {
        guard let container = context?.container else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        do {
            for item in try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.batchKey == batchKey && $0.state == "failed" })) {
                item.state = "pending"; item.message = nil
            }
            try context.save(); refreshSummaries(); restart(manual: true)
        } catch { context.rollback(); message = describe(error) }
    }
    func assign(batchKey: String, target: MacImportTarget) {
        guard let container = context?.container, !isBusy else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        do {
            guard let batch = try context.fetch(FetchDescriptor<MacImportBatch>(predicate: #Predicate { $0.key == batchKey })).first else { return }
            batch.targetData = try JSONEncoder().encode(target)
            let files = try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.batchKey == batchKey }, sortBy: [SortDescriptor(\.position)]))
            for file in files where file.finished {
                if let id = file.songID, let song = try context.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.id == id })).first {
                    try MacImportLibrary.attach(song, receipt: file, batch: batch, context: context)
                }
            }
            try context.save(); message = nil
        } catch { context.rollback(); message = describe(error) }
    }
    private func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard active, self.generation == generation else { throw CancellationError() }
    }
    private func isNoSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return error as? MacImportError == .noSpace || ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue || ns.domain == NSPOSIXErrorDomain && ns.code == 28
    }
    private func describe(_ error: Error) -> String {
        if isNoSpace(error) { return MacImportError.noSpace.localizedDescription }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadCorruptFile { return MacImportError.damagedFile.localizedDescription }
        return error.localizedDescription
    }
    private func refreshSummaries() {
        guard let container = context?.container else { return }
        let context = ModelContext(container); context.autosaveEnabled = false
        do {
            var descriptor = FetchDescriptor<MacImportBatch>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            descriptor.fetchLimit = 30
            summaries = try context.fetch(descriptor).filter { scope == nil || $0.scope == scope }.map { batch in
                let key = batch.key
                let files = try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.batchKey == key }))
                return MacImportSummary(id: key, title: batch.title, imported: files.filter { $0.state == "imported" }.count,
                    reused: files.filter { $0.state == "reused" }.count, pending: files.filter { $0.state == "pending" }.count,
                    failed: files.filter { $0.state == "failed" }.count, remoteFailed: batch.job?.failedCount ?? 0,
                    running: batch.job?.isRunning ?? false, message: files.compactMap(\.message).first)
            }
        } catch { message = describe(error) }
    }
}
