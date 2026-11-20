import Foundation
import SwiftData
import SwiftUI

@MainActor
enum CatalogUpdates {
    private static var pending: (id: UUID, task: Task<Void, Error>)?

    static func finishPendingWrite() async {
        while let write = pending {
            _ = await write.task.result
            if pending?.id == write.id { pending = nil }
        }
    }

    static func write(in context: ModelContext, operation: @escaping @Sendable (ModelContext) throws -> Void) async throws {
        let previous = pending?.task
        let id = UUID()
        let task = Task {
            _ = await previous?.result
            // Include staged songs already inserted by a local bulk import.
            if context.hasChanges { try context.save() }
            let container = context.container
            try await Task.detached(priority: .userInitiated) {
                let writer = CatalogWriter(modelContainer: container)
                try await writer.write(operation)
            }.value
        }
        pending = (id, task)
        defer { if pending?.id == id { pending = nil } }
        try await task.value
    }
}

@ModelActor private actor CatalogWriter {
    func write(_ operation: @Sendable (ModelContext) throws -> Void) throws {
        modelContext.autosaveEnabled = false
        try operation(modelContext)
    }
}

// A deliberately broad starter classification; the user's assignments take precedence.
enum MusicCatalog {
    enum MatchField: String, CaseIterable, Identifiable, Sendable {
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

    struct ArtistEdit: Sendable {
        let id: UUID?
        let name: String
        let aliases: [String]
        let fields: [String]
        let genreID: UUID?
        let newGenre: String
        let createPlaylist: Bool
    }

    enum ArtistEditError: Error {
        case invalidName, duplicateName, missingArtist, missingGenre
    }

    private static let matchingLocale = Locale(identifier: "en_US_POSIX")
    private static let separators = CharacterSet.alphanumerics.inverted
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
        text.lowercased(with: matchingLocale)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: matchingLocale)
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func containsName(_ name: String, in text: String) -> Bool {
        containsNormalizedName(normalized(name), in: text)
    }

    private static func artistNameKey(_ name: String) -> String {
        let key = normalized(name)
        return key.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : key
    }

    static func artistProfile(named name: String, in artists: [ArtistProfile]) -> ArtistProfile? {
        let key = artistNameKey(name)
        guard !key.isEmpty else { return nil }
        return artists.first { artistNameKey($0.name) == key }
    }

    private static func containsNormalizedName(_ key: String, in text: String) -> Bool {
        return !key.isEmpty && (" " + normalized(text) + " ").contains(" " + key + " ")
    }

    static func matches(_ profile: ArtistProfile, text: String) -> Bool {
        let text = " " + normalized(text) + " "
        return MatchRule(profile).names.contains { text.contains($0) }
    }

    static func matches(_ profile: ArtistProfile, song: Song) -> Bool {
        let rule = MatchRule(profile)
        return rule.matches(normalizedFields(for: song, fields: rule.fields))
    }

    private struct MatchRule {
        let id: UUID
        let name: String
        let genreID: UUID?
        let fields: Set<MatchField>
        let names: [String]

        init(_ profile: ArtistProfile) {
            id = profile.id
            name = profile.name
            genreID = profile.genreID
            fields = Set(profile.matchFields.compactMap(MatchField.init(rawValue:)))
            names = ([name] + profile.aliases).map(normalized).filter { !$0.isEmpty }.map { " " + $0 + " " }
        }

        func matches(_ values: [MatchField: String]) -> Bool {
            fields.contains { field in
                guard let value = values[field] else { return false }
                return names.contains { value.contains($0) }
            }
        }
    }

    private static func normalizedFields(for song: Song, fields: Set<MatchField>) -> [MatchField: String] {
        var values: [MatchField: String] = [:]
        for field in fields {
            let value: String
            switch field {
            case .artist: value = song.artist
            case .title: value = song.title
            case .album: value = song.album
            case .fileName: value = song.fileName
            }
            values[field] = " " + normalized(value) + " "
        }
        return values
    }

    static func tracks(in playlist: Playlist, songs: [Song], artists: [ArtistProfile]) -> [Song] {
        if playlist.artistName.isEmpty {
            let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            return playlist.songIDs.compactMap { lookup[$0] }
        }
        return songs.filter(artistTrackMatcher(for: playlist.artistName, artists: artists))
    }

    static func artistTrackMatcher(for name: String, artists: [ArtistProfile]) -> (Song) -> Bool {
        if let profile = artistProfile(named: name, in: artists) {
            let rule = MatchRule(profile)
            return { rule.matches(normalizedFields(for: $0, fields: rule.fields)) }
        }
        let key = normalized(name)
        return { containsNormalizedName(key, in: $0.artist) }
    }

    static func seed(in context: ModelContext) throws {
        var genres = Dictionary(try context.fetch(FetchDescriptor<MusicGenre>()).map { (normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var names = Set(try context.fetch(FetchDescriptor<ArtistProfile>()).map { artistNameKey($0.name) })
        for (genreName, starterNames) in starters {
            let key = normalized(genreName)
            let genre = genres[key] ?? MusicGenre(name: genreName)
            if genres[key] == nil { context.insert(genre); genres[key] = genre }
            for name in starterNames where names.insert(normalized(name)).inserted {
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
            }
        }
        // Carry existing artist playlists into the searchable catalog.
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) where !playlist.artistName.isEmpty {
            if names.insert(artistNameKey(playlist.artistName)).inserted {
                context.insert(ArtistProfile(name: playlist.artistName))
            }
        }
        try reclassify(in: context)
    }

    static func classify(_ song: Song, artists: [ArtistProfile], genres: [MusicGenre] = []) {
        Classifier(artists: artists, genres: genres).classify(song)
    }

    private struct Classifier {
        let rules: [MatchRule]
        let fields: Set<MatchField>
        let genresByName: [String: [UUID]]

        init(artists: [ArtistProfile], genres: [MusicGenre]) {
            rules = artists.map(MatchRule.init)
            fields = rules.reduce(into: [.artist]) { $0.formUnion($1.fields) }
            genresByName = Dictionary(grouping: genres) { normalized($0.name) }.mapValues { $0.map(\.id) }
        }

        func classify(_ song: Song) {
            let values = normalizedFields(for: song, fields: fields)
            let found = rules.filter { $0.matches(values) }
            let artistIDs = found.map(\.id)
            if song.artistIDs != artistIDs && Set(song.artistIDs) != Set(artistIDs) { song.artistIDs = artistIDs }
            let inferred = Set(found.compactMap(\.genreID))
            if Set(song.inferredGenreIDs) != inferred { song.inferredGenreIDs = inferred.sorted() }
            if song.originalGenreIDs.isEmpty, !song.importedGenre.isEmpty, let imported = genresByName[normalized(song.importedGenre)] {
                song.originalGenreIDs = imported
            }
            let genres = song.genreOverrideID.map { [$0] } ?? (song.originalGenreIDs.isEmpty ? song.inferredGenreIDs : song.originalGenreIDs)
            if song.genreIDs != genres { song.genreIDs = genres }
            if ["  ", " unknown artist ", " unbekannter kunstler "].contains(values[.artist]), !found.isEmpty {
                let artistName = found.map(\.name).sorted().joined(separator: ", ")
                if song.artist != artistName { song.artist = artistName }
            }
        }
    }

    static func reclassify(in context: ModelContext) throws {
        try reclassify(in: context, changedArtist: nil, addedGenreKey: nil)
    }

    private static func reclassify(in context: ModelContext, changedArtist: MatchRule?, addedGenreKey: String?) throws {
        let artists = try context.fetch(FetchDescriptor<ArtistProfile>())
        let genres = try context.fetch(FetchDescriptor<MusicGenre>())
        let classifier = Classifier(artists: artists, genres: genres)
        for song in try context.fetch(FetchDescriptor<Song>()) {
            if let changedArtist, !song.artistIDs.contains(changedArtist.id) {
                let matchesNewGenre = addedGenreKey.map { song.originalGenreIDs.isEmpty && !song.importedGenre.isEmpty && normalized(song.importedGenre) == $0 } ?? false
                guard matchesNewGenre || changedArtist.matches(normalizedFields(for: song, fields: changedArtist.fields)) else { continue }
            }
            classifier.classify(song)
        }
        if context.hasChanges { try context.save() }
    }

    static func saveArtist(_ edit: ArtistEdit, in context: ModelContext) throws {
        let nameKey = artistNameKey(edit.name)
        guard !nameKey.isEmpty else { throw ArtistEditError.invalidName }
        let artists = try context.fetch(FetchDescriptor<ArtistProfile>())
        let matching = artistProfile(named: edit.name, in: artists)
        let profile: ArtistProfile
        if let id = edit.id {
            guard let stored = artists.first(where: { $0.id == id }) else { throw ArtistEditError.missingArtist }
            if let matching, matching.id != id { throw ArtistEditError.duplicateName }
            profile = stored
        } else {
            profile = matching ?? ArtistProfile(name: edit.name)
        }
        var genreID = edit.genreID
        var addedGenreKey: String?
        if !edit.newGenre.isEmpty {
            let genres = try context.fetch(FetchDescriptor<MusicGenre>())
            let genreKey = normalized(edit.newGenre)
            if let genre = genres.first(where: { normalized($0.name) == genreKey }) {
                genreID = genre.id
            } else {
                let genre = MusicGenre(name: edit.newGenre)
                context.insert(genre)
                genreID = genre.id
                addedGenreKey = genreKey
            }
        } else if let selected = genreID {
            let descriptor = FetchDescriptor<MusicGenre>(predicate: #Predicate { $0.id == selected })
            guard try context.fetchCount(descriptor) > 0 else { throw ArtistEditError.missingGenre }
        }

        let isNew = profile.modelContext == nil
        let nameChanged = profile.name != edit.name
        let oldNameKey = artistNameKey(profile.name)
        var aliases = edit.aliases
        if oldNameKey != nameKey, !aliases.contains(profile.name) { aliases.append(profile.name) }
        let needsReclassification = isNew || nameChanged || profile.aliases != aliases || profile.genreID != genreID || profile.matchFields != edit.fields
        if isNew { context.insert(profile) }
        if nameChanged { profile.name = edit.name }
        if profile.aliases != aliases { profile.aliases = aliases }
        if profile.genreID != genreID { profile.genreID = genreID }
        if profile.matchFields != edit.fields { profile.matchFields = edit.fields }
        if edit.createPlaylist || nameChanged {
            let playlists = try context.fetch(FetchDescriptor<Playlist>())
            for playlist in playlists where !playlist.artistName.isEmpty && artistNameKey(playlist.artistName) == oldNameKey {
                if playlist.artistName != edit.name { playlist.artistName = edit.name }
            }
            if edit.createPlaylist && !playlists.contains(where: { !$0.artistName.isEmpty && artistNameKey($0.artistName) == nameKey }) {
                context.insert(Playlist(name: edit.name, artistName: edit.name))
            }
        }
        if needsReclassification {
            try reclassify(in: context, changedArtist: MatchRule(profile), addedGenreKey: addedGenreKey)
        } else if context.hasChanges {
            try context.save()
        }
    }

    static func trackCounts(in songs: [Song], by field: KeyPath<Song, [UUID]>) -> [UUID: Int] {
        songs.reduce(into: [:]) { counts, song in
            for id in Set(song[keyPath: field]) { counts[id, default: 0] += 1 }
        }
    }
}

struct GenreLibraryView: View {
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @Query private var artists: [ArtistProfile]
    @Query private var songs: [Song]
    @State private var query = ""

    var body: some View {
        let trackCounts = MusicCatalog.trackCounts(in: songs, by: \.genreIDs)
        List {
            Group {
            Section {
                ForEach(genres.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { genre in
                    NavigationLink { GenreDetailView(genre: genre) } label: {
                        HStack {
                            Label(genre.name, systemImage: "music.note.list").fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text("\(trackCounts[genre.id, default: 0]) Titel")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
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
                    List(songs.filter { $0.genreIDs.isEmpty }) {
                        SongRow(song: $0).listRowBackground(AppTheme.surface)
                    }
                        .musicScreen()
                        .navigationTitle("Ohne Zuordnung")
                }
            }
            }
            }.listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .musicScreen()
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
        let trackCounts = MusicCatalog.trackCounts(in: songs, by: \.artistIDs)
        List {
            Group {
            Section("Künstler") {
                ForEach(artists.filter { $0.genreID == genre.id && (query.isEmpty || $0.name.localizedStandardContains(query)) }) { artist in
                    NavigationLink { CatalogArtistView(artist: artist) } label: {
                        HStack {
                            Text(artist.name)
                            Spacer()
                            Text("\(trackCounts[artist.id, default: 0])")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
            Section("Heruntergeladene Titel") {
                ForEach(songs.filter { $0.genreIDs.contains(genre.id) && (query.isEmpty || "\($0.title) \($0.artist)".localizedStandardContains(query)) }) { SongRow(song: $0) }
            }
            }.listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .musicScreen()
        .navigationTitle(genre.name)
        .searchable(text: $query, prompt: "Künstler oder Titel suchen")
        .toolbar { Button("Künstler hinzufügen", systemImage: "person.badge.plus") { showingCreate = true } }
        .sheet(isPresented: $showingCreate) { ArtistEditorView(initialGenreID: genre.id).musicScreen() }
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
                ForEach(tracks) { SongRow(song: $0) }.listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .musicScreen()
        .navigationTitle(artist.name)
        .toolbar { Button("Bearbeiten") { editing = true } }
        .sheet(isPresented: $editing) { ArtistEditorView(artist: artist).musicScreen() }
    }
}

struct ArtistEditorView: View {
    private enum Field: Hashable { case name, aliases, genre }

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
    @State private var isSaving = false
    @State private var matchFields = Set(MusicCatalog.MatchField.allCases.map(\.rawValue))
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Group {
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
                        .focused($focusedField, equals: .name)
                        .autocorrectionDisabled()
                    TextField("Weitere Schreibweisen, mit Komma trennen", text: $aliases)
                        .focused($focusedField, equals: .aliases)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(MusicCatalog.MatchField.allCases) { field in
                        Toggle(isOn: Binding(
                            get: { matchFields.contains(field.rawValue) },
                            set: { enabled in
                                if enabled { matchFields.insert(field.rawValue) }
                                else { matchFields.remove(field.rawValue) }
                            }
                        )) { Text(LocalizedStringKey(field.label)) }
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
                            Group {
                                if let genre = genres.first(where: { $0.id == genreID }) { Text(genre.name) }
                                else { Text("Ohne Genre") }
                            }.foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .disabled(!newGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Oder neues Genre erstellen", text: $newGenre)
                        .focused($focusedField, equals: .genre)
                } header: {
                    Text("Genre auswählen oder erstellen")
                } footer: {
                    Text("Die Zuordnung gilt für vorhandene und künftig importierte Titel dieses Künstlers. Bei bekannten Namen wird das hinterlegte Genre vorgeschlagen.")
                }
                }.listRowBackground(AppTheme.surface)
            }
            .disabled(isSaving)
            .musicScreen()
            .navigationTitle(Text(LocalizedStringKey(artist == nil ? "Create Artist +" : "Künstler bearbeiten")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().accessibilityLabel("Speichern")
                    } else {
                        Button("Speichern", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
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
                if artist == nil, let known = MusicCatalog.artistProfile(named: value, in: artists) {
                    genreID = known.genreID
                    aliases = known.aliases.joined(separator: ", ")
                    matchFields = Set(known.matchFields)
                }
            }
            .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(L10n.text(errorMessage ?? "")) }
        }
        .interactiveDismissDisabled(isSaving)
        .musicScreen()
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !cleanName.isEmpty else { return }
        let edit = MusicCatalog.ArtistEdit(
            id: artist?.id, name: cleanName,
            aliases: aliases.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            fields: matchFields.sorted(), genreID: genreID,
            newGenre: newGenre.trimmingCharacters(in: .whitespacesAndNewlines), createPlaylist: createPlaylist
        )
        focusedField = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await CatalogUpdates.write(in: context) { try MusicCatalog.saveArtist(edit, in: $0) }
                dismiss()
            } catch MusicCatalog.ArtistEditError.duplicateName {
                errorMessage = "Ein Künstler mit diesem Namen existiert bereits."
            } catch MusicCatalog.ArtistEditError.missingGenre {
                genreID = nil
                errorMessage = "Das gewählte Genre ist nicht mehr vorhanden. Wähle ein anderes oder speichere ohne Genre."
            } catch MusicCatalog.ArtistEditError.missingArtist {
                errorMessage = "Der Künstler wurde inzwischen entfernt."
            } catch {
                errorMessage = L10n.error(error)
            }
        }
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
            if query.isEmpty {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("Ohne Genre").foregroundStyle(AppTheme.text)
                        Spacer()
                        if selection == nil { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityAddTraits(selection == nil ? .isSelected : [])
                .listRowBackground(AppTheme.surface)
            }
            ForEach(results) { genre in
                Button {
                    selection = genre.id
                    dismiss()
                } label: {
                    HStack {
                        Text(genre.name).foregroundStyle(AppTheme.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if genre.id == selection { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityAddTraits(genre.id == selection ? .isSelected : [])
                .listRowBackground(AppTheme.surface)
            }
            if results.isEmpty {
                Text("Kein Genre gefunden. Du kannst im Formular ein neues erstellen.")
                    .foregroundStyle(AppTheme.secondaryText)
                    .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .musicScreen()
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
                Button {
                    onSelect(profile)
                    dismiss()
                } label: {
                    Text(profile.name).frame(minHeight: 44, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(AppTheme.text)
                .listRowBackground(AppTheme.surface)
            }
            if results.isEmpty {
                Text("Kein Künstler gefunden. Eigene Namen kannst du im Formular eingeben.")
                    .foregroundStyle(AppTheme.secondaryText).listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .musicScreen()
        .navigationTitle("Künstler auswählen")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Künstler suchen")
    }
}
