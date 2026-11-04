import Foundation
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

enum AudioMetadata {
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
}

extension Importer {
    private static var activeJobs = Set<String>()
    private static var stagingURL: URL { LibraryStore.musicURL.appendingPathComponent(".imports", isDirectory: true) }

    static func stageAndImport(_ source: URL, context: ModelContext) async throws {
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let key = UUID().uuidString
        let receipt = stagingURL.appendingPathComponent(key + ".json")
        let partial = stagingURL.appendingPathComponent(key + ".partial-" + source.lastPathComponent)
        var job = MusicImportJob(fileName: key + "-" + source.lastPathComponent, originalName: source.lastPathComponent)
        activeJobs.insert(key)
        defer { activeJobs.remove(key) }
        try JSONEncoder().encode(job).write(to: receipt, options: .atomic)
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: partial)
        }.value
        job.ready = true
        try JSONEncoder().encode(job).write(to: receipt, options: .atomic)
        try await finishImport(job, receipt: receipt, partial: partial, context: context)
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
            try? await finishImport(job, receipt: receipt, partial: partial, context: context)
        }
    }

    private static func finishImport(_ job: MusicImportJob, receipt: URL, partial: URL, context: ModelContext) async throws {
        let destination = LibraryStore.musicURL.appendingPathComponent(job.fileName)
        let fileName = job.fileName
        if try context.fetch(FetchDescriptor<Song>(predicate: #Predicate { $0.fileName == fileName })).first != nil {
            try context.save()
            try FileManager.default.removeItem(at: receipt)
            return
        }
        let audioURL = FileManager.default.fileExists(atPath: destination.path) ? destination : partial
        let asset = AVURLAsset(url: audioURL)
        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ identifier: AVMetadataIdentifier) async -> String {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return "" }
            return (try? await item.load(.stringValue)) ?? ""
        }
        let title = await value(.commonIdentifierTitle)
        let artist = await value(.commonIdentifierArtist)
        let album = await value(.commonIdentifierAlbumName)
        let genre = (try? await AudioMetadata.genre(at: audioURL)) ?? ""
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var artwork: Data?
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first { artwork = try? await item.load(.dataValue) }
        let song = Song(title: title.isEmpty ? URL(fileURLWithPath: job.originalName).deletingPathExtension().lastPathComponent : title, artist: artist.isEmpty ? "Unbekannter Künstler" : artist, album: album.isEmpty ? "Unbekanntes Album" : album, duration: duration.isFinite ? duration : 0, fileName: fileName, artworkData: artwork, importedGenre: genre)
        song.genreMetadataLoaded = true
        var genres = try context.fetch(FetchDescriptor<MusicGenre>())
        if !genre.isEmpty, !genres.contains(where: { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(genre) }) {
            let created = MusicGenre(name: genre)
            context.insert(created)
            genres.append(created)
        }
        MusicCatalog.classify(song, artists: try context.fetch(FetchDescriptor<ArtistProfile>()), genres: genres)
        if audioURL == partial { try FileManager.default.moveItem(at: partial, to: destination) }
        context.insert(song)
        try context.save()
        try FileManager.default.removeItem(at: receipt)
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
