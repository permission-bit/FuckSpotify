import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation
import UIKit

private let appTint = Color(red: 0.18, green: 0.42, blue: 0.34)

struct RootView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @EnvironmentObject private var player: AudioPlayer
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Start", systemImage: "house.fill") }
            LibraryView().tabItem { Label("Bibliothek", systemImage: "music.note.list") }
            SearchView().tabItem { Label("Suche", systemImage: "magnifyingglass") }
            PlaylistsView().tabItem { Label("Playlists", systemImage: "rectangle.stack.fill") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil { Color.clear.frame(height: 72) }
        }
        .overlay(alignment: .bottom) {
            if player.current != nil {
                MiniPlayer()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 78)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(appTint)
        .animation(.easeInOut(duration: 0.2), value: player.current?.id)
        .onAppear { player.setLibrary(songs) }.onChange(of: songs.count) { _, _ in player.setLibrary(songs) }
    }
}

struct HomeView: View {
    @Query(sort: \Song.addedAt, order: .reverse) private var songs: [Song]
    @Environment(\.modelContext) private var context
    @State private var showImporter = false; @State private var importingFolder = false
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) { Text("Deine Musik").font(.largeTitle.bold()); Text("Offline hören, ganz ohne Ablenkung.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                if songs.isEmpty { EmptyLibraryCard { importingFolder = true; showImporter = true } } else {
                    HomeSection(title: "Zuletzt hinzugefügt", icon: "clock") { ForEach(songs.prefix(8)) { SongRow(song: $0) } }
                    if !songs.filter(\.isFavorite).isEmpty { HomeSection(title: "Favoriten", icon: "heart.fill") { ForEach(songs.filter(\.isFavorite).prefix(5)) { SongRow(song: $0) } } }
                }
            }.padding(16) }.background(Color(.systemGroupedBackground)).navigationTitle("Start")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("Ordner importieren", systemImage: "folder") { importingFolder = true; showImporter = true }; Button("Dateien importieren", systemImage: "music.note") { importingFolder = false; showImporter = true } } label: { Image(systemName: "plus.circle.fill").font(.title3) } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder, .audio], allowsMultipleSelection: true) { result in
                Task {
                    if importingFolder { await Importer.importFolders(result, context: context) }
                    else { await Importer.importFiles(result, context: context) }
                }
            }
        }
    }
}

struct HomeSection<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: icon).font(.headline); VStack(spacing: 0) { content }.padding(.horizontal, 12).padding(.vertical, 6).background(.background, in: RoundedRectangle(cornerRadius: 18)) } }
}

struct EmptyLibraryCard: View {
    let action: () -> Void
    var body: some View { VStack(spacing: 14) { Image(systemName: "music.note.list").font(.system(size: 38)).foregroundStyle(appTint); Text("Deine Bibliothek ist noch leer").font(.headline); Text("Importiere einen Musikordner, um loszulegen.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center); Button("Ordner auswählen", action: action).buttonStyle(.borderedProminent).tint(appTint) }.frame(maxWidth: .infinity).padding(28).background(.background, in: RoundedRectangle(cornerRadius: 20)) }
}

struct LibraryView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @Environment(\.modelContext) private var context
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Ansicht", selection: $mode) {
                    Text("Titel").tag(0)
                    Text("Alben").tag(1)
                    Text("Künstler").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                List {
                    if mode == 0 {
                        ForEach(songs) { SongRow(song: $0) }
                            .onDelete { offsets in offsets.forEach { context.delete(songs[$0]) } }
                    } else {
                        ForEach(grouped, id: \.key) { item in
                            Section(item.key) {
                                ForEach(item.value) { SongRow(song: $0) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bibliothek")
        }
    }

    private var grouped: [(key: String, value: [Song])] { Dictionary(grouping: songs) { mode == 1 ? $0.album : $0.artist }.sorted { $0.key < $1.key } }
}

struct SearchView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered) { SongRow(song: $0) }
                .listStyle(.insetGrouped)
                .searchable(text: $query, prompt: "Titel, Künstler oder Album")
                .navigationTitle("Suche")
        }
    }

    private var filtered: [Song] { query.isEmpty ? songs : songs.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) } }
}

struct PlaylistsView: View {
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Environment(\.modelContext) private var context
    @State private var showingPlaylistAlert = false
    @State private var showingArtistAlert = false
    @State private var newPlaylistName = ""
    @State private var newArtistName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistDetail(playlist: playlist) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                if !playlist.artistName.isEmpty { Text("Artist playlist · \(playlist.artistName)").font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: playlist.artistName.isEmpty ? "music.note.list" : "person.crop.circle") }
                    }
                }
                .onDelete { indexes in indexes.forEach { context.delete(playlists[$0]) } }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Playlist erstellen", systemImage: "music.note.list") { newPlaylistName = ""; showingPlaylistAlert = true }
                        Button("Create Artist +", systemImage: "person.crop.circle.badge.plus") { newArtistName = ""; showingArtistAlert = true }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .alert("Neue Playlist", isPresented: $showingPlaylistAlert) {
                TextField("Name der Playlist", text: $newPlaylistName)
                Button("Erstellen") { createPlaylist() }
                Button("Abbrechen", role: .cancel) { }
            }
            .alert("Create Artist +", isPresented: $showingArtistAlert) {
                TextField("Künstlername", text: $newArtistName)
                Button("Artist playlist erstellen") { createArtistPlaylist() }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                Text("Alle Songs mit diesem Künstlernamen werden automatisch hinzugefügt.")
            }
        }
    }

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(Playlist(name: name))
    }

    private func createArtistPlaylist() {
        let artist = newArtistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return }
        context.insert(Playlist(name: artist, artistName: artist))
    }
}

struct PlaylistDetail: View {
    let playlist: Playlist
    @Query private var songs: [Song]
    @EnvironmentObject private var player: AudioPlayer

    init(playlist: Playlist) { self.playlist = playlist; _songs = Query() }

    var body: some View {
        List {
            if !playlist.artistName.isEmpty {
                Section {
                    ForEach(artistSongs) { SongRow(song: $0) }
                } header: {
                    Label("Alle Titel von \(playlist.artistName)", systemImage: "person.crop.circle")
                }
            } else {
                ForEach(regularSongs) { SongRow(song: $0) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(playlist.name)
    }

    private var regularSongs: [Song] { songs.filter { playlist.songIDs.contains($0.id) } }
    private var artistSongs: [Song] { songs.filter { $0.artist.localizedCaseInsensitiveContains(playlist.artistName) } }
}

struct SongRow: View {
    let song: Song; @EnvironmentObject private var player: AudioPlayer; @Environment(\.modelContext) private var context; @Query(sort: \Playlist.name) private var playlists: [Playlist]
    var body: some View {
        Button { player.play(song) } label: { HStack(spacing: 12) { Artwork(data: song.artworkData); VStack(alignment: .leading, spacing: 3) { Text(song.title).font(.body.weight(.medium)).lineLimit(1); Text("\(song.artist) · \(song.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(minLength: 4); if song.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }; Image(systemName: "ellipsis").foregroundStyle(.tertiary).font(.caption) }.contentShape(Rectangle()) }.buttonStyle(.plain).padding(.vertical, 5)
        .swipeActions(edge: .leading, allowsFullSwipe: true) { Button("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }.tint(appTint); Button("Warteschlange", systemImage: "text.badge.plus") { player.addToQueue(song) }.tint(.blue) }
        .contextMenu { Button(song.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: song.isFavorite ? "heart.slash" : "heart") { song.isFavorite.toggle() }; Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }; Button("An Warteschlange anhängen", systemImage: "text.badge.plus") { player.addToQueue(song) }; if !playlists.filter({ $0.artistName.isEmpty }).isEmpty { Menu("In Playlist speichern", systemImage: "plus.rectangle.on.folder") { ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in Button(playlist.name) { if !playlist.songIDs.contains(song.id) { playlist.songIDs.append(song.id) } } } } }; Divider(); Button("Löschen", systemImage: "trash", role: .destructive) { context.delete(song) } }
    }
}

struct Artwork: View { let data: Data?; var body: some View { Group { if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary) } }.frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10)) } }

struct MiniPlayer: View {
    @EnvironmentObject private var player: AudioPlayer
    @State private var showingNowPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.primary.opacity(0.10))
                    Rectangle()
                        .fill(appTint.opacity(0.9))
                        .frame(width: proxy.size.width * min(max(player.progress, 0), 1))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 14)

            HStack(spacing: 10) {
                Button { showingNowPlaying = true } label: {
                    HStack(spacing: 10) {
                        Artwork(data: player.current?.artworkData)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Vorheriger Titel")
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Wiedergabe")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Nächster Titel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .sheet(isPresented: $showingNowPlaying) { NowPlayingView() }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayer; @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { ScrollView { VStack(spacing: 24) { Artwork(data: player.current?.artworkData).frame(width: 280, height: 280).font(.largeTitle).clipShape(RoundedRectangle(cornerRadius: 22)).padding(.top, 18); VStack(alignment: .leading, spacing: 5) { Text(player.current?.title ?? "").font(.title2.bold()); Text(player.current?.artist ?? "").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading); Slider(value: Binding(get: { player.progress }, set: player.seek)); HStack { Text(time(player.progress * (player.current?.duration ?? 0))); Spacer(); Text(time(player.current?.duration ?? 0)) }.font(.caption).foregroundStyle(.secondary); HStack(spacing: 28) { Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }; Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? appTint : .primary) }; Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 62)) }; Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }; Button { player.repeatMode = (player.repeatMode + 1) % 2 } label: { Image(systemName: player.repeatMode == 1 ? "repeat.1" : "repeat") } }; if !player.queue.isEmpty { VStack(alignment: .leading, spacing: 10) { Label("Als Nächstes", systemImage: "list.number").font(.headline); ForEach(player.queue) { song in HStack { Artwork(data: song.artworkData); Text(song.title).lineLimit(1); Spacer(); Button { player.removeFromQueue(song) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } } } }.frame(maxWidth: .infinity, alignment: .leading) } }.padding(24) }.navigationTitle("Wiedergabe").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fertig") { dismiss() } } } }
    private func time(_ seconds: Double) -> String { "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))" }
}

@MainActor
enum Importer {
    static func importFiles(_ result: Result<[URL], Error>, context: ModelContext) async {
        guard case .success(let urls) = result else { return }
        for source in urls {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let destination = LibraryStore.musicURL.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { continue }
            let asset = AVURLAsset(url: destination)
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            func metadataValue(_ key: AVMetadataIdentifier) async -> String {
                guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: key).first,
                      let value = try? await item.load(.value) as? String else { return "" }
                return value
            }
            let titleValue = await metadataValue(.commonIdentifierTitle)
            let artistValue = await metadataValue(.commonIdentifierArtist)
            let albumValue = await metadataValue(.commonIdentifierAlbumName)
            let title = titleValue.isEmpty ? source.deletingPathExtension().lastPathComponent : titleValue
            let artist = artistValue.isEmpty ? "Unbekannter Künstler" : artistValue
            let album = albumValue.isEmpty ? "Unbekanntes Album" : albumValue
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
            var art: Data?
            if let artItem { art = try? await artItem.load(.dataValue) }
            context.insert(Song(title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0, fileName: destination.lastPathComponent, artworkData: art))
        }
    }
}
