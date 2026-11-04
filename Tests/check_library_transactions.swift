// Run with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_library_transactions.swift
// Uses production models/services with a temporary on-disk SwiftData store.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
let app = try read("OfflineMusic/OfflineMusicApp.swift")
let management = try read("OfflineMusic/LibraryManagement.swift")
let catalog = try read("OfflineMusic/MusicCatalog.swift")
let importer = try read("OfflineMusic/FolderImporter.swift")
let views = try read("OfflineMusic/Views.swift")
let importerBase = String(views[views.range(of: "@MainActor\nenum Importer")!.lowerBound...])
func between(_ text: String, _ start: String, _ end: String) -> String {
    String(text[text.range(of: start)!.lowerBound..<text.range(of: end)!.lowerBound])
}
let models = between(app, "@Model final class Song", "enum LibraryStore")
let genres = between(management, "@MainActor", "struct SongGenreEditorView")
let duplicateLogic = between(management, "enum DuplicateKind", "struct DuplicateManagerView")
let service = String(management[management.range(of: "@MainActor\nenum DuplicateLibraryStore")!.lowerBound...])
let catalogLogic = between(catalog, "@MainActor", "struct GenreLibraryView")
let audioMetadata = between(importer, "enum AudioMetadata", "struct MusicImportJob")
let importLogic = String(importer[importer.range(of: "struct MusicImportJob")!.lowerBound...])
let support = #"""
enum LibraryStore {
    static let musicURL = FileManager.default.temporaryDirectory.appendingPathComponent("library-test-" + UUID().uuidString, isDirectory: true)
}
@MainActor final class AudioPlayer {
    var current: Song?
    var queue: [Song] = []
    var replacements: [UUID: UUID] = [:]
    func reconcileDuplicates(songs: [Song], replacements: [UUID: UUID], previousCurrentID: UUID?, previousQueueIDs: [UUID]) {
        self.replacements = replacements
        let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        current = previousCurrentID.flatMap { lookup[replacements[$0] ?? $0] }
        queue = previousQueueIDs.compactMap { lookup[replacements[$0] ?? $0] }
    }
}
"""#
let checks = #"""
try await Task { @MainActor in
    let fm = FileManager.default
    try fm.createDirectory(at: LibraryStore.musicURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: LibraryStore.musicURL) }
    let config = ModelConfiguration(url: LibraryStore.musicURL.appendingPathComponent("test.store"))
    let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
    let context = container.mainContext
    let original = MusicGenre(name: "Rock")
    context.insert(original)
    let a = Song(title: "Song", artist: "Artist", album: "Album", duration: 123, fileName: "a.mp3", importedGenre: "Rock")
    let b = Song(title: "Song", artist: "Artist", album: "Album", duration: 123, fileName: "b.mp3", importedGenre: "Rock")
    for song in [a, b] {
        song.genreMetadataLoaded = true
        song.originalGenreIDs = [original.id]
        song.genreIDs = [original.id]
        context.insert(song)
        try Data("identical music bytes".utf8).write(to: LibraryStore.musicURL.appendingPathComponent(song.fileName))
    }
    try context.save()
    try SongGenreStore.apply(a, genreName: "Custom Genre", context: context)
    precondition(a.importedGenre == "Rock" && b.genreIDs == [original.id])
    precondition(a.genreOverrideID != nil && a.genreIDs != b.genreIDs)
    let fresh = ModelContext(container)
    let saved = try fresh.fetch(FetchDescriptor<Song>()).first { $0.fileName == "a.mp3" }!
    precondition(saved.genreOverrideID == a.genreOverrideID && saved.importedGenre == "Rock")
    try SongGenreStore.restore(a, context: context)
    precondition(a.genreOverrideID == nil && a.genreIDs == [original.id])

    a.isFavorite = true
    let removedID = a.id, keptID = b.id
    let playlist = Playlist(name: "Manual")
    playlist.songIDs = [removedID, keptID]
    context.insert(playlist)
    try context.save()
    func record(_ song: Song) -> DuplicateSongRecord {
        DuplicateSongRecord(id: song.id, title: song.title, artist: song.artist, album: song.album, duration: song.duration, fileName: song.fileName, path: LibraryStore.musicURL.appendingPathComponent(song.fileName).path, fileSize: Int64(Data("identical music bytes".utf8).count), fileFormat: "MP3")
    }
    let group = DuplicateGroup(kind: .exact, records: [record(a), record(b)])
    let player = AudioPlayer()
    player.current = a
    player.queue = [a, b]
    let count = try DuplicateLibraryStore.delete(groups: [group], removalIDs: [removedID], keepIDs: [group.id: keptID], context: context, player: player)
    precondition(count == 1 && playlist.songIDs == [keptID] && b.isFavorite)
    precondition(player.current?.id == keptID && player.replacements[removedID] == keptID)
    precondition(!fm.fileExists(atPath: LibraryStore.musicURL.appendingPathComponent("a.mp3").path))
    precondition(fm.fileExists(atPath: LibraryStore.musicURL.appendingPathComponent("b.mp3").path))
    let remainingCount = try context.fetchCount(FetchDescriptor<Song>())
    precondition(remainingCount == 1)

    // Simulate termination after moving a file but before committing the database.
    let transaction = LibraryStore.musicURL.appendingPathComponent(".duplicate-removals/interrupted", isDirectory: true)
    try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
    try Data(#"{"fileNames":["b.mp3"]}"#.utf8).write(to: transaction.appendingPathComponent("receipt.json"))
    try fm.moveItem(at: LibraryStore.musicURL.appendingPathComponent("b.mp3"), to: transaction.appendingPathComponent("b.mp3"))
    try DuplicateLibraryStore.recover(in: context)
    precondition(fm.fileExists(atPath: LibraryStore.musicURL.appendingPathComponent("b.mp3").path), "Uncommitted deletion must restore the original file")
    // Recover a fully copied audio file, while discarding only an unpublished partial copy.
    var wave = Data()
    func text(_ value: String) { wave.append(Data(value.utf8)) }
    func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
    func dword(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
    text("RIFF"); dword(16036); text("WAVEfmt "); dword(16); word(1); word(1); dword(8000); dword(16000); word(2); word(16); text("data"); dword(16000)
    wave.append(Data(repeating: 0, count: 16000))
    let staging = LibraryStore.musicURL.appendingPathComponent(".imports", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    let ready = MusicImportJob(fileName: "resume-source.wav", originalName: "source.wav", ready: true)
    try JSONEncoder().encode(ready).write(to: staging.appendingPathComponent("resume.json"))
    try wave.write(to: staging.appendingPathComponent("resume.partial-source.wav"))
    let pending = MusicImportJob(fileName: "pending-source.wav", originalName: "source.wav")
    try JSONEncoder().encode(pending).write(to: staging.appendingPathComponent("pending.json"))
    try Data([0, 1]).write(to: staging.appendingPathComponent("pending.partial-source.wav"))
    try await Importer.recoverInterruptedImports(context: context)
    let imported = try context.fetch(FetchDescriptor<Song>())
    precondition(imported.count == 2 && imported.contains { $0.fileName == ready.fileName })
    precondition(!fm.fileExists(atPath: staging.appendingPathComponent("pending.partial-source.wav").path))
    try await Importer.recoverInterruptedImports(context: context)
    let countAfterRetry = try context.fetchCount(FetchDescriptor<Song>())
    precondition(countAfterRetry == 2, "Recovery must not insert duplicate records")
    print("PASS: persisted independent genres, restore, reference transfer, interrupted deletion recovery and idempotent import recovery")
}.value
"""#
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
let code = "import Foundation\nimport SwiftData\nimport AVFoundation\nimport CryptoKit\nimport UniformTypeIdentifiers\n" + [models, support, catalogLogic, audioMetadata, genres, duplicateLogic, service, importerBase, importLogic, checks].joined(separator: "\n")
try pipe.fileHandleForWriting.write(contentsOf: Data(code.utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
