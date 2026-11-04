// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_smart_playlists.swift
// Exercises production smart queries and model operations against an on-disk store.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = try String(contentsOf: root.appendingPathComponent("OfflineMusic/OfflineMusicApp.swift"), encoding: .utf8)
let smart = try String(contentsOf: root.appendingPathComponent("OfflineMusic/SmartPlaylists.swift"), encoding: .utf8)
let models = String(app[app.range(of: "@Model final class Song")!.lowerBound..<app.range(of: "enum LibraryStore")!.lowerBound])
let rules = String(smart[smart.range(of: "enum SmartPlaylistKind")!.lowerBound..<smart.range(of: "struct SmartPlaylistDetail")!.lowerBound])
let progress = String(app[app.range(of: "struct PlaybackHistoryProgress")!.lowerBound..<app.range(of: "struct PlaybackSession")!.lowerBound])
let checks = #"""
try MainActor.assumeIsolated {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = ModelConfiguration(url: directory.appendingPathComponent("library.store"))
    let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
    let context = container.mainContext
    for kind in SmartPlaylistKind.allCases { precondition(try context.fetch(kind.descriptor).isEmpty) }
    let tracks = ["a", "b", "c", "missing"].enumerated().map { index, name in
        let song = Song(title: name, duration: 100, fileName: name + ".mp3")
        song.addedAt = Date(timeIntervalSince1970: Double(index + 1) * 100)
        context.insert(song)
        return song
    }
    let a = tracks[0], b = tracks[1], c = tracks[2], missing = tracks[3]
    a.isFavorite = true
    a.registerPlayback(count: 3, at: Date(timeIntervalSince1970: 500))
    b.registerPlayback(at: Date(timeIntervalSince1970: 600))
    func ids(_ kind: SmartPlaylistKind) throws -> [UUID] { try context.fetch(kind.descriptor).map(\.id) }
    precondition(try ids(.recentlyPlayed) == [b.id, a.id])
    precondition(try ids(.neverPlayed) == [missing.id, c.id])
    precondition(try ids(.mostPlayed) == [a.id, b.id])
    precondition(try ids(.recentlyAdded) == [missing.id, c.id, b.id, a.id])
    precondition(try ids(.favorites) == [a.id])
    var state = PlaybackHistoryProgress(songID: c.id)
    precondition(!state.consume(29, duration: 100))
    if state.consume(1, duration: 100) { c.registerPlayback(at: Date(timeIntervalSince1970: 700)) }
    precondition(!state.consume(50, duration: 100), "One listening session must count only once")
    c.isFavorite = true
    precondition(try ids(.neverPlayed) == [missing.id])
    precondition(try ids(.mostPlayed) == [a.id, c.id, b.id])
    precondition(try ids(.favorites) == [a.id, c.id])
    precondition(a.addedAt == Date(timeIntervalSince1970: 100))
    var short = PlaybackHistoryProgress(songID: UUID())
    precondition(!short.consume(4.9, duration: 10) && short.consume(0.1, duration: 10))
    var invalid = PlaybackHistoryProgress(songID: UUID())
    precondition(!invalid.consume(.nan, duration: 0) && !invalid.consume(-1, duration: 0))

    let playlist = Playlist(name: "My playlist")
    context.insert(playlist)
    playlist.appendSongs([a.id, b.id, a.id, c.id])
    precondition(playlist.songIDs == [a.id, b.id, c.id])
    playlist.reorderSongs([c.id, a.id, b.id])
    playlist.appendSongs([b.id, missing.id, missing.id])
    precondition(playlist.songIDs == [c.id, a.id, b.id, missing.id])
    playlist.removeSongs([a.id, missing.id])
    precondition(playlist.songIDs == [c.id, b.id])
    let unknownID = UUID()
    playlist.appendSongs([unknownID])
    playlist.reorderSongs([b.id, c.id])
    precondition(playlist.songIDs == [b.id, c.id, unknownID], "Reordering must preserve unresolved associations")
    try context.save()
    let reopened = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
    let fresh = reopened.mainContext
    let savedPlaylist = try fresh.fetch(FetchDescriptor<Playlist>()).first!
    precondition(savedPlaylist.id == playlist.id && savedPlaylist.songIDs == [b.id, c.id, unknownID])
    let savedMost = try fresh.fetch(SmartPlaylistKind.mostPlayed.descriptor)
    precondition(savedMost.map(\.id) == [a.id, c.id, b.id] && savedMost[0].playCount == 3)
    let count = try fresh.fetchCount(FetchDescriptor<Song>())
    precondition(count == 4, "Smart playlists must not duplicate or delete tracks")
    print("PASS: all five smart queries, live membership/order updates, threshold rules, first-added dates, batch selection operations, unresolved IDs and persistence across store reopening")
}
"""#
// Swift's precondition autoclosure cannot throw; materialize each throwing check.
let adapted = checks.replacingOccurrences(of: "precondition(try ", with: "try check(try ")
let checkHelper = "func check(_ condition: @autoclosure () throws -> Bool) rethrows { let result = try condition(); precondition(result) }\n"
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe(); process.standardInput = pipe
try process.run()
let code = "import Foundation\nimport SwiftData\n" + [models, rules, progress, checkHelper, adapted].joined(separator: "\n")
try pipe.fileHandleForWriting.write(contentsOf: Data(code.utf8)); try pipe.fileHandleForWriting.close()
process.waitUntilExit(); exit(process.terminationStatus)
