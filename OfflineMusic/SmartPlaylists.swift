import SwiftData
import SwiftUI

enum SmartPlaylistKind: String, CaseIterable, Identifiable {
    case recentlyPlayed, neverPlayed, mostPlayed, recentlyAdded, favorites
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyPlayed: return "Zuletzt gespielt"
        case .neverPlayed: return "Noch nie gespielt"
        case .mostPlayed: return "Meistgespielt"
        case .recentlyAdded: return "Zuletzt hinzugefügt"
        case .favorites: return "Favoriten"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .neverPlayed: return "sparkles"
        case .mostPlayed: return "chart.bar.fill"
        case .recentlyAdded: return "plus.circle.fill"
        case .favorites: return "heart.fill"
        }
    }

    var descriptor: FetchDescriptor<Song> {
        let title = SortDescriptor(\Song.title)
        let id = SortDescriptor(\Song.fileName)
        switch self {
        case .recentlyPlayed:
            return FetchDescriptor(predicate: #Predicate<Song> { $0.lastPlayedAt != nil }, sortBy: [SortDescriptor(\Song.lastPlayedAt, order: .reverse), title, id])
        case .neverPlayed:
            return FetchDescriptor(predicate: #Predicate<Song> { $0.playCount == 0 }, sortBy: [SortDescriptor(\Song.addedAt, order: .reverse), title, id])
        case .mostPlayed:
            return FetchDescriptor(predicate: #Predicate<Song> { $0.playCount > 0 }, sortBy: [SortDescriptor(\Song.playCount, order: .reverse), SortDescriptor(\Song.lastPlayedAt, order: .reverse), title, id])
        case .recentlyAdded:
            return FetchDescriptor(sortBy: [SortDescriptor(\Song.addedAt, order: .reverse), title, id])
        case .favorites:
            return FetchDescriptor(predicate: #Predicate<Song> { $0.isFavorite }, sortBy: [title, id])
        }
    }
}

struct SmartPlaylistDetail: View {
    let kind: SmartPlaylistKind
    @Query private var songs: [Song]
    @EnvironmentObject private var player: AudioPlayer
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<UUID>()
    @State private var showingActions = false

    init(kind: SmartPlaylistKind) {
        self.kind = kind
        _songs = Query(kind.descriptor)
    }

    var body: some View {
        List(selection: $selectedIDs) {
            Section {
                Label("Smart Playlist · \(songs.count) Titel", systemImage: kind.symbol)
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Abspielen", systemImage: "play.fill") {
                    if let first = songs.first { player.play(first, in: songs) }
                }
                .disabled(songs.isEmpty)
            } footer: { Text("Aktualisiert sich automatisch. Ein Titel zählt nach 30 gehörten Sekunden oder der Hälfte seiner Dauer als gespielt.") }
            if songs.isEmpty {
                ContentUnavailableView("Noch keine Titel", systemImage: kind.symbol, description: Text("Passende Titel erscheinen hier automatisch."))
            } else {
                ForEach(songs) { song in
                    SongRow(song: song, playbackCollection: songs).tag(song.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) {
                if editMode.isEditing {
                    Button(selectedIDs.count == songs.count ? "Auswahl aufheben" : "Alle auswählen") {
                        if selectedIDs.count == songs.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(songs.map(\.id)) }
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Aktionen · \(selectedIDs.count) ausgewählt", systemImage: "ellipsis.circle") { showingActions = true }
                        .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .sheet(isPresented: $showingActions) {
            LibrarySelectionActions(songs: songs.filter { selectedIDs.contains($0.id) }) {
                selectedIDs.removeAll()
                editMode = .inactive
                showingActions = false
            }
        }
        .onChange(of: songs.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
    }
}
