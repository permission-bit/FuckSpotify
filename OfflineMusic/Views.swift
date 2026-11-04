import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation
import UIKit

private let appTint = Color(red: 0.20, green: 0.60, blue: 0.42)

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var catalogError: String?
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
        .task {
            do { try MusicCatalog.seed(in: context) }
            catch { catalogError = error.localizedDescription }
        }
        .alert("Musikkatalog konnte nicht geladen werden", isPresented: Binding(get: { catalogError != nil }, set: { if !$0 { catalogError = nil } })) {
            Button("OK") { catalogError = nil }
        } message: { Text(catalogError ?? "") }
    }
}

struct HomeView: View {
    @Query(sort: \Song.addedAt, order: .reverse) private var songs: [Song]
    @Environment(\.modelContext) private var context
    @State private var showImporter = false; @State private var importingFolder = false
    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deine Musik").font(.largeTitle.bold())
                    Text("Offline hören, ganz ohne Ablenkung.").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                if songs.isEmpty {
                    EmptyLibraryCard { importingFolder = true; showImporter = true }
                } else {
                    Section {
                        ForEach(songs.prefix(8)) { SongRow(song: $0) }
                    } header: { Label("Zuletzt hinzugefügt", systemImage: "clock") }
                    if !songs.filter(\.isFavorite).isEmpty {
                        Section {
                            ForEach(songs.filter(\.isFavorite).prefix(5)) { SongRow(song: $0) }
                        } header: { Label("Favoriten", systemImage: "heart.fill") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Start")
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
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { GenreLibraryView() } label: {
                        Label("Genres & Künstler", systemImage: "guitars")
                    }
                }
                Section("Deine Playlists") {
                ForEach(filteredPlaylists) { playlist in
                    NavigationLink { PlaylistDetail(playlist: playlist) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                if !playlist.artistName.isEmpty { Text("Artist playlist · \(playlist.artistName)").font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: playlist.artistName.isEmpty ? "music.note.list" : "person.crop.circle") }
                    }
                }
                .onDelete { indexes in
                    let visible = filteredPlaylists
                    indexes.forEach { context.delete(visible[$0]) }
                }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Playlists")
            .searchable(text: $query, prompt: "Playlists oder Künstler suchen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Playlist erstellen", systemImage: "music.note.list") { showingPlaylistAlert = true }
                        Button("Create Artist +", systemImage: "person.crop.circle.badge.plus") { showingArtistAlert = true }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .sheet(isPresented: $showingPlaylistAlert) { PlaylistEditorView() }
            .sheet(isPresented: $showingArtistAlert) { ArtistEditorView(createPlaylist: true) }
        }
    }

    private var filteredPlaylists: [Playlist] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? playlists : playlists.filter {
            $0.name.localizedStandardContains(search) || $0.artistName.localizedStandardContains(search)
        }
    }

}

struct PlaylistEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Song.title) private var songs: [Song]
    @State private var name = ""
    @State private var query = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Name der Playlist") { TextField("Name", text: $name) }
                Section("Titel auswählen · \(selectedIDs.count) ausgewählt") {
                    ForEach(filteredSongs) { song in
                        Button {
                            if selectedIDs.contains(song.id) { selectedIDs.remove(song.id) }
                            else { selectedIDs.insert(song.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Artwork(data: song.artworkData)
                                VStack(alignment: .leading) {
                                    Text(song.title).foregroundStyle(.primary).lineLimit(1)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .accessibilityAddTraits(selectedIDs.contains(song.id) ? .isSelected : [])
                        .modifier(TrackSwipeActions(song: song))
                    }
                    if filteredSongs.isEmpty {
                        Text(songs.isEmpty ? "Importiere Musik, um Titel auszuwählen." : "Keine passenden Titel gefunden.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Playlist erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titel, Künstler oder Album suchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        playlist.songIDs = songs.filter { selectedIDs.contains($0.id) }.map(\.id)
                        context.insert(playlist)
                        do { try context.save(); dismiss() }
                        catch { context.delete(playlist); errorMessage = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var filteredSongs: [Song] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? songs : songs.filter {
            "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(search)
        }
    }
}

struct PlaylistDetail: View {
    let playlist: Playlist
    @Query private var songs: [Song]
    @Query private var artists: [ArtistProfile]
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
    private var artistSongs: [Song] {
        let profile = artists.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(playlist.artistName) }
        return songs.filter { song in
            if let profile { return song.artistIDs.contains(profile.id) }
            return MusicCatalog.containsName(playlist.artistName, in: song.artist)
        }
    }
}

struct SongRow: View {
    let song: Song; @EnvironmentObject private var player: AudioPlayer; @Environment(\.modelContext) private var context; @Query(sort: \Playlist.name) private var playlists: [Playlist]
    var body: some View {
        Button { player.play(song) } label: { HStack(spacing: 12) { Artwork(data: song.artworkData); VStack(alignment: .leading, spacing: 3) { Text(song.title).font(.body.weight(.medium)).lineLimit(1); Text("\(song.artist) · \(song.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(minLength: 4); if song.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }; Image(systemName: "ellipsis").foregroundStyle(.tertiary).font(.caption) }.contentShape(Rectangle()) }.buttonStyle(.plain).padding(.vertical, 5)
        .modifier(TrackSwipeActions(song: song))
        .contextMenu { Button(song.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: song.isFavorite ? "heart.slash" : "heart") { song.isFavorite.toggle() }; Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }; Button("An Warteschlange anhängen", systemImage: "text.badge.plus") { player.addToQueue(song) }; if !playlists.filter({ $0.artistName.isEmpty }).isEmpty { Menu("In Playlist speichern", systemImage: "plus.rectangle.on.folder") { ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in Button(playlist.name) { if !playlist.songIDs.contains(song.id) { playlist.songIDs.append(song.id) } } } } }; Divider(); Button("Löschen", systemImage: "trash", role: .destructive) { context.delete(song) } }
    }
}

// Shared by every track list, including the home screen and playlist selection.
struct TrackSwipeActions: ViewModifier {
    let song: Song
    @EnvironmentObject private var player: AudioPlayer

    func body(content: Content) -> some View {
        content.swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(song)
            }
            .tint(appTint)
            Button("Warteschlange", systemImage: "text.badge.plus") {
                player.addToQueue(song)
            }
            .tint(.blue)
        }
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
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var selectedQueueIDs = Set<UUID>()
    @State private var showingClearQueueConfirmation = false

    var body: some View {
        NavigationStack {
            List(selection: $selectedQueueIDs) {
                Section {
                    VStack(spacing: 24) {
                        Artwork(data: player.current?.artworkData)
                            .frame(width: 280, height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.current?.title ?? "").font(.title2.bold())
                            Text(player.current?.artist ?? "").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Slider(value: Binding(get: { player.progress }, set: player.seek))
                        HStack {
                            Text(time(player.progress * (player.current?.duration ?? 0)))
                            Spacer()
                            Text(time(player.current?.duration ?? 0))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        controls
                    }
                    .padding(.vertical, 18)
                }
                .listRowBackground(appTint.opacity(0.12))
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Wird wiedergegeben: \(player.current?.title ?? String())")
                if !player.queue.isEmpty {
                    Section {
                        ForEach(player.queue) { song in
                            QueueTrackRow(song: song)
                                .tag(song.id)
                        }
                        .onMove(perform: player.moveQueue)
                        .onDelete(perform: player.removeQueue)
                    } header: {
                        HStack {
                            Label("Als Nächstes · \(player.queue.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                            Spacer()
                            Button("Leeren", role: .destructive) { showingClearQueueConfirmation = true }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .animation(.easeInOut(duration: 0.2), value: player.queue.map(\.id))
            .navigationTitle("Wiedergabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !player.queue.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if editMode.isEditing, !selectedQueueIDs.isEmpty {
                        Button("Auswahl entfernen", role: .destructive) {
                            player.removeQueue(ids: selectedQueueIDs)
                            selectedQueueIDs.removeAll()
                        }
                    }
                }
            }
            .confirmationDialog("Warteschlange leeren?", isPresented: $showingClearQueueConfirmation, titleVisibility: .visible) {
                Button("Kommende Titel entfernen", role: .destructive) {
                    player.clearQueue()
                    selectedQueueIDs.removeAll()
                }
            } message: {
                Text("Der gerade spielende Titel läuft weiter.")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel("Vorheriger Titel")
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.shuffle ? appTint : .primary)
            }
            .accessibilityLabel("Zufallswiedergabe")
            .accessibilityValue(player.shuffle ? "Ein" : "Aus")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Wiedergabe")
            Button { player.next() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .accessibilityLabel("Nächster Titel")
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == 1 ? "repeat.1" : "repeat")
            }
            .accessibilityLabel("Titel wiederholen")
        }
        .buttonStyle(.plain)
    }

    private func time(_ seconds: Double) -> String {
        "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}

struct QueueTrackRow: View {
    let song: Song
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Artwork(data: song.artworkData)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(song.artist) · \(song.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Entfernen", systemImage: "trash", role: .destructive) { player.removeFromQueue(song) }
        }
        .accessibilityLabel("Kommender Titel: \(song.title), \(song.artist)")
    }
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
            let song = Song(title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0, fileName: destination.lastPathComponent, artworkData: art)
            let profiles = (try? context.fetch(FetchDescriptor<ArtistProfile>())) ?? []
            MusicCatalog.classify(song, artists: profiles)
            context.insert(song)
        }
    }
}
