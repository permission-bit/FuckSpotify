import Foundation
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

enum AudioMetadata {
    static func trackNumber(at url: URL) async throws -> Int? {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        for identifier: AVMetadataIdentifier in [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber] {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue), let number = Int(value.split(separator: "/").first.map(String.init) ?? ""), number > 0 { return number }
            }
        }
        return nil
    }

    static func validateTransfer(at url: URL, size: Int64, sha256: String, duration: Double) async throws {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard DuplicateScanner.fileSize(at: url.path) == size,
                  DuplicateScanner.streamingHash(at: url.path) == sha256 else { throw CocoaError(.fileReadCorruptFile) }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.processingFormat.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { throw CocoaError(.fileReadCorruptFile) }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let formats = try await track.load(.formatDescriptions)
        guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEGLayer3 }) else { throw CocoaError(.fileReadCorruptFile) }
        let actualDuration = try await asset.load(.duration).seconds
        guard actualDuration.isFinite, actualDuration > 0, abs(actualDuration - duration) <= 2 else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func genre(at url: URL) async throws -> String {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        let identifiers: [AVMetadataIdentifier] = [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre, .quickTimeUserDataGenre, .iTunesMetadataPredefinedGenre]
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
        }
        return ""
    }
}

struct MusicImportJob: Codable {
    let fileName: String
    let originalName: String
    var ready = false
    var expectedSHA256: String?
    var expectedSize: Int64?
    var expectedDuration: Double?
    var remoteMetadata: [String: String]?
}

extension Importer {
    private static var activeJobs = Set<String>()
    private static var stagingURL: URL { LibraryStore.musicURL.appendingPathComponent(".imports", isDirectory: true) }

    @discardableResult static func stageAndImport(_ source: URL, context: ModelContext, fileName: String? = nil,
        expectedSHA256: String? = nil, expectedSize: Int64? = nil, expectedDuration: Double? = nil, metadata: [String: String]? = nil) async throws -> Song {
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let key = UUID().uuidString
        let receipt = stagingURL.appendingPathComponent(key + ".json")
        let partial = stagingURL.appendingPathComponent(key + ".partial-" + source.lastPathComponent)
        var job = MusicImportJob(fileName: fileName ?? key + "-" + source.lastPathComponent, originalName: source.lastPathComponent)
        guard URL(fileURLWithPath: job.fileName).lastPathComponent == job.fileName, !job.fileName.hasPrefix(".") else { throw CocoaError(.fileWriteInvalidFileName) }
        job.expectedSHA256 = expectedSHA256; job.expectedSize = expectedSize; job.expectedDuration = expectedDuration; job.remoteMetadata = metadata
        activeJobs.insert(key)
        defer { activeJobs.remove(key) }
        try JSONEncoder().encode(job).write(to: receipt, options: .atomic)
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: partial)
        }.value
        job.ready = true
        try JSONEncoder().encode(job).write(to: receipt, options: .atomic)
        return try await finishImport(job, receipt: receipt, partial: partial, context: context)
    }

    static func recoverInterruptedImports(context: ModelContext) async throws {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return }
        for receipt in try FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) where receipt.pathExtension == "json" {
            let key = receipt.deletingPathExtension().lastPathComponent
            guard !activeJobs.contains(key), let data = try? Data(contentsOf: receipt), let job = try? JSONDecoder().decode(MusicImportJob.self, from: data) else { continue }
            let partial = stagingURL.appendingPathComponent(key + ".partial-" + job.originalName)
            if !job.ready {
                // Only an unpublished, interrupted copy is discarded; originals remain untouched.
                if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
                try FileManager.default.removeItem(at: receipt)
                continue
            }
            _ = try? await finishImport(job, receipt: receipt, partial: partial, context: context)
        }
    }

    @discardableResult private static func finishImport(_ job: MusicImportJob, receipt: URL, partial: URL, context: ModelContext) async throws -> Song {
        let destination = LibraryStore.musicURL.appendingPathComponent(job.fileName)
        let fileName = job.fileName
        let audioURL = FileManager.default.fileExists(atPath: destination.path) ? destination : partial
        if let hash = job.expectedSHA256, let size = job.expectedSize, let duration = job.expectedDuration {
            try await AudioMetadata.validateTransfer(at: audioURL, size: size, sha256: hash, duration: duration)
        }
        if let existing = try context.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.fileName == fileName })).first {
            try Task.checkCancellation()
            if audioURL == partial { try FileManager.default.moveItem(at: partial, to: destination) }
            try context.save()
            try FileManager.default.removeItem(at: receipt)
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            return existing
        }
        let asset = AVURLAsset(url: audioURL)
        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ identifier: AVMetadataIdentifier) async -> String {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return "" }
            return (try? await item.load(.stringValue)) ?? ""
        }
        let embeddedTitle = await value(.commonIdentifierTitle)
        let embeddedArtist = await value(.commonIdentifierArtist)
        let embeddedAlbum = await value(.commonIdentifierAlbumName)
        let embeddedGenre = (try? await AudioMetadata.genre(at: audioURL)) ?? ""
        let title = job.remoteMetadata?["title"] ?? embeddedTitle
        let artist = job.remoteMetadata?["artist"] ?? embeddedArtist
        let album = job.remoteMetadata?["album"] ?? embeddedAlbum
        let genre = job.remoteMetadata?["genre"] ?? embeddedGenre
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var artwork: Data?
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first { artwork = try? await item.load(.dataValue) }
        let song = Song(title: title.isEmpty ? URL(fileURLWithPath: job.originalName).deletingPathExtension().lastPathComponent : title, artist: artist.isEmpty ? "Unbekannter Künstler" : artist, album: album.isEmpty ? "Unbekanntes Album" : album, duration: duration.isFinite ? duration : 0, fileName: fileName, artworkData: artwork, importedGenre: genre)
        song.genreMetadataLoaded = true
        let embeddedTrack = try? await AudioMetadata.trackNumber(at: audioURL)
        song.trackNumber = job.remoteMetadata?["track"].flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") } ?? embeddedTrack
        var genres = try context.fetch(FetchDescriptor<MusicGenre>())
        if !genre.isEmpty, !genres.contains(where: { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(genre) }) {
            let created = MusicGenre(name: genre)
            context.insert(created)
            genres.append(created)
        }
        MusicCatalog.classify(song, artists: try context.fetch(FetchDescriptor<ArtistProfile>()), genres: genres)
        try Task.checkCancellation()
        if audioURL == partial { try FileManager.default.moveItem(at: partial, to: destination) }
        context.insert(song)
        try context.save()
        try FileManager.default.removeItem(at: receipt)
        return song
    }

    static func importFolders(_ result: Result<[URL], Error>, context: ModelContext) async {
        guard case .success(let urls) = result else { return }
        for url in urls { await importFolder(.success([url]), context: context) }
    }

    static func importFolder(_ result: Result<[URL], Error>, context: ModelContext) async {
        guard case .success(let urls) = result, let folder = urls.first else { return }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.compactMap { item -> URL? in
            guard let url = item as? URL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { return nil }
            return url
        } ?? []
        await Importer.importFiles(.success(files), context: context)
    }
}
