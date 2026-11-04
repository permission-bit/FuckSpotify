import Foundation
import SwiftData
import SwiftUI

// A deliberately broad starter classification; the user's assignments take precedence.
@MainActor
enum MusicCatalog {
    enum MatchField: String, CaseIterable, Identifiable {
        case artist, title, album, fileName
        var id: String { rawValue }
        var label: String {
            switch self {
            case .artist: return "Künstler"
            case .title: return "Titel"
            case .album: return "Album"
            case .fileName: return "Dateiname"
            }
        }
    }
    static let starters: [(String, [String])] = [
        ("Rock", ["Queen", "AC/DC", "The Rolling Stones", "Led Zeppelin", "Foo Fighters", "Nirvana"]),
        ("Hip-Hop", ["Eminem", "Tupac Shakur", "The Notorious B.I.G.", "Kendrick Lamar", "Nas", "Snoop Dogg"]),
        ("Deutschrap", ["Sido", "Bushido", "Kool Savas", "Marteria", "Apache 207", "Cro"]),
        ("Pop", ["Taylor Swift", "Ariana Grande", "Dua Lipa", "Ed Sheeran", "Michael Jackson", "Madonna"]),
        ("Metal", ["Metallica", "Iron Maiden", "Black Sabbath", "Slayer", "Judas Priest"]),
        ("Punk", ["Sex Pistols", "Ramones", "The Clash", "Die Ärzte", "Die Toten Hosen"]),
        ("Electronic", ["Daft Punk", "The Chemical Brothers", "The Prodigy", "Kraftwerk"]),
        ("Techno", ["Carl Cox", "Sven Väth", "Charlotte de Witte", "Amelie Lens"]),
        ("R&B / Soul", ["Aretha Franklin", "Stevie Wonder", "Marvin Gaye", "Alicia Keys"]),
        ("Jazz", ["Miles Davis", "John Coltrane", "Ella Fitzgerald", "Louis Armstrong"]),
        ("Blues", ["B.B. King", "Muddy Waters", "John Lee Hooker", "Howlin' Wolf"]),
        ("Reggae", ["Bob Marley", "Peter Tosh", "Jimmy Cliff"]),
        ("Country", ["Johnny Cash", "Dolly Parton", "Willie Nelson"]),
        ("Schlager", ["Helene Fischer", "Andrea Berg", "Roland Kaiser"]),
        ("Klassik", ["Johann Sebastian Bach", "Wolfgang Amadeus Mozart", "Ludwig van Beethoven"])
    ]

    static func normalized(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func containsName(_ name: String, in text: String) -> Bool {
        let key = normalized(name)
        return !key.isEmpty && (" " + normalized(text) + " ").contains(" " + key + " ")
    }

    static func matches(_ profile: ArtistProfile, text: String) -> Bool {
        ([profile.name] + profile.aliases).contains { containsName($0, in: text) }
    }

    static func matches(_ profile: ArtistProfile, song: Song) -> Bool {
        profile.matchFields.contains { field in
            let value: String
            switch MatchField(rawValue: field) {
            case .artist: value = song.artist
            case .title: value = song.title
            case .album: value = song.album
            case .fileName: value = song.fileName
            case nil: return false
            }
            return matches(profile, text: value)
        }
    }

    static func tracks(in playlist: Playlist, songs: [Song], artists: [ArtistProfile]) -> [Song] {
        if playlist.artistName.isEmpty {
            let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            return playlist.songIDs.compactMap { lookup[$0] }
        }
        if let profile = artists.first(where: { normalized($0.name) == normalized(playlist.artistName) }) {
            return songs.filter { matches(profile, song: $0) }
        }
        return songs.filter { containsName(playlist.artistName, in: $0.artist) }
    }

    static func seed(in context: ModelContext) throws {
        var genres = try context.fetch(FetchDescriptor<MusicGenre>())
        var artists = try context.fetch(FetchDescriptor<ArtistProfile>())
        for (genreName, names) in starters {
            let genre = genres.first { normalized($0.name) == normalized(genreName) } ?? MusicGenre(name: genreName)
            if !genres.contains(where: { $0.id == genre.id }) { context.insert(genre); genres.append(genre) }
            for name in names where !artists.contains(where: { normalized($0.name) == normalized(name) }) {
                let aliases: [String]
                switch name {
                case "Tupac Shakur": aliases = ["2Pac", "Tupac"]
                case "The Notorious B.I.G.": aliases = ["Notorious BIG", "Biggie Smalls"]
                case "Die Ärzte": aliases = ["Die Aerzte"]
                case "AC/DC": aliases = ["ACDC"]
                default: aliases = []
                }
                let artist = ArtistProfile(name: name, aliases: aliases, genreID: genre.id)
                context.insert(artist)
                artists.append(artist)
            }
        }
        // Carry existing artist playlists into the searchable catalog.
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) where !playlist.artistName.isEmpty {
            if !artists.contains(where: { normalized($0.name) == normalized(playlist.artistName) }) {
                let profile = ArtistProfile(name: playlist.artistName)
                context.insert(profile)
                artists.append(profile)
            }
        }
        try reclassify(in: context)
    }

    static func classify(_ song: Song, artists: [ArtistProfile], genres: [MusicGenre] = []) {
        let unknown = ["", "unknown artist", "unbekannter kunstler"].contains(normalized(song.artist))
        let found = artists.filter { matches($0, song: song) }
        song.artistIDs = found.map(\.id)
        song.inferredGenreIDs = Array(Set(found.compactMap(\.genreID)))
        let importedIDs = genres.filter { normalized($0.name) == normalized(song.importedGenre) }.map(\.id)
        if song.originalGenreIDs.isEmpty, !importedIDs.isEmpty { song.originalGenreIDs = importedIDs }
        if let override = song.genreOverrideID { song.genreIDs = [override] }
        else { song.genreIDs = song.originalGenreIDs.isEmpty ? song.inferredGenreIDs : song.originalGenreIDs }
        if unknown, !found.isEmpty { song.artist = found.map(\.name).sorted().joined(separator: ", ") }
    }

    static func reclassify(in context: ModelContext) throws {
        let artists = try context.fetch(FetchDescriptor<ArtistProfile>())
        let genres = try context.fetch(FetchDescriptor<MusicGenre>())
        for song in try context.fetch(FetchDescriptor<Song>()) { classify(song, artists: artists, genres: genres) }
        try context.save()
    }
}

struct GenreLibraryView: View {
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @Query private var artists: [ArtistProfile]
    @Query private var songs: [Song]
    @State private var query = ""

    var body: some View {
        List {
            Section {
                ForEach(genres.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { genre in
                    NavigationLink { GenreDetailView(genre: genre) } label: {
                        HStack {
                            Label(genre.name, systemImage: "music.note.list")
                            Spacer()
                            Text("\(songs.filter { $0.genreIDs.contains(genre.id) }.count) Titel")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Die Startzuordnungen sind grobe Musikrichtungen. Du kannst das Genre eines Künstlers jederzeit ändern.")
            }
            if !query.isEmpty {
                Section("Gefundene Künstler") {
                    ForEach(artists.filter { $0.name.localizedStandardContains(query) || $0.aliases.contains(where: { $0.localizedStandardContains(query) }) }) { artist in
                        NavigationLink(artist.name) { CatalogArtistView(artist: artist) }
                    }
                }
            }
            if query.isEmpty {
            Section("Ohne Genre") {
                ForEach(artists.filter { $0.genreID == nil }) { artist in
                    NavigationLink(artist.name) { CatalogArtistView(artist: artist) }
                }
                NavigationLink("Noch nicht zugeordnete Titel") {
                    List(songs.filter { $0.genreIDs.isEmpty }) { SongRow(song: $0) }
                        .navigationTitle("Ohne Zuordnung")
                }
            }
            }
        }
        .navigationTitle("Genres & Künstler")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Genres oder Künstler suchen")
    }
}

struct GenreDetailView: View {
    let genre: MusicGenre
    @Query(sort: \ArtistProfile.name) private var artists: [ArtistProfile]
    @Query(sort: \Song.title) private var songs: [Song]
    @State private var showingCreate = false
    @State private var query = ""

    var body: some View {
        List {
            Section("Künstler") {
                ForEach(artists.filter { $0.genreID == genre.id && (query.isEmpty || $0.name.localizedStandardContains(query)) }) { artist in
                    NavigationLink { CatalogArtistView(artist: artist) } label: {
                        HStack {
                            Text(artist.name)
                            Spacer()
                            Text("\(songs.filter { $0.artistIDs.contains(artist.id) }.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Heruntergeladene Titel") {
                ForEach(songs.filter { $0.genreIDs.contains(genre.id) && (query.isEmpty || "\($0.title) \($0.artist)".localizedStandardContains(query)) }) { SongRow(song: $0) }
            }
        }
        .navigationTitle(genre.name)
        .searchable(text: $query, prompt: "Künstler oder Titel suchen")
        .toolbar { Button("Künstler hinzufügen", systemImage: "person.badge.plus") { showingCreate = true } }
        .sheet(isPresented: $showingCreate) { ArtistEditorView(initialGenreID: genre.id) }
    }
}

struct CatalogArtistView: View {
    let artist: ArtistProfile
    @Query(sort: \Song.title) private var songs: [Song]
    @State private var editing = false

    var body: some View {
        List {
            let tracks = songs.filter { $0.artistIDs.contains(artist.id) }
            if tracks.isEmpty {
                ContentUnavailableView("Noch keine Titel", systemImage: "music.note", description: Text("Passende importierte Songs erscheinen hier automatisch."))
            } else {
                ForEach(tracks) { SongRow(song: $0) }
            }
        }
        .navigationTitle(artist.name)
        .toolbar { Button("Bearbeiten") { editing = true } }
        .sheet(isPresented: $editing) { ArtistEditorView(artist: artist) }
    }
}

struct ArtistEditorView: View {
    var artist: ArtistProfile? = nil
    var createPlaylist = false
    var initialGenreID: UUID? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @Query private var artists: [ArtistProfile]
    @State private var name = ""
    @State private var aliases = ""
    @State private var genreID: UUID?
    @State private var newGenre = ""
    @State private var errorMessage: String?
    @State private var initialized = false
    @State private var matchFields = Set(MusicCatalog.MatchField.allCases.map(\.rawValue))

    var body: some View {
        NavigationStack {
            Form {
                Section("Künstler") {
                    NavigationLink {
                        ArtistNamePickerView { profile in
                            name = profile.name
                            aliases = profile.aliases.joined(separator: ", ")
                            genreID = profile.genreID
                            matchFields = Set(profile.matchFields)
                        }
                    } label: { Label("Bekannte Künstler durchsuchen", systemImage: "magnifyingglass") }
                    TextField("Künstlername", text: $name)
                        .autocorrectionDisabled()
                    TextField("Weitere Schreibweisen, mit Komma trennen", text: $aliases)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(MusicCatalog.MatchField.allCases) { field in
                        Toggle(field.label, isOn: Binding(
                            get: { matchFields.contains(field.rawValue) },
                            set: { enabled in
                                if enabled { matchFields.insert(field.rawValue) }
                                else { matchFields.remove(field.rawValue) }
                            }
                        ))
                    }
                } header: { Text("Namen und Schreibweisen suchen in") }
                footer: { Text("Ein Treffer in einem ausgewählten Feld genügt. Groß- und Kleinschreibung, Akzente und Satzzeichen werden beim Vergleich vereinheitlicht.") }
                Section {
                    NavigationLink {
                        GenrePickerView(selection: $genreID)
                    } label: {
                        HStack {
                            Text("Genre")
                            Spacer()
                            Text(genres.first { $0.id == genreID }?.name ?? "Bitte auswählen")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!newGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Oder neues Genre erstellen", text: $newGenre)
                } header: {
                    Text("Genre auswählen oder erstellen")
                } footer: {
                    Text("Die Zuordnung gilt für vorhandene und künftig importierte Titel dieses Künstlers. Bei bekannten Namen wird das hinterlegte Genre vorgeschlagen.")
                }
            }
            .navigationTitle(artist == nil ? "Create Artist +" : "Künstler bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern", action: save)
                        .disabled(matchFields.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (genreID == nil && newGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                name = artist?.name ?? ""
                aliases = artist?.aliases.joined(separator: ", ") ?? ""
                genreID = artist?.genreID ?? initialGenreID
                matchFields = Set(artist?.matchFields ?? MusicCatalog.MatchField.allCases.map(\.rawValue))
            }
            .onChange(of: name) { _, value in
                if artist == nil, let known = artists.first(where: { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(value) }) {
                    genreID = known.genreID
                    aliases = known.aliases.joined(separator: ", ")
                    matchFields = Set(known.matchFields)
                }
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGenre = newGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        if let duplicate = artists.first(where: { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(cleanName) }),
           let artist, duplicate.id != artist.id {
            errorMessage = "Ein Künstler mit diesem Namen existiert bereits."
            return
        }
        do {
            var selectedID = genreID
            if !cleanGenre.isEmpty {
                let genre = genres.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(cleanGenre) } ?? MusicGenre(name: cleanGenre)
                if !genres.contains(where: { $0.id == genre.id }) { context.insert(genre) }
                selectedID = genre.id
            }
            guard let selectedID else { return }
            let profile = artist ?? artists.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(cleanName) } ?? ArtistProfile(name: cleanName)
            if !artists.contains(where: { $0.id == profile.id }) { context.insert(profile) }
            let oldName = profile.name
            profile.name = cleanName
            profile.aliases = aliases.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if MusicCatalog.normalized(oldName) != MusicCatalog.normalized(cleanName),
               !profile.aliases.contains(oldName) { profile.aliases.append(oldName) }
            profile.genreID = selectedID
            profile.matchFields = matchFields.sorted()
            let playlists = try context.fetch(FetchDescriptor<Playlist>())
            for playlist in playlists where MusicCatalog.normalized(playlist.artistName) == MusicCatalog.normalized(oldName) {
                playlist.artistName = cleanName
            }
            if createPlaylist && !playlists.contains(where: { MusicCatalog.normalized($0.artistName) == MusicCatalog.normalized(cleanName) }) {
                context.insert(Playlist(name: cleanName, artistName: cleanName))
            }
            try MusicCatalog.reclassify(in: context)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct GenrePickerView: View {
    @Binding var selection: UUID?
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @State private var query = ""

    var body: some View {
        List {
            let results = genres.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            ForEach(results) { genre in
                Button {
                    selection = genre.id
                    dismiss()
                } label: {
                    HStack {
                        Text(genre.name).foregroundStyle(.primary)
                        Spacer()
                        if genre.id == selection { Image(systemName: "checkmark") }
                    }
                }
            }
            if results.isEmpty {
                Text("Kein Genre gefunden. Du kannst im Formular ein neues erstellen.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Genre auswählen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Genre suchen")
    }
}

struct ArtistNamePickerView: View {
    let onSelect: (ArtistProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ArtistProfile.name) private var artists: [ArtistProfile]
    @State private var query = ""

    var body: some View {
        List {
            let results = artists.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.aliases.contains(where: { $0.localizedStandardContains(query) }) }
            ForEach(results) { profile in
                Button(profile.name) {
                    onSelect(profile)
                    dismiss()
                }
                .foregroundStyle(.primary)
            }
            if results.isEmpty { Text("Kein Künstler gefunden. Eigene Namen kannst du im Formular eingeben.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Künstler auswählen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Künstler suchen")
    }
}
