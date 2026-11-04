import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation
import UIKit
import PhotosUI

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
        .contentMargins(.bottom, player.current == nil ? 16 : 104, for: .scrollContent)
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
    @EnvironmentObject private var player: AudioPlayer
    @State private var mode = 0
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<UUID>()
    @State private var showingActions = false
    @State private var showingDeleteConfirmation = false
    @State private var showingDuplicates = false

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

                List(selection: $selectedIDs) {
                    if mode == 0 {
                        ForEach(songs) { SongRow(song: $0).tag($0.id) }
                            .onDelete { offsets in offsets.forEach { context.delete(songs[$0]) } }
                    } else {
                        ForEach(grouped, id: \.key) { item in
                            Section(item.key) {
                                ForEach(item.value) { SongRow(song: $0).tag($0.id) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
                .animation(.easeInOut(duration: 0.2), value: selectedIDs)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bibliothek")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editMode.isEditing {
                        Button(selectedIDs.count == songs.count ? "Auswahl aufheben" : "Alle auswählen") {
                            if selectedIDs.count == songs.count { selectedIDs.removeAll() }
                            else { selectedIDs = Set(songs.map(\.id)) }
                        }
                    } else { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode.isEditing, !selectedIDs.isEmpty {
                        Text("\(selectedIDs.count) ausgewählt").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Duplikate", systemImage: "doc.on.doc") { showingDuplicates = true }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if editMode.isEditing {
                        Button("Aktionen", systemImage: "ellipsis.circle") { showingActions = true }
                            .disabled(selectedIDs.isEmpty)
                        Spacer()
                        Button("Löschen", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                            .disabled(selectedIDs.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingActions) {
                LibrarySelectionActions(songs: songs.filter { selectedIDs.contains($0.id) }, onFinish: finishSelection)
            }
            .sheet(isPresented: $showingDuplicates) { DuplicateManagerView() }
            .confirmationDialog("Bibliothekseinträge löschen?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    songs.filter { selectedIDs.contains($0.id) }.forEach(context.delete)
                    finishSelection()
                }
            } message: {
                Text("Die ausgewählten Titel werden aus der Bibliothek entfernt. Audiodateien bleiben erhalten.")
            }
        }
    }

    private func finishSelection() {
        selectedIDs.removeAll()
        editMode = .inactive
        showingActions = false
    }

    private var grouped: [(key: String, value: [Song])] { Dictionary(grouping: songs) { mode == 1 ? $0.album : $0.artist }.sorted { $0.key < $1.key } }
}

struct SearchView: View {
    @Query(sort: \Song.title) private var songs: [Song]
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered) { SongRow(song: $0) }
                .listStyle(.insetGrouped)
                .searchable(text: $query, prompt: "Titel, Künstler oder Album")
                .navigationTitle("Suche")
        }
    }

    private var filtered: [Song] {
        query.isEmpty ? songs : songs.filter { song in
            let genreNames = genres.filter { song.genreIDs.contains($0.id) }.map(\.name).joined(separator: " ")
            return "\(song.title) \(song.artist) \(song.album) \(genreNames)".localizedCaseInsensitiveContains(query)
        }
    }
}

struct PlaylistsView: View {
    private enum Route: Hashable { case playlist(UUID), catalog }
    @State private var path: [Route] = []
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @Query(sort: \Song.title) private var songs: [Song]
    @Query private var artists: [ArtistProfile]
    @Environment(\.modelContext) private var context
    @State private var showingPlaylistAlert = false
    @State private var showingArtistAlert = false
    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<UUID>()
    @State private var editingPlaylist: Playlist?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selectedIDs) {
                Section {
                    NavigationLink(value: Route.catalog) {
                        Label("Genres & Künstler", systemImage: "guitars")
                    }
                }
                Section("Deine Playlists") {
                    ForEach(filteredPlaylists) { playlist in
                        NavigationLink(value: Route.playlist(playlist.id)) {
                            HStack(spacing: 12) {
                                PlaylistArtwork(playlist: playlist, fallbackData: artworkData(for: playlist))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                    if !playlist.artistName.isEmpty { Text("Artist playlist · \(playlist.artistName)").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Umbenennen / Bearbeiten", systemImage: "pencil") { editingPlaylist = playlist }
                            Button("Cover ändern", systemImage: "photo") { editingPlaylist = playlist }
                            Button("Löschen", systemImage: "trash", role: .destructive) { context.delete(playlist) }
                        }
                    }
                    .onDelete { indexes in
                        let visible = filteredPlaylists
                        indexes.forEach { context.delete(visible[$0]) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .animation(.easeInOut(duration: 0.2), value: selectedIDs)
            .navigationTitle("Playlists")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .catalog: GenreLibraryView()
                case .playlist(let id):
                    if let playlist = playlists.first(where: { $0.id == id }) {
                        PlaylistDetail(playlist: playlist)
                    } else {
                        ContentUnavailableView("Playlist nicht mehr vorhanden", systemImage: "music.note.list")
                    }
                }
            }
            .searchable(text: $query, prompt: "Playlists oder Künstler suchen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Playlist erstellen", systemImage: "music.note.list") { showingPlaylistAlert = true }
                        Button("Create Artist +", systemImage: "person.crop.circle.badge.plus") { showingArtistAlert = true }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editMode.isEditing {
                        Button(selectedIDs.count == filteredPlaylists.count ? "Auswahl aufheben" : "Alle auswählen") {
                            if selectedIDs.count == filteredPlaylists.count { selectedIDs.removeAll() }
                            else { selectedIDs = Set(filteredPlaylists.map(\.id)) }
                        }
                    } else { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode.isEditing, !selectedIDs.isEmpty { Text("\(selectedIDs.count) ausgewählt").font(.caption).foregroundStyle(.secondary) }
                }
                ToolbarItem(placement: .bottomBar) {
                    if editMode.isEditing {
                        Button("Löschen", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                            .disabled(selectedIDs.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingPlaylistAlert) { PlaylistEditorView() }
            .sheet(isPresented: $showingArtistAlert) { ArtistEditorView(createPlaylist: true) }
            .sheet(item: $editingPlaylist) { PlaylistEditorView(playlist: $0) }
            .confirmationDialog("Playlists löschen?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    playlists.filter { selectedIDs.contains($0.id) }.forEach(context.delete)
                    selectedIDs.removeAll()
                    editMode = .inactive
                }
            } message: { Text("Die ausgewählten Playlists und ihre Verknüpfungen werden entfernt. Songs und Audiodateien bleiben erhalten.") }
        }
    }

    private var filteredPlaylists: [Playlist] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? playlists : playlists.filter {
            $0.name.localizedStandardContains(search) || $0.artistName.localizedStandardContains(search)
        }
    }

    private func artworkData(for playlist: Playlist) -> Data? {
        MusicCatalog.tracks(in: playlist, songs: songs, artists: artists).compactMap(\.artworkData).first
    }

}

struct PlaylistEditorView: View {
    let playlist: Playlist?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Song.title) private var songs: [Song]
    @Query private var artists: [ArtistProfile]
    @State private var name = ""
    @State private var query = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var coverData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var showingSongCovers = false
    @State private var errorMessage: String?

    init(playlist: Playlist? = nil) {
        self.playlist = playlist
        _name = State(initialValue: playlist?.name ?? "")
        _selectedIDs = State(initialValue: Set(playlist?.songIDs ?? []))
        _coverData = State(initialValue: playlist?.coverData)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Name der Playlist") { TextField("Name", text: $name) }
                Section("Cover") {
                    HStack(spacing: 16) {
                        CoverImage(data: coverData, size: 96)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("Fotos auswählen", systemImage: "photo.on.rectangle")
                            }
                            Button("Datei auswählen", systemImage: "folder") { showingFileImporter = true }
                            Button("Cover eines Playlist-Titels", systemImage: "music.note") { showingSongCovers = true }
                                .disabled(coverSongs.isEmpty)
                            if coverData != nil {
                                Button("Cover entfernen", systemImage: "xmark.circle", role: .destructive) { coverData = nil; photoItem = nil }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if playlist?.artistName.isEmpty ?? true {
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
                } else {
                    Section { Text("Artist-Playlists werden automatisch über den Künstler gepflegt.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(playlist == nil ? "Playlist erstellen" : "Playlist bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Titel, Künstler oder Album suchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(playlist == nil ? "Erstellen" : "Speichern") {
                        savePlaylist()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        coverData = resizedCoverData(data)
                    }
                }
            }
            .sheet(isPresented: $showingSongCovers) {
                NavigationStack {
                    List(coverSongs) { song in
                        Button {
                            coverData = song.artworkData.flatMap(resizedCoverData)
                            photoItem = nil
                            showingSongCovers = false
                        } label: {
                            HStack(spacing: 12) {
                                Artwork(data: song.artworkData)
                                VStack(alignment: .leading) {
                                    Text(song.title).foregroundStyle(.primary)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("Song-Cover auswählen")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { showingSongCovers = false } } }
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { coverData = resizedCoverData(data) }
            }
        }
    }

    private var filteredSongs: [Song] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? songs : songs.filter {
            "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(search)
        }
    }

    private var coverSongs: [Song] {
        let tracks: [Song]
        if let playlist, !playlist.artistName.isEmpty {
            tracks = MusicCatalog.tracks(in: playlist, songs: songs, artists: artists)
        } else {
            tracks = songs.filter { selectedIDs.contains($0.id) }
        }
        return tracks.filter { $0.artworkData != nil }
    }

    private func savePlaylist() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        do {
            if let playlist {
                playlist.name = cleanName
                playlist.coverData = coverData
                if playlist.artistName.isEmpty {
                    let selected = Set(selectedIDs)
                    let existingOrder = playlist.songIDs.filter { selected.contains($0) }
                    let existingIDs = Set(existingOrder)
                    let newlySelected = songs.filter { selected.contains($0.id) && !existingIDs.contains($0.id) }.map(\.id)
                    playlist.songIDs = existingOrder + newlySelected
                }
            } else {
                let created = Playlist(name: cleanName, coverData: coverData)
                created.songIDs = songs.filter { selectedIDs.contains($0.id) }.map(\.id)
                context.insert(created)
            }
            try context.save()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct PlaylistDetail: View {
    let playlist: Playlist
    @Query private var songs: [Song]
    @Query private var artists: [ArtistProfile]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: AudioPlayer
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<UUID>()
    @State private var showingEditor = false
    @State private var showingClearSelection = false
    @State private var showingArtistEditor = false

    init(playlist: Playlist) { self.playlist = playlist; _songs = Query() }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PlaylistArtwork(playlist: playlist, fallbackData: displayedSongs.compactMap(\.artworkData).first, size: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name).font(.title3.bold())
                        Text(playlist.artistName.isEmpty ? "\(regularSongs.count) Titel" : "Artist playlist · \(artistSongs.count) Titel")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            if !playlist.artistName.isEmpty {
                Section { ForEach(artistSongs) { SongRow(song: $0) } } header: {
                    Label("Alle Titel von \(playlist.artistName)", systemImage: "person.crop.circle")
                }
            } else if regularSongs.isEmpty {
                ContentUnavailableView("Playlist ist leer", systemImage: "music.note.list", description: Text("Füge Titel über das Kontextmenü oder Bearbeiten hinzu."))
            } else {
                Section("Titel · \(regularSongs.count)") {
                    ForEach(regularSongs) { song in
                        PlaylistSongRow(song: song) {
                            remove(song)
                        }
                        .tag(song.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Entfernen", systemImage: "minus.circle", role: .destructive) { remove(song) }
                        }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: remove)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .animation(.easeInOut(duration: 0.2), value: regularSongs.map(\.id))
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if playlist.artistName.isEmpty, !regularSongs.isEmpty {
                    if editMode.isEditing {
                        Button(selectedIDs.count == regularSongs.count ? "Auswahl aufheben" : "Alle auswählen") {
                            if selectedIDs.count == regularSongs.count { selectedIDs.removeAll() }
                            else { selectedIDs = Set(regularSongs.map(\.id)) }
                        }
                    } else { EditButton() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if editMode.isEditing, !selectedIDs.isEmpty {
                    Text("\(selectedIDs.count) ausgewählt").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu {
                        Button("Playlist und Cover bearbeiten", systemImage: "pencil") { showingEditor = true }
                        if artistProfile != nil {
                            Button("Künstlerzuordnung bearbeiten", systemImage: "person.crop.circle") { showingArtistEditor = true }
                        }
                    } label: { Label("Bearbeiten", systemImage: "pencil") }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if editMode.isEditing, !selectedIDs.isEmpty {
                    Button("Aus Playlist entfernen", systemImage: "minus.circle", role: .destructive) { showingClearSelection = true }
                }
            }
        }
        .sheet(isPresented: $showingEditor) { PlaylistEditorView(playlist: playlist) }
        .sheet(isPresented: $showingArtistEditor) {
            if let profile = artistProfile { ArtistEditorView(artist: profile) }
        }
        .confirmationDialog("Titel aus Playlist entfernen?", isPresented: $showingClearSelection, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                playlist.songIDs.removeAll { selectedIDs.contains($0) }
                try? context.save()
                selectedIDs.removeAll()
                editMode = .inactive
            }
        } message: { Text("Die Audiodateien bleiben in deiner Bibliothek erhalten.") }
    }

    private var regularSongs: [Song] {
        let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return playlist.songIDs.compactMap { lookup[$0] }
    }
    private var artistSongs: [Song] {
        MusicCatalog.tracks(in: playlist, songs: songs, artists: artists)
    }
    private var artistProfile: ArtistProfile? {
        guard !playlist.artistName.isEmpty else { return nil }
        return artists.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(playlist.artistName) }
    }
    private var displayedSongs: [Song] { playlist.artistName.isEmpty ? regularSongs : artistSongs }

    private func move(from offsets: IndexSet, to destination: Int) {
        var visibleIDs = regularSongs.map(\.id)
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)
        let visibleSet = Set(visibleIDs)
        playlist.songIDs = visibleIDs + playlist.songIDs.filter { !visibleSet.contains($0) }
        try? context.save()
    }

    private func remove(_ song: Song) {
        playlist.songIDs.removeAll { $0 == song.id }
        selectedIDs.remove(song.id)
        try? context.save()
    }

    private func remove(at offsets: IndexSet) {
        let ids = offsets.map { regularSongs[$0].id }
        playlist.songIDs.removeAll { ids.contains($0) }
        try? context.save()
    }
}

struct PlaylistSongRow: View {
    let song: Song
    let remove: () -> Void
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Button { player.play(song) } label: {
            HStack(spacing: 12) {
                Artwork(data: song.artworkData)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.body.weight(.medium)).lineLimit(1)
                    Text("\(song.artist) · \(song.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if song.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }
            Button("An Warteschlange anhängen", systemImage: "text.badge.plus") { player.addToQueue(song) }
            Divider()
            Button("Aus Playlist entfernen", systemImage: "minus.circle", role: .destructive, action: remove)
        }
    }
}

struct PlaylistArtwork: View {
    let data: Data?
    let size: CGFloat

    init(playlist: Playlist, fallbackData: Data? = nil, size: CGFloat = 56) {
        self.data = playlist.coverData ?? fallbackData
        self.size = size
    }

    var body: some View { CoverImage(data: data, size: size) }
}

struct CoverImage: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

private func resizedCoverData(_ data: Data) -> Data {
    guard let image = UIImage(data: data), max(image.size.width, image.size.height) > 1024 else { return data }
    let scale = 1024 / max(image.size.width, image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.jpegData(withCompressionQuality: 0.82) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
}

struct LibrarySelectionActions: View {
    let songs: [Song]
    let onFinish: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: AudioPlayer
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var newPlaylistName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Auswahl") { Text("\(songs.count) Titel ausgewählt").foregroundStyle(.secondary) }
                Section("Zu bestehender Playlist hinzufügen") {
                    ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            Label(playlist.name, systemImage: "plus.rectangle.on.folder")
                        }
                    }
                    if playlists.filter({ $0.artistName.isEmpty }).isEmpty {
                        Text("Noch keine normale Playlist vorhanden.").foregroundStyle(.secondary)
                    }
                }
                Section("Neue Playlist") {
                    TextField("Name der Playlist", text: $newPlaylistName)
                    Button("Neue Playlist mit Auswahl erstellen", systemImage: "plus.circle.fill") { createPlaylist() }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Wiedergabe") {
                    Button("Auswahl an Warteschlange anhängen", systemImage: "text.badge.plus") {
                        player.addToQueue(songs)
                        finish()
                    }
                }
            }
            .navigationTitle("Auswahlaktionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { finish() } } }
            .alert("Aktion fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func add(to playlist: Playlist) {
        let existing = Set(playlist.songIDs)
        playlist.songIDs.append(contentsOf: songs.map(\.id).filter { !existing.contains($0) })
        do { try context.save(); finish() } catch { errorMessage = error.localizedDescription }
    }

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = Playlist(name: name)
        playlist.songIDs = songs.map(\.id)
        context.insert(playlist)
        do { try context.save(); finish() } catch { context.delete(playlist); errorMessage = error.localizedDescription }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

struct SongRow: View {
    let song: Song
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.modelContext) private var context
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var showingGenreEditor = false
    var body: some View {
        Button { player.play(song) } label: { HStack(spacing: 12) { Artwork(data: song.artworkData); VStack(alignment: .leading, spacing: 3) { Text(song.title).font(.body.weight(.medium)).lineLimit(1); Text("\(song.artist) · \(song.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(minLength: 4); if song.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }; Image(systemName: "ellipsis").foregroundStyle(.tertiary).font(.caption) }.contentShape(Rectangle()) }.buttonStyle(.plain).padding(.vertical, 5)
        .modifier(TrackSwipeActions(song: song))
        .contextMenu {
            Button(song.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: song.isFavorite ? "heart.slash" : "heart") { song.isFavorite.toggle() }
            Button("Genre bearbeiten", systemImage: "tag") { showingGenreEditor = true }
            if song.genreOverrideID != nil {
                Button("Originalgenre wiederherstellen", systemImage: "arrow.uturn.backward") { SongGenreStore.restore(song, context: context) }
            }
            Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }
            Button("An Warteschlange anhängen", systemImage: "text.badge.plus") { player.addToQueue(song) }
            if !playlists.filter({ $0.artistName.isEmpty }).isEmpty {
                Menu("In Playlist speichern", systemImage: "plus.rectangle.on.folder") {
                    ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in
                        Button(playlist.name) { if !playlist.songIDs.contains(song.id) { playlist.songIDs.append(song.id) } }
                    }
                }
            }
            Divider()
            Button("Löschen", systemImage: "trash", role: .destructive) { context.delete(song) }
        }
        .sheet(isPresented: $showingGenreEditor) { SongGenreEditorView(song: song) }
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

struct Artwork: View {
    let data: Data?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: min(22, size * 10 / 48)))
        .clipShape(RoundedRectangle(cornerRadius: min(22, size * 10 / 48)))
    }
}

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
                        GeometryReader { geometry in
                            Artwork(data: player.current?.artworkData, size: geometry.size.width)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 420)
                        .accessibilityHidden(true)
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
                        HStack(spacing: 48) {
                            Button { player.seekBy(-15) } label: {
                                Image(systemName: "gobackward.15").font(.title2)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("15 Sekunden zurück")
                            Button { player.seekBy(15) } label: {
                                Image(systemName: "goforward.15").font(.title2)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("15 Sekunden vor")
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.current == nil)
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
            let importedGenre = await metadataValue(.commonIdentifierType)
            let title = titleValue.isEmpty ? source.deletingPathExtension().lastPathComponent : titleValue
            let artist = artistValue.isEmpty ? "Unbekannter Künstler" : artistValue
            let album = albumValue.isEmpty ? "Unbekanntes Album" : albumValue
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let artItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
            var art: Data?
            if let artItem { art = try? await artItem.load(.dataValue) }
            let song = Song(title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0, fileName: destination.lastPathComponent, artworkData: art, importedGenre: importedGenre)
            let profiles = (try? context.fetch(FetchDescriptor<ArtistProfile>())) ?? []
            let genres = (try? context.fetch(FetchDescriptor<MusicGenre>())) ?? []
            MusicCatalog.classify(song, artists: profiles, genres: genres)
            context.insert(song)
        }
    }
}
