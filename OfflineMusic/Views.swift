import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct RootView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @EnvironmentObject private var player: AudioPlayer
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView().tabItem { Label("Home", systemImage: "house.fill") }
                LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }
                SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
                PlaylistsView().tabItem { Label("Playlists", systemImage: "rectangle.stack.fill") }
            }
            if player.current != nil {
                MiniPlayer()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 54)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil { Color.clear.frame(height: 64) }
        }
        .animation(.easeInOut(duration: 0.2), value: player.current?.id)
        .onAppear { player.setLibrary(songs) }
        .onChange(of: songs) { _, value in player.setLibrary(value) }
    }
}

struct HomeView: View {
    @Query(sort: \Song.addedAt, order: .reverse) private var songs: [Song]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: AudioPlayer
    @State private var showImporter = false
    @State private var importingFolder = false
    init() { _songs = Query(sort: \Song.addedAt, order: .reverse) }
    var body: some View { NavigationStack { List { Section("Recently Added") { ForEach(songs.prefix(10)) { SongRow(song: $0) } }.headerProminence(.increased); if !songs.isEmpty { Section("Favorites") { ForEach(songs.filter(\.isFavorite).prefix(5)) { SongRow(song: $0) } } } }.navigationTitle("Home").toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("Ordner importieren", systemImage: "folder") { importingFolder = true; showImporter = true }; Button("Dateien importieren", systemImage: "music.note") { importingFolder = false; showImporter = true } } label: { Image(systemName: "plus") } } }.fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder, .audio], allowsMultipleSelection: true) { result in if importingFolder { Importer.importFolders(result, context: context) } else { Importer.importFiles(result, context: context) } } } }
}

struct LibraryView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: AudioPlayer
    @State private var mode = 0
    init() { _songs = Query(sort: \Song.title) }
    var body: some View { NavigationStack { VStack { Picker("View", selection: $mode) { Text("Songs").tag(0); Text("Albums").tag(1); Text("Artists").tag(2) }.pickerStyle(.segmented).padding(.horizontal); List { if mode == 0 { ForEach(songs) { SongRow(song: $0) }.onDelete { i in i.forEach { context.delete(songs[$0]) } } } else { ForEach(grouped, id: \.key) { item in Section(item.key) { ForEach(item.value) { SongRow(song: $0) } } } } }.listStyle(.insetGrouped) }.navigationTitle("Library") } }
    private var grouped: [(key: String, value: [Song])] { Dictionary(grouping: songs) { mode == 1 ? $0.album : $0.artist }.sorted { $0.key < $1.key } }
}

struct SearchView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @EnvironmentObject private var player: AudioPlayer
    @State private var query = ""
    init() { _songs = Query(sort: \Song.title) }
    var body: some View { NavigationStack { List(filtered) { SongRow(song: $0) }.searchable(text: $query, prompt: "Songs, artists, albums").navigationTitle("Search") } }
    private var filtered: [Song] { query.isEmpty ? songs : songs.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) } }
}

struct PlaylistsView: View {
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Environment(\.modelContext) private var context
    @State private var newName = ""
    init() { _playlists = Query(sort: \Playlist.name) }
    var body: some View { NavigationStack { List { ForEach(playlists) { playlist in NavigationLink(playlist.name) { PlaylistDetail(playlist: playlist) } }.onDelete { i in i.forEach { context.delete(playlists[$0]) } } }.navigationTitle("Playlists").toolbar { Button { newName = "New Playlist" } label: { Image(systemName: "plus") } }.alert("New Playlist", isPresented: Binding(get: { !newName.isEmpty }, set: { if !$0 { newName = "" } })) { TextField("Name", text: $newName); Button("Create") { context.insert(Playlist(name: newName)); newName = "" }; Button("Cancel", role: .cancel) { newName = "" } } } }
}

struct PlaylistDetail: View { let playlist: Playlist; @Query private var songs: [Song]; @EnvironmentObject private var player: AudioPlayer; init(playlist: Playlist) { self.playlist = playlist; _songs = Query() }; var body: some View { List(songs.filter { playlist.songIDs.contains($0.id) }) { SongRow(song: $0) }.navigationTitle(playlist.name) } }

struct SongRow: View { let song: Song; @EnvironmentObject private var player: AudioPlayer; var body: some View { Button { player.play(song) } label: { HStack { Artwork(data: song.artworkData); VStack(alignment: .leading) { Text(song.title).lineLimit(1); Text("\(song.artist) · \(song.album)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if song.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) } } }.buttonStyle(.plain).padding(.vertical, 3).contextMenu { Button(song.isFavorite ? "Remove Favorite" : "Favorite", systemImage: song.isFavorite ? "heart.slash" : "heart") { song.isFavorite.toggle() } } } }
struct Artwork: View { let data: Data?; var body: some View { Group { if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary) } }.frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).clipShape(RoundedRectangle(cornerRadius: 6)) } }
struct MiniPlayer: View { @EnvironmentObject private var player: AudioPlayer; @State private var showingNowPlaying = false; var body: some View { HStack { Button { showingNowPlaying = true } label: { HStack { Artwork(data: player.current?.artworkData); VStack(alignment: .leading) { Text(player.current?.title ?? "").font(.subheadline).bold().lineLimit(1); Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain); Spacer(); Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) } }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).shadow(radius: 4).sheet(isPresented: $showingNowPlaying) { NowPlayingView() } } }
struct NowPlayingView: View { @EnvironmentObject private var player: AudioPlayer; @Environment(\.dismiss) private var dismiss; var body: some View { NavigationStack { VStack(spacing: 28) { Spacer(); Artwork(data: player.current?.artworkData).frame(width: 280, height: 280).font(.largeTitle).clipShape(RoundedRectangle(cornerRadius: 18)); VStack(spacing: 5) { Text(player.current?.title ?? "").font(.title2.bold()); Text(player.current?.artist ?? "").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading); Slider(value: Binding(get: { player.progress }, set: player.seek)); HStack { Text("0:00").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(Int(player.current?.duration ?? 0) / 60):\(String(format: "%02d", Int(player.current?.duration ?? 0) % 60))").font(.caption).foregroundStyle(.secondary) }; HStack(spacing: 34) { Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }; Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.accentColor : Color.primary) }; Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 62)) }; Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }; Button { player.repeatMode = (player.repeatMode + 1) % 2 } label: { Image(systemName: player.repeatMode == 1 ? "repeat.1" : "repeat") } }; Spacer() }.padding(24).navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } } } } }

enum Importer { static func importFiles(_ result: Result<[URL], Error>, context: ModelContext) { guard case .success(let urls) = result else { return }; for source in urls { let accessed = source.startAccessingSecurityScopedResource(); defer { if accessed { source.stopAccessingSecurityScopedResource() } }; let name = source.lastPathComponent; let destination = LibraryStore.musicURL.appendingPathComponent(UUID().uuidString + "-" + name); guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { continue }; let asset = AVURLAsset(url: destination); let metadata = asset.commonMetadata; func value(_ key: AVMetadataIdentifier) -> String { (AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: key).first?.value as? String) ?? "" }; let title = value(.commonIdentifierTitle).isEmpty ? source.deletingPathExtension().lastPathComponent : value(.commonIdentifierTitle); let artist = value(.commonIdentifierArtist).isEmpty ? "Unknown Artist" : value(.commonIdentifierArtist); let album = value(.commonIdentifierAlbumName).isEmpty ? "Unknown Album" : value(.commonIdentifierAlbumName); let duration = CMTimeGetSeconds(asset.duration); let art = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first?.dataValue; context.insert(Song(title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0, fileName: destination.lastPathComponent, artworkData: art)) } } }
