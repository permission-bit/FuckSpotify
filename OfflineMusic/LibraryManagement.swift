import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
enum SongGenreStore {
    static func apply(_ song: Song, genreName: String, context: ModelContext) throws {
        let cleanName = genreName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let genres = try context.fetch(FetchDescriptor<MusicGenre>())
        let genre = genres.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(cleanName) } ?? MusicGenre(name: cleanName)
        if !genres.contains(where: { $0.id == genre.id }) { context.insert(genre) }
        song.genreOverrideID = genre.id
        song.genreIDs = [genre.id]
        try context.save()
    }

    static func restore(_ song: Song, context: ModelContext) {
        do {
            var originalIDs = song.originalGenreIDs
            if originalIDs.isEmpty, !song.importedGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let genres = try context.fetch(FetchDescriptor<MusicGenre>())
                let genre = genres.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(song.importedGenre) } ?? MusicGenre(name: song.importedGenre)
                if !genres.contains(where: { $0.id == genre.id }) { context.insert(genre) }
                originalIDs = [genre.id]
                song.originalGenreIDs = originalIDs
            }
            song.genreOverrideID = nil
            song.genreIDs = originalIDs.isEmpty ? song.inferredGenreIDs : originalIDs
            try context.save()
        } catch { }
    }
}

struct SongGenreEditorView: View {
    let song: Song
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MusicGenre.name) private var genres: [MusicGenre]
    @State private var selectedGenreID: UUID?
    @State private var customGenre = ""
    @State private var errorMessage: String?

    init(song: Song) {
        self.song = song
        _selectedGenreID = State(initialValue: song.genreOverrideID ?? song.genreIDs.first)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Aktives Genre") {
                    Text(activeGenreName).font(.headline)
                    if song.genreOverrideID != nil { Label("Manuell für diesen Titel gesetzt", systemImage: "slider.horizontal.3") }
                }
                Section("Genre auswählen") {
                    Picker("Genre", selection: $selectedGenreID) {
                        Text("Bitte auswählen").tag(nil as UUID?)
                        ForEach(genres) { genre in Text(genre.name).tag(Optional(genre.id)) }
                    }
                    .disabled(!customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Oder eigenes Genre", text: $customGenre)
                }
                Section("Importierte Angaben") {
                    LabeledContent("Importiertes Genre", value: song.importedGenre.isEmpty ? "Nicht vorhanden" : song.importedGenre)
                    LabeledContent("Automatische Zuordnung", value: inferredGenreNames.isEmpty ? "Nicht vorhanden" : inferredGenreNames)
                }
                if song.genreOverrideID != nil {
                    Section {
                        Button("Originalgenre wiederherstellen", systemImage: "arrow.uturn.backward") {
                            SongGenreStore.restore(song, context: context)
                            dismiss()
                        }
                    } footer: {
                        Text("Dies stellt das importierte Genre wieder her. Falls keines vorhanden ist, wird die automatische Künstlerzuordnung verwendet.")
                    }
                }
            }
            .navigationTitle("Genre bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(selectedGenreID == nil && customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Genre konnte nicht gespeichert werden", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var activeGenreName: String { genreNames(for: song.genreIDs).joined(separator: ", ").isEmpty ? "Nicht zugeordnet" : genreNames(for: song.genreIDs).joined(separator: ", ") }
    private var inferredGenreNames: String { genreNames(for: song.inferredGenreIDs).joined(separator: ", ") }
    private func genreNames(for ids: [UUID]) -> [String] { genres.filter { ids.contains($0.id) }.map(\.name) }

    private func save() {
        do {
            if !customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SongGenreStore.apply(song, genreName: customGenre, context: context)
            } else if let selectedGenreID, let genre = genres.first(where: { $0.id == selectedGenreID }) {
                try SongGenreStore.apply(song, genreName: genre.name, context: context)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

enum DuplicateKind: String, Sendable {
    case exact
    case possible

    var title: String { self == .exact ? "Exakte Duplikate" : "Mögliche Duplikate" }
    var detail: String { self == .exact ? "Gleicher SHA-256-Dateiinhalt" : "Gleiche Metadaten und nahezu gleiche Dauer" }
}

struct DuplicateSongInput: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let fileName: String
    let path: String
}

struct DuplicateSongRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let fileName: String
    let path: String
    let fileSize: Int64
    let fileFormat: String

    var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

struct DuplicateGroup: Identifiable, Sendable {
    let kind: DuplicateKind
    let records: [DuplicateSongRecord]
    var id: String { "\(kind.rawValue)-" + records.map { $0.id.uuidString }.sorted().joined(separator: "-") }
}

enum DuplicateScanner {
    static func scan(_ inputs: [DuplicateSongInput]) async -> [DuplicateGroup] {
        await Task.detached(priority: .utility) { scanSynchronously(inputs) }.value
    }

    private static func scanSynchronously(_ inputs: [DuplicateSongInput]) -> [DuplicateGroup] {
        let records = inputs.compactMap { input -> DuplicateSongRecord? in
            guard let size = fileSize(at: input.path) else { return nil }
            return DuplicateSongRecord(id: input.id, title: input.title, artist: input.artist, album: input.album, duration: input.duration, fileName: input.fileName, path: input.path, fileSize: size, fileFormat: URL(fileURLWithPath: input.fileName).pathExtension.uppercased())
        }

        let sameSizeCandidates = Dictionary(grouping: records, by: \.fileSize).values.filter { $0.count > 1 }
        var exactGroups: [DuplicateGroup] = []
        var exactIDs = Set<UUID>()
        for candidates in sameSizeCandidates {
            let byHash = Dictionary(grouping: candidates.compactMap { record -> (String, DuplicateSongRecord)? in
                guard let hash = streamingHash(at: record.path) else { return nil }
                return (hash, record)
            }, by: { $0.0 })
            for matches in byHash.values where matches.count > 1 {
                let groupRecords = matches.map(\.1).sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                exactGroups.append(DuplicateGroup(kind: .exact, records: groupRecords))
                exactIDs.formUnion(groupRecords.map(\.id))
            }
        }

        let possibleCandidates = records.filter { !exactIDs.contains($0.id) && metadataKey(for: $0) != nil }
        var possibleGroups: [DuplicateGroup] = []
        for candidates in Dictionary(grouping: possibleCandidates, by: { metadataKey(for: $0)! }).values {
            let ordered = candidates.sorted { $0.duration < $1.duration }
            var current: [DuplicateSongRecord] = []
            for record in ordered {
                if let last = current.last, abs(record.duration - last.duration) > 2 {
                    if current.count > 1 { possibleGroups.append(DuplicateGroup(kind: .possible, records: current)) }
                    current = []
                }
                current.append(record)
            }
            if current.count > 1 { possibleGroups.append(DuplicateGroup(kind: .possible, records: current)) }
        }
        return exactGroups.sorted { $0.id < $1.id } + possibleGroups.sorted { $0.id < $1.id }
    }

    private static func metadataKey(for record: DuplicateSongRecord) -> String? {
        let title = normalized(record.title)
        let artist = normalized(record.artist)
        let album = normalized(record.album)
        guard !title.isEmpty, !artist.isEmpty || !album.isEmpty else { return nil }
        return "\(title)|\(artist)|\(album)"
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func fileSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func streamingHash(at path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1_048_576), !read.isEmpty else { break }
                chunk = read
            } catch { return nil }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeDeletionIDs(groups: [DuplicateGroup], removalIDs: Set<UUID>) -> (ids: Set<UUID>, blockedGroupCount: Int) {
        var safeIDs = Set<UUID>()
        var blockedGroupCount = 0
        for group in groups {
            let selected = group.records.filter { removalIDs.contains($0.id) }
            guard !selected.isEmpty else { continue }
            if group.records.contains(where: { !removalIDs.contains($0.id) && $0.isAvailable }) {
                safeIDs.formUnion(selected.map(\.id))
            } else {
                blockedGroupCount += 1
            }
        }
        return (safeIDs, blockedGroupCount)
    }
}

struct DuplicateManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: AudioPlayer
    @Query(sort: \Song.title) private var songs: [Song]
    @State private var groups: [DuplicateGroup] = []
    @State private var keepIDs: [String: UUID] = [:]
    @State private var removalIDs = Set<UUID>()
    @State private var isScanning = false
    @State private var showingDeleteConfirmation = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if isScanning {
                    Section { HStack { ProgressView(); Text("Musikdateien werden geprüft …") } }
                } else if groups.isEmpty {
                    ContentUnavailableView("Keine Duplikate gefunden", systemImage: "checkmark.circle", description: Text("Scanne die Bibliothek erneut, wenn du neue Musik importiert hast."))
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                duplicateRow(record, in: group)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(group.kind.title, systemImage: group.kind == .exact ? "checkmark.seal" : "questionmark.circle")
                                Text(group.kind.detail).font(.caption).textCase(nil)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Duplikate")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Scannen", systemImage: "arrow.clockwise") { scan() }.disabled(isScanning) }
                ToolbarItem(placement: .bottomBar) {
                    Button("Markierte löschen (\(removalIDs.count))", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                        .disabled(removalIDs.isEmpty || isScanning)
                }
            }
            .confirmationDialog("Markierte Duplikate löschen?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Dateien und Bibliothekseinträge löschen", role: .destructive) { deleteMarked() }
            } message: { Text("Mindestens eine zugängliche Version jeder Gruppe bleibt erhalten.") }
            .alert("Duplikatverwaltung", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .task { scan() }
        }
    }

    @ViewBuilder
    private func duplicateRow(_ record: DuplicateSongRecord, in group: DuplicateGroup) -> some View {
        let keepID = keepIDs[group.id] ?? group.records.first?.id
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                    Text("\(record.artist) · \(record.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(durationText(record.duration)) · \(fileSizeText(record.fileSize)) · \(record.fileFormat.isEmpty ? "Audio" : record.fileFormat)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Vorschau", systemImage: "play.fill") { preview(record) }.labelStyle(.iconOnly)
            }
            HStack {
                Button(record.id == keepID ? "Wird behalten" : "Behalten") {
                    keepIDs[group.id] = record.id
                    removalIDs.remove(record.id)
                }
                .buttonStyle(.bordered)
                .tint(record.id == keepID ? Color(red: 0.20, green: 0.60, blue: 0.42) : .secondary)
                Spacer()
                Toggle("Löschen", isOn: Binding(
                    get: { removalIDs.contains(record.id) },
                    set: { marked in
                        if marked, record.id != keepIDs[group.id] { removalIDs.insert(record.id) }
                        else { removalIDs.remove(record.id) }
                    }
                ))
                .labelsHidden()
                .disabled(record.id == keepID)
            }
        }
        .opacity(record.isAvailable ? 1 : 0.5)
    }

    private func scan() {
        isScanning = true
        let inputs = songs.map { song in
            DuplicateSongInput(id: song.id, title: song.title, artist: song.artist, album: song.album, duration: song.duration, fileName: song.fileName, path: LibraryStore.musicURL.appendingPathComponent(song.fileName).path)
        }
        Task {
            let results = await DuplicateScanner.scan(inputs)
            groups = results
            keepIDs = Dictionary(uniqueKeysWithValues: results.compactMap { group in group.records.first.map { (group.id, $0.id) } })
            removalIDs.removeAll()
            isScanning = false
        }
    }

    private func preview(_ record: DuplicateSongRecord) {
        guard let song = songs.first(where: { $0.id == record.id }) else { return }
        player.play(song)
    }

    private func deleteMarked() {
        let deletion = DuplicateScanner.safeDeletionIDs(groups: groups, removalIDs: removalIDs)
        let safeIDs = deletion.ids
        let blockedGroups = deletion.blockedGroupCount
        guard !safeIDs.isEmpty else {
            message = "Für jede Gruppe muss mindestens eine zugängliche Version behalten werden."
            return
        }
        var deletedIDs = Set<UUID>()
        var failed = 0
        for song in songs where safeIDs.contains(song.id) {
            let url = LibraryStore.musicURL.appendingPathComponent(song.fileName)
            do {
                guard FileManager.default.fileExists(atPath: url.path) else { failed += 1; continue }
                try FileManager.default.removeItem(at: url)
                deletedIDs.insert(song.id)
            } catch { failed += 1 }
        }
        guard !deletedIDs.isEmpty else {
            message = "Keine ausgewählte Datei konnte gelöscht werden."
            return
        }
        do {
            let playlists = try context.fetch(FetchDescriptor<Playlist>())
            for playlist in playlists { playlist.songIDs.removeAll { deletedIDs.contains($0) } }
            player.removeSongs(ids: deletedIDs)
            songs.filter { deletedIDs.contains($0.id) }.forEach(context.delete)
            try context.save()
            if failed > 0 || blockedGroups > 0 { message = "\(deletedIDs.count) Dateien gelöscht. Einige Auswahlen wurden zum Schutz der letzten Version übersprungen." }
            scan()
        } catch { message = error.localizedDescription }
    }

    private func durationText(_ duration: Double) -> String {
        let seconds = Int(duration) % 60
        return "\(Int(duration) / 60):" + String(format: "%02d", seconds)
    }
    private func fileSizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
