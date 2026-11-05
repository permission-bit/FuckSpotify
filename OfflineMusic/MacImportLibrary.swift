import Foundation
import SwiftData

@MainActor enum MacImportLibrary {
    static func batchKey(scope: String, jobID: UUID) -> String { scope + "/" + jobID.uuidString }
    static func fileKey(batchKey: String, itemID: UUID, checksum: String) -> String { batchKey + "/" + itemID.uuidString + "/" + checksum }

    static func accept(_ page: MacDeliveryPage, scope: String, target: MacImportTarget, context: ModelContext, requestedTargets: [String: MacImportTarget] = [:]) throws {
        for delivery in page.deliveries {
            guard let manifest = delivery.item.result else { continue }
            try manifest.validate()
            let key = batchKey(scope: scope, jobID: delivery.job.id)
            let batch: MacImportBatch
            if let existing = try context.fetch(FetchDescriptor<MacImportBatch>(predicate: #Predicate { $0.key == key })).first { batch = existing }
            else {
                let name = delivery.item.playlist_title ?? manifest.metadata["album"] ?? "Mac-Import"
                let requested = delivery.job.request_id.flatMap { requestedTargets[$0.uuidString] } ?? target
                batch = try MacImportBatch(key: key, scope: scope, job: delivery.job, title: name.isEmpty ? "Mac-Import" : name, target: requested)
                context.insert(batch)
            }
            batch.jobData = try JSONEncoder().encode(delivery.job); batch.updatedAt = .now
            let receiptKey = fileKey(batchKey: key, itemID: delivery.item.id, checksum: manifest.sha256)
            if try context.fetchCount(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.key == receiptKey })) == 0 {
                context.insert(try MacImportedFile(key: receiptKey, batchKey: key, item: delivery.item, checksum: manifest.sha256))
            }
        }
        // Commit receipts BEFORE advancing the separately atomic feed cursor.
        try context.save()
    }

    static func attach(_ song: Song, receipt: MacImportedFile, batch: MacImportBatch, context: ModelContext) throws {
        let playlist: Playlist
        switch batch.target {
        case .library: return
        case .automatic:
            guard (batch.job?.total_items ?? 0) > 1 || receipt.item?.playlist_title != nil || batch.job?.request_id != nil else { return }
            let id = batch.automaticPlaylistID
            if let existing = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first { playlist = existing }
            else {
                guard !batch.playlistWasCreated else { throw MacImportError.missingPlaylist }
                playlist = Playlist(name: batch.title); playlist.id = id
                context.insert(playlist); batch.playlistWasCreated = true
            }
        case .playlist(let id):
            guard let existing = try context.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first else { throw MacImportError.missingPlaylist }
            playlist = existing
        }
        let batchKey = batch.key
        let receipts = try context.fetch(FetchDescriptor<MacImportedFile>(predicate: #Predicate { $0.batchKey == batchKey }, sortBy: [SortDescriptor(\.position)]))
        let order = receipts.compactMap { $0.key == receipt.key ? song.id : $0.songID }
        playlist.songIDs = MacPlaylistOrder.inserting([song.id], desired: order, into: playlist.songIDs)
    }

    static func freeSpace(for manifest: MacAudioManifest, at directory: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < manifest.size * 3 + 20 * 1024 * 1024 { throw MacImportError.noSpace }
    }
}

// Size buckets are built once per import pass. Hashes use the existing streaming
// duplicate scanner and are cached only while the observed file stays unchanged.
struct MacDuplicateIndex: Sendable {
    private var bySize: [Int64: [DuplicateSongRecord]] = [:]
    private var byMetadata: [String: [DuplicateSongRecord]] = [:]
    private var hashes: [UUID: String] = [:]
    init(_ records: [DuplicateSongRecord]) {
        bySize = Dictionary(grouping: records, by: \.fileSize)
        for record in records {
            if let key = DuplicateScanner.metadataKey(for: record) { byMetadata[key, default: []].append(record) }
        }
    }
    mutating func match(_ manifest: MacAudioManifest, incoming: DuplicateSongRecord) throws -> (UUID?, Bool) {
        for record in bySize[manifest.size] ?? [] {
            try Task.checkCancellation()
            guard record.isUnchanged else { continue }
            let hash = hashes[record.id] ?? DuplicateScanner.streamingHash(at: record.path)
            if let hash { hashes[record.id] = hash }
            if hash == manifest.sha256, record.isUnchanged { return (record.id, false) }
        }
        let key = DuplicateScanner.metadataKey(for: incoming)
        let possible = (key.flatMap { byMetadata[$0] } ?? []).contains {
            $0.isAvailable && abs($0.duration - incoming.duration) <= 2
        }
        return (nil, possible)
    }
    mutating func add(_ record: DuplicateSongRecord, checksum: String) {
        bySize[record.fileSize, default: []].append(record); hashes[record.id] = checksum
        if let key = DuplicateScanner.metadataKey(for: record) { byMetadata[key, default: []].append(record) }
    }
}

actor MacDuplicateLookup {
    private var index: MacDuplicateIndex?
    private let inputs: [DuplicateSongInput]
    init(inputs: [DuplicateSongInput]) { self.inputs = inputs }
    func match(_ manifest: MacAudioManifest, incoming: DuplicateSongRecord) throws -> (UUID?, Bool) {
        if index == nil {
            index = MacDuplicateIndex(inputs.compactMap { input in
                guard let size = DuplicateScanner.fileSize(at: input.path) else { return nil }
                let date = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.modificationDate] as? Date
                return DuplicateSongRecord(id: input.id, title: input.title, artist: input.artist, album: input.album,
                    duration: input.duration, fileName: input.fileName, path: input.path, fileSize: size,
                    fileFormat: URL(fileURLWithPath: input.fileName).pathExtension, modifiedAt: date)
            })
        }
        return try index!.match(manifest, incoming: incoming)
    }
    func add(_ record: DuplicateSongRecord, checksum: String) { index?.add(record, checksum: checksum) }
}
