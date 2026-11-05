// Production import/coordinator integration. All data lives in the runner's temporary library.
import Foundation
import SwiftData

@main struct MacImportChecks {
    @MainActor static func settled(_ importer: MacImportCoordinator) async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        let deadline = Date().addingTimeInterval(25)
        while importer.isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!importer.isBusy, "Import did not settle")
    }
    @MainActor static func main() async throws {
        let credentials = try JSONDecoder().decode(MacCredentials.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = LibraryStore.musicURL
        let configuration = ModelConfiguration(url: root.appendingPathComponent("library.store"))
        // Open the store created with the PREVIOUS production model/schema.
        let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self,
            MacImportBatch.self, MacImportedFile.self, configurations: configuration)
        func context() -> ModelContext { let c = ModelContext(container); c.autosaveEnabled = false; return c }
        let before = context()
        precondition(tryCount(before, Song.self) == 2 && tryCount(before, Playlist.self) == 1)
        let directory = root.appendingPathComponent(".transfer-state")
        let importer = MacImportCoordinator(directory: directory)
        importer.attach(container); importer.setAutomatic(false); importer.setConnection(credentials); importer.setActive(true)
        importer.refresh(); await settled(importer)
        precondition(importer.message == nil, importer.message ?? "")
        var check = context()
        let songs = try check.fetch(FetchDescriptor<Song>())
        precondition(songs.count == 3, "One exact duplicate must reuse the manually edited original")
        let original = songs.first { $0.fileName == "manual.mp3" }!
        precondition(original.title == "My edited name" && original.artist == "Manual artist" && original.isFavorite)
        precondition(original.importedGenre == "Original genre" && original.genreOverrideID != nil)
        let added = songs.first { $0.fileName.hasPrefix("mac-") }!
        precondition(added.title == "Second local fixture" && added.artist == "Fixture Artist" && added.album == "Transfer fixture")
        precondition(added.importedGenre == "Rock" && added.trackNumber == 3 && added.duration > 0 && added.artworkData?.isEmpty == false)
        let playlists = try check.fetch(FetchDescriptor<Playlist>())
        let automatic = playlists.first { $0.name == "Transfer fixture" }!
        let autoID = automatic.id
        precondition(automatic.songIDs == [original.id, added.id])
        precondition(importer.summaries.first?.imported == 1 && importer.summaries.first?.reused == 1)
        print("PASS: old library migration, real HTTPS download, metadata/cover/track number, exact duplicate reuse and automatic playlist order")

        let batch = try check.fetch(FetchDescriptor<MacImportBatch>()).first!
        let batchKey = batch.key
        let manual = playlists.first { $0.name == "Manual order" }!
        let manualID = manual.id
        let originalOrder = manual.songIDs
        importer.assign(batchKey: batchKey, target: .playlist(manualID))
        check = context()
        let assigned = try check.fetch(FetchDescriptor<Playlist>()).first { $0.id == manualID }!
        precondition(assigned.songIDs == originalOrder + [added.id])
        assigned.songIDs = [added.id] + originalOrder
        try check.save()
        // A repeated explicit attachment must read the latest user order.
        importer.assign(batchKey: batchKey, target: .playlist(manualID))
        var fresh = context()
        precondition(try! fresh.fetch(FetchDescriptor<Playlist>()).first { $0.id == manualID }!.songIDs == [added.id] + originalOrder)
        fresh = context()
        let edited = try fresh.fetch(FetchDescriptor<Playlist>()).first { $0.id == manualID }!
        edited.songIDs = originalOrder // User removes the newly imported membership.
        try fresh.save()
        importer.setActive(false)
        let journal = MacImportJournal(directory: directory)
        var settings = try journal.load(); settings.cursors = [:]; try journal.save(settings)
        let restarted = MacImportCoordinator(directory: directory)
        restarted.attach(container); restarted.setConnection(credentials); restarted.setActive(true); restarted.refresh()
        await settled(restarted)
        precondition(restarted.message == nil, restarted.message ?? "")
        fresh = context()
        precondition(tryCount(fresh, Song.self) == 3 && tryCount(fresh, Playlist.self) == 2)
        precondition(try! fresh.fetch(FetchDescriptor<Playlist>()).first { $0.id == manualID }!.songIDs == originalOrder)
        precondition(try! fresh.fetch(FetchDescriptor<Playlist>()).contains { $0.id == autoID })
        print("PASS: existing-playlist import, manual reorder/removal preserved, app restart and repeated delivery without duplicate songs/playlists")

        // Late successes are inserted between surviving neighbours; existing IDs never move.
        let a = UUID(), b = UUID(), c = UUID(), manualTrack = UUID()
        precondition(MacPlaylistOrder.inserting([a, b], desired: [a, b, c], into: [manualTrack, c]) == [manualTrack, a, b, c])
        precondition(MacPlaylistOrder.inserting([b], desired: [a, b, c], into: [c, a]) == [c, a, b])
        let manifest = try JSONDecoder().decode(MacAudioManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let good = root.appendingPathComponent("manual.mp3")
        let bad = root.appendingPathComponent("corrupt-test.mp3")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(64).write(to: bad)
        do { try await AudioMetadata.validateTransfer(at: bad, size: manifest.size, sha256: manifest.sha256, duration: manifest.duration); preconditionFailure("Truncated audio must fail") } catch { }
        var changed = bytes; changed[changed.startIndex] ^= 1; try changed.write(to: bad)
        do { try await AudioMetadata.validateTransfer(at: bad, size: manifest.size, sha256: manifest.sha256, duration: manifest.duration); preconditionFailure("Checksum mismatch must fail") } catch { }
        do { try await AudioMetadata.validateTransfer(at: good, size: manifest.size, sha256: manifest.sha256, duration: manifest.duration + 20); preconditionFailure("Duration mismatch must fail") } catch { }
        let huge = MacAudioManifest(format: "mp3", duration: 2, size: Int64.max, sha256: manifest.sha256, metadata: [:])
        do { try huge.validate(); preconditionFailure("Oversized manifest must fail") } catch { }
        try FileManager.default.removeItem(at: bad)
        precondition(tryCount(context(), Song.self) == 3)
        print("PASS: partial-playlist ordering, missing library files, truncation, checksum mismatch and invalid audio properties leave existing music intact")

        // Persist a pending item and an already verified download, as on app termination.
        fresh = context()
        let receipt = try fresh.fetch(FetchDescriptor<MacImportedFile>()).first { $0.checksum == manifest.sha256 }!
        receipt.state = "pending"; receipt.songID = nil; try fresh.save()
        let staged = try journal.stagingURL(receipt.stagingName)
        restarted.setActive(false)
        let offline = MacImportCoordinator(api: FailingDownloadAPI(error: .unavailable), directory: directory)
        offline.attach(container); offline.setConnection(credentials); offline.setActive(true); offline.refresh()
        await settled(offline)
        precondition(offline.summaries.first?.pending == 1 && offline.message != nil)
        precondition(tryCount(context(), Song.self) == 3)
        offline.setActive(false)
        let full = MacImportCoordinator(api: FailingDownloadAPI(error: .noSpace), directory: directory)
        full.attach(container); full.setConnection(credentials); full.setActive(true); full.refresh()
        await settled(full)
        precondition(full.summaries.first?.failed == 1 && full.message == MacImportError.noSpace.localizedDescription)
        precondition(FileManager.default.fileExists(atPath: good.path) && tryCount(context(), Song.self) == 3)
        full.setActive(false); full.retry(batchKey: batchKey)
        print("PASS: network interruption stays pending; storage failure is reported and leaves all existing files intact")
        try FileManager.default.copyItem(at: good, to: staged)
        let resumed = MacImportCoordinator(api: DownloadForbiddenAPI(), directory: directory)
        resumed.attach(container); resumed.setConnection(credentials); resumed.setActive(true); resumed.refresh()
        await settled(resumed)
        precondition(resumed.message == nil, resumed.message ?? "")
        precondition(resumed.summaries.first?.pending == 0 && tryCount(context(), Song.self) == 3)
        precondition(!FileManager.default.fileExists(atPath: staged.path))
        resumed.setActive(false)
        print("PASS: verified staged transfer resumes after restart without downloading or duplicating audio")
        let brokenState = root.appendingPathComponent("broken-state")
        try FileManager.default.createDirectory(at: brokenState, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: brokenState.appendingPathComponent("settings.json"))
        let blocked = MacImportCoordinator(directory: brokenState)
        blocked.attach(container); blocked.setConnection(credentials); blocked.setActive(true); blocked.refresh()
        precondition(blocked.message == MacImportError.stateUnavailable.localizedDescription && !blocked.isBusy)
        blocked.setActive(false)
        print("PASS: corrupted import settings fail closed instead of resetting delivery history")

        let uiImporter = MacImportCoordinator(directory: directory)
        uiImporter.attach(container); uiImporter.setConnection(credentials); uiImporter.setActive(true)
        let hub = ImportHubStore()
        hub.connect(credentials); await hub.loadSources()
        precondition(hub.sources.count == 2 && hub.sources.allSatisfy(\.importable))
        hub.toggle(hub.sources[1]); hub.toggle(hub.sources[0])
        let ordered = hub.selection
        precondition(ordered.map(\.id) == hub.sources.map(\.id), "Tap order must not change original source order")
        await hub.submit(quality: "128K", target: .playlist(manualID), importer: uiImporter)
        guard let submitted = hub.submittedJob, let requestID = submitted.request_id else { preconditionFailure(hub.message ?? "UI submission failed") }
        let repeated = try await MacCompanionAPI().submit(credentials, sources: ordered, quality: "128K", requestID: requestID)
        precondition(repeated.id == submitted.id)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let job = try await MacCompanionAPI().jobInfo(credentials, jobID: submitted.id)
            if !job.isRunning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        uiImporter.refresh(); await settled(uiImporter)
        precondition(uiImporter.message == nil, uiImporter.message ?? "")
        check = context()
        precondition(tryCount(check, Song.self) == 3 && tryCount(check, Playlist.self) == 2,
                     "The requested existing playlist must win over the global automatic-playlist default")
        let submittedBatch = try check.fetch(FetchDescriptor<MacImportBatch>()).first { $0.jobID == submitted.id }!
        precondition(submittedBatch.target == .playlist(manualID))
        let jobDetails = MacJobDetailsStore(job: submitted, credentials: credentials)
        await jobDetails.refresh()
        precondition(jobDetails.items.map(\.position) == [1, 2] && jobDetails.items.allSatisfy { $0.status == "reused" || $0.status == "completed" })
        uiImporter.setActive(false)
        print("PASS: native import UI API, source multi-selection order, persistent target-before-submit, request-id replay and per-title job progress")
        try await checkImportHubStores(credentials)
    }
    @MainActor static func tryCount<T: PersistentModel>(_ context: ModelContext, _ type: T.Type) -> Int { try! context.fetchCount(FetchDescriptor<T>()) }
}

struct DownloadForbiddenAPI: MacTransferNetworking {
    func deliveries(_ credentials: MacCredentials, after: Int64) async throws -> MacDeliveryPage { try await MacCompanionAPI().deliveries(credentials, after: after) }
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo { try await MacCompanionAPI().jobInfo(credentials, jobID: jobID) }
    func download(_ credentials: MacCredentials, jobID: UUID, itemID: UUID, manifest: MacAudioManifest, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws { preconditionFailure("Verified staged files must not be downloaded again") }
}

struct FailingDownloadAPI: MacTransferNetworking {
    enum Failure: Sendable { case unavailable, noSpace }
    let error: Failure
    func deliveries(_ credentials: MacCredentials, after: Int64) async throws -> MacDeliveryPage { try await MacCompanionAPI().deliveries(credentials, after: after) }
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo { try await MacCompanionAPI().jobInfo(credentials, jobID: jobID) }
    func download(_ credentials: MacCredentials, jobID: UUID, itemID: UUID, manifest: MacAudioManifest, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch error { case .unavailable: throw MacConnectionError.unavailable; case .noSpace: throw MacImportError.noSpace }
    }
}
