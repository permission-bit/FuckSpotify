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

    let fieldArtist = ArtistProfile(name: "Test Musiker", aliases: ["TÉST ALIAS"], genreID: hiphop.id)
    context.insert(fieldArtist)
    let albumMatch = Song(title: "Ein Song", artist: "Music Channel", album: "test alias – COLLECTION", fileName: "album.mp3")
    fieldArtist.matchFields = ["album"]
    MusicCatalog.classify(albumMatch, artists: [fieldArtist])
    precondition(albumMatch.artistIDs == [fieldArtist.id], "Album matching must normalize case, accents and punctuation")
    fieldArtist.matchFields = ["title"]
    MusicCatalog.classify(albumMatch, artists: [fieldArtist])
    precondition(albumMatch.artistIDs.isEmpty, "Disabled fields must not contribute matches")
    let titleMatch = Song(title: "TEST MUSIKER - Live", artist: "Queen", fileName: "title.mp3")
    MusicCatalog.classify(titleMatch, artists: [fieldArtist] + artists)
    precondition(titleMatch.artistIDs.contains(fieldArtist.id), "An existing artist metadata match must not hide a title match")
    let artistPlaylist = Playlist(name: "Test Playlist", artistName: "TEST MUSIKER")
    precondition(MusicCatalog.tracks(in: artistPlaylist, songs: [titleMatch, albumMatch], artists: [fieldArtist]).map(\.id) == [titleMatch.id])
    let manualPlaylist = Playlist(name: "Manual")
    manualPlaylist.songIDs = [albumMatch.id, titleMatch.id]
    precondition(MusicCatalog.tracks(in: manualPlaylist, songs: [titleMatch, albumMatch], artists: []).map(\.id) == manualPlaylist.songIDs)
    try context.save()
    let savedFieldArtist = try context.fetch(FetchDescriptor<ArtistProfile>()).first { $0.id == fieldArtist.id }
    precondition(savedFieldArtist?.matchFields == ["title"])
    context.delete(fieldArtist)
    try context.save()

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
    print("PASS: catalog seeding, normalization, configurable match fields, playlist membership/order, aliases, custom genres and reclassification")
}

@MainActor func checkArtistWrites() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: config)
    let context = container.mainContext
    let song = Song(title: "Maria Studio – Live", artist: "Uploader", fileName: "live.mp3")
    let other = Song(title: "Maria Studio – Live", artist: "Uploader", fileName: "second.mp3")
    let manualGenre = MusicGenre(name: "Manual")
    let manualPlaylist = Playlist(name: "Manual")
    other.genreOverrideID = manualGenre.id
    for song in [song, other] { context.insert(song) }
    context.insert(manualGenre)
    context.insert(manualPlaylist)

    let edit = MusicCatalog.ArtistEdit(id: nil, name: "María Studio", aliases: [], fields: ["title"], genreID: nil, newGenre: "Live", createPlaylist: true)
    try await CatalogUpdates.write(in: context) {
        precondition(!Thread.isMainThread, "Catalog writes must run off the main thread")
        try MusicCatalog.saveArtist(edit, in: $0)
    }
    let reader = ModelContext(container)
    let artist = try reader.fetch(FetchDescriptor<ArtistProfile>()).first!
    let tracks = try reader.fetch(FetchDescriptor<Song>())
    let playlists = try reader.fetch(FetchDescriptor<Playlist>())
    precondition(artist.name == "María Studio" && tracks.count == 2)
    precondition(tracks.allSatisfy { $0.artistIDs == [artist.id] })
    precondition(tracks.first { $0.id == song.id }?.genreIDs == [artist.genreID!])
    precondition(tracks.first { $0.id == other.id }?.genreIDs == [manualGenre.id])
    precondition(playlists.count == 2 && playlists.contains { $0.id == manualPlaylist.id && $0.artistName.isEmpty })
    precondition(playlists.contains { $0.artistName == artist.name })
    precondition(MusicCatalog.trackCounts(in: tracks, by: \.artistIDs)[artist.id] == 2)

    let rename = MusicCatalog.ArtistEdit(id: artist.id, name: "Studio Maria", aliases: [], fields: ["title"], genreID: artist.genreID, newGenre: "", createPlaylist: true)
    try await CatalogUpdates.write(in: context) { try MusicCatalog.saveArtist(rename, in: $0) }
    let refreshed = ModelContext(container)
    let renamedArtist = try refreshed.fetch(FetchDescriptor<ArtistProfile>()).first!
    let renamedPlaylists = try refreshed.fetch(FetchDescriptor<Playlist>())
    precondition(renamedArtist.aliases == ["María Studio"] && renamedPlaylists.count == 2)
    precondition(renamedPlaylists.contains { $0.artistName == "Studio Maria" })
    var savedUnchangedCatalog = false
    let observer = NotificationCenter.default.publisher(for: ModelContext.didSave, object: refreshed).sink { _ in savedUnchangedCatalog = true }
    defer { observer.cancel() }
    try MusicCatalog.reclassify(in: refreshed)
    precondition(!savedUnchangedCatalog, "A repeat classification should not save unchanged songs")

    let removeGenre = MusicCatalog.ArtistEdit(id: artist.id, name: "Studio Maria", aliases: ["María Studio"], fields: ["title"], genreID: nil, newGenre: "", createPlaylist: false)
    try await CatalogUpdates.write(in: context) { try MusicCatalog.saveArtist(removeGenre, in: $0) }
    let withoutGenre = ModelContext(container)
    let savedTracks = try withoutGenre.fetch(FetchDescriptor<Song>())
    precondition(savedTracks.allSatisfy { $0.artistIDs == [artist.id] && $0.inferredGenreIDs.isEmpty })
    precondition(savedTracks.first { $0.id == song.id }?.genreIDs == [])
    precondition(savedTracks.first { $0.id == other.id }?.genreIDs == [manualGenre.id])

    let removeMatch = MusicCatalog.ArtistEdit(id: artist.id, name: "Studio Maria", aliases: ["María Studio"], fields: ["album"], genreID: nil, newGenre: "", createPlaylist: false)
    try await CatalogUpdates.write(in: context) { try MusicCatalog.saveArtist(removeMatch, in: $0) }
    let unassignedTracks = try ModelContext(container).fetch(FetchDescriptor<Song>())
    precondition(unassignedTracks.allSatisfy(\.artistIDs.isEmpty), "Previously assigned songs must be updated when the new rule no longer matches")

    for name in ["☆", "!!!"] {
        let draft = MusicCatalog.ArtistEdit(id: nil, name: name, aliases: [], fields: [], genreID: nil, newGenre: "", createPlaylist: true)
        try await CatalogUpdates.write(in: context) { try MusicCatalog.saveArtist(draft, in: $0) }
    }
    let finalReader = ModelContext(container)
    let savedProfiles = try finalReader.fetch(FetchDescriptor<ArtistProfile>())
    let savedPlaylists = try finalReader.fetch(FetchDescriptor<Playlist>())
    for name in ["☆", "!!!"] {
        let profile = MusicCatalog.artistProfile(named: name, in: savedProfiles)
        precondition(profile?.name == name && profile?.genreID == nil)
        precondition(savedPlaylists.contains { $0.artistName == name })
    }
    print("PASS: background artist creation/rename, staged tracks, manual genre override and playlist reuse")
}

try await checkArtistWrites()
"""#
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", "-"]
let pipe = Pipe()
process.standardInput = pipe
try process.run()
let source = "import Foundation\nimport Combine\nimport SwiftData\n" + models + logic + checks
try pipe.fileHandleForWriting.write(contentsOf: Data(source.utf8))
try pipe.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
