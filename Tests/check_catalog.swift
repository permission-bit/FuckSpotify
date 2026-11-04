// Run with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift Tests/check_catalog.swift
// Exercises the actual persisted models and catalog logic using an in-memory store.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = try String(contentsOf: root.appendingPathComponent("OfflineMusic/OfflineMusicApp.swift"), encoding: .utf8)
let catalog = try String(contentsOf: root.appendingPathComponent("OfflineMusic/MusicCatalog.swift"), encoding: .utf8)
let models = String(app[app.range(of: "@Model final class Song")!.lowerBound..<app.range(of: "enum LibraryStore")!.lowerBound])
let logic = String(catalog[catalog.range(of: "@MainActor")!.lowerBound..<catalog.range(of: "struct GenreLibraryView")!.lowerBound])
let checks = #"""
try MainActor.assumeIsolated {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
    let context = container.mainContext
    try MusicCatalog.seed(in: context)
    let artists = try context.fetch(FetchDescriptor<ArtistProfile>())
    let genres = try context.fetch(FetchDescriptor<MusicGenre>())
    precondition(genres.count == 15)
    precondition(artists.count > 60)
    let eminem = artists.first { $0.name == "Eminem" }!
    let hiphop = genres.first { $0.name == "Hip-Hop" }!

    let tagged = Song(title: "Lose Yourself", artist: "EMINEM", fileName: "song.mp3")
    MusicCatalog.classify(tagged, artists: artists)
    precondition(tagged.artistIDs == [eminem.id] && tagged.genreIDs == [hiphop.id])

    let file = Song(title: "Track", fileName: "Queen - Bohemian Rhapsody.mp3")
    MusicCatalog.classify(file, artists: artists)
    precondition(file.artist == "Queen" && !file.genreIDs.isEmpty)

    let alias = Song(title: "Changes", artist: "2Pac", fileName: "track.mp3")
    MusicCatalog.classify(alias, artists: artists)
    precondition(alias.artistIDs.contains(artists.first { $0.name == "Tupac Shakur" }!.id))

    let falseMatch = Song(title: "Across the universe", fileName: "acrobat.mp3")
    MusicCatalog.classify(falseMatch, artists: artists)
    precondition(falseMatch.artistIDs.isEmpty, "Cro must not match inside another word")

    let collaboration = Song(title: "Track", artist: "Eminem feat. Snoop Dogg", fileName: "track.mp3")
    MusicCatalog.classify(collaboration, artists: artists)
    precondition(collaboration.artistIDs.count == 2 && collaboration.genreIDs == [hiphop.id])

    let uploader = Song(title: "ACDC - Thunderstruck", artist: "Music Channel", fileName: "track.mp3")
    MusicCatalog.classify(uploader, artists: artists)
    precondition(!uploader.artistIDs.isEmpty)
    precondition(MusicCatalog.containsName("Sven Väth", in: "SVEN VATH - Live"))

    let customGenre = MusicGenre(name: "Mein Genre")
    context.insert(customGenre)
    let custom = ArtistProfile(name: "Mein Künstler", genreID: customGenre.id)
    context.insert(custom)
    let customSong = Song(title: "Mein Künstler - Song", fileName: "local.mp3")
    context.insert(customSong)
    context.insert(tagged)
    try MusicCatalog.reclassify(in: context)
    precondition(customSong.genreIDs == [customGenre.id])
    eminem.genreID = customGenre.id
    try MusicCatalog.seed(in: context)
    precondition(tagged.genreIDs == [customGenre.id], "User assignments must survive reseeding")
    let savedArtists = try context.fetch(FetchDescriptor<ArtistProfile>())
    let savedGenres = try context.fetch(FetchDescriptor<MusicGenre>())
    precondition(savedArtists.count == artists.count + 1)
    precondition(savedGenres.count == genres.count + 1)
    print("PASS: catalog seeding, aliases, filename recognition, boundaries, collaborations, custom genres and reclassification")
}
"""#
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
let source = "import Foundation\nimport SwiftData\n" + models + logic + checks
try pipe.fileHandleForWriting.write(contentsOf: Data(source.utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
