import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
enum SongGenreStore {
    static func loadOriginal(_ song: Song, context: ModelContext) async throws {
        guard !song.genreMetadataLoaded else { return }
        let url = LibraryStore.musicURL.appendingPathComponent(song.fileName)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return }
        let genreName = try await AudioMetadata.genre(at: url)
        song.importedGenre = genreName
        song.genreMetadataLoaded = true
        song.originalGenreIDs = []
        if song.genreOverrideID == nil { song.genreIDs = song.inferredGenreIDs }
        if !genreName.isEmpty {
            let genres = try context.fetch(FetchDescriptor<MusicGenre>())
            let genre = genres.first { MusicCatalog.normalized($0.name) == MusicCatalog.normalized(genreName) } ?? MusicGenre(name: genreName)
            if !genres.contains(where: { $0.id == genre.id }) { context.insert(genre) }
            song.originalGenreIDs = [genre.id]
            if song.genreOverrideID == nil { song.genreIDs = [genre.id] }
        }
        try context.save()
    }

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

    static func restore(_ song: Song, context: ModelContext) throws {
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
    @State private var loadingOriginal = true

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
                            do { try SongGenreStore.restore(song, context: context); dismiss() }
                            catch { errorMessage = error.localizedDescription }
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
                        .disabled(loadingOriginal || (selectedGenreID == nil && customGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .alert("Genre konnte nicht gespeichert werden", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task {
                do {
                    try await SongGenreStore.loadOriginal(song, context: context)
                    selectedGenreID = song.genreOverrideID ?? song.genreIDs.first
                } catch { errorMessage = error.localizedDescription }
                loadingOriginal = false
            }
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
    var detail: String { self == .exact ? "Diese Dateien haben identischen Inhalt." : "Ähnliche Angaben und Dauer. Bitte Versionen vergleichen." }
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
    var modifiedAt: Date? = nil

    var canonicalPath: String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    var isAvailable: Bool {
        guard FileManager.default.isReadableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return false }
        return true
    }

    var isUnchanged: Bool {
        guard isAvailable, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? NSNumber)?.int64Value == fileSize else { return false }
        return modifiedAt == nil || attributes[.modificationDate] as? Date == modifiedAt
    }
}

struct DuplicateGroup: Identifiable, Sendable {
    let kind: DuplicateKind
    let records: [DuplicateSongRecord]
    var id: String { "\(kind.rawValue)-" + records.map { $0.id.uuidString }.sorted().joined(separator: "-") }
}

enum DuplicateScanner {
    static func scan(_ inputs: [DuplicateSongInput]) async -> [DuplicateGroup] {
        let task = Task.detached(priority: .utility) { scanSynchronously(inputs) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func scanSynchronously(_ inputs: [DuplicateSongInput]) -> [DuplicateGroup] {
        let records = inputs.compactMap { input -> DuplicateSongRecord? in
            guard !Task.isCancelled, let size = fileSize(at: input.path) else { return nil }
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.modificationDate] as? Date
            return DuplicateSongRecord(id: input.id, title: input.title, artist: input.artist, album: input.album, duration: input.duration, fileName: input.fileName, path: input.path, fileSize: size, fileFormat: URL(fileURLWithPath: input.fileName).pathExtension.uppercased(), modifiedAt: modifiedAt)
        }

        let sameSizeCandidates = Dictionary(grouping: records, by: \.fileSize).values.filter { $0.count > 1 }
        var exactGroups: [DuplicateGroup] = []
        var redundantExactIDs = Set<UUID>()
        for candidates in sameSizeCandidates {
            guard !Task.isCancelled else { return [] }
            let byHash = Dictionary(grouping: candidates.compactMap { record -> (String, DuplicateSongRecord)? in
                guard record.isUnchanged, let hash = streamingHash(at: record.path), record.isUnchanged else { return nil }
                return (hash, record)
            }, by: { $0.0 })
            for matches in byHash.values where matches.count > 1 {
                let groupRecords = matches.map(\.1).sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                exactGroups.append(DuplicateGroup(kind: .exact, records: groupRecords))
                redundantExactIDs.formUnion(groupRecords.dropFirst().map(\.id))
            }
        }

        let possibleCandidates = records.filter { !redundantExactIDs.contains($0.id) && metadataKey(for: $0) != nil }
        var possibleGroups: [DuplicateGroup] = []
        for candidates in Dictionary(grouping: possibleCandidates, by: { metadataKey(for: $0)! }).values {
            let ordered = candidates.sorted { $0.duration < $1.duration }
            var current: [DuplicateSongRecord] = []
            for record in ordered {
                if let first = current.first, abs(record.duration - first.duration) > 2 {
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
        let artist = knownValue(record.artist)
        let album = knownValue(record.album)
        guard !title.isEmpty, !artist.isEmpty || !album.isEmpty, record.duration.isFinite, record.duration > 0 else { return nil }
        return "\(title)|\(artist)|\(album)"
    }

    static func normalized(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func knownValue(_ value: String) -> String {
        let key = normalized(value)
        return ["unknown", "unknown artist", "unknown album", "unbekannt", "unbekannter kunstler", "unbekanntes album"].contains(key) ? "" : key
    }

    private static func fileSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: path),
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return nil }
        return size.int64Value
    }

    private static func streamingHash(at path: String) -> String? {
        guard let before = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard !Task.isCancelled else { return nil }
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1_048_576), !read.isEmpty else { break }
                chunk = read
            } catch { return nil }
            hasher.update(data: chunk)
        }
        guard let after = try? FileManager.default.attributesOfItem(atPath: path),
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeDeletionIDs(groups: [DuplicateGroup], removalIDs: Set<UUID>) -> (ids: Set<UUID>, blockedGroupCount: Int) {
        var safeIDs = Set<UUID>()
        var blockedIDs = Set<UUID>()
        var blockedGroupCount = 0
        let selectedPaths = Set(groups.flatMap(\.records).filter { removalIDs.contains($0.id) }.map(\.canonicalPath))
        let retainedPaths = Set(groups.flatMap(\.records).filter { !removalIDs.contains($0.id) }.map(\.canonicalPath))
        for group in groups {
            let selected = group.records.filter { removalIDs.contains($0.id) }
            guard !selected.isEmpty else { continue }
            if selected.allSatisfy({ $0.isUnchanged && !retainedPaths.contains($0.canonicalPath) }), group.records.contains(where: { !removalIDs.contains($0.id) && !selectedPaths.contains($0.canonicalPath) && $0.isUnchanged }) {
                safeIDs.formUnion(selected.map(\.id))
            } else {
                blockedGroupCount += 1
                blockedIDs.formUnion(selected.map(\.id))
            }
        }
        return (safeIDs.subtracting(blockedIDs), blockedGroupCount)
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
    @State private var scanTask: Task<Void, Never>?

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
                                    .listRowBackground(player.current?.id == record.id ? Color.green.opacity(0.1) : Color(.secondarySystemGroupedBackground))
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
            .onDisappear { scanTask?.cancel() }
            .onChange(of: songs.count) { _, _ in scan() }
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
                    Text(record.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Text("\(durationText(record.duration)) · \(fileSizeText(record.fileSize)) · \(record.fileFormat.isEmpty ? "Audio" : record.fileFormat)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(player.current?.id == record.id && player.isPlaying ? "Pause" : "Vorschau", systemImage: player.current?.id == record.id && player.isPlaying ? "pause.fill" : "play.fill") { preview(record) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!record.isAvailable)
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
                        if marked, !keepIDs.values.contains(record.id) { removalIDs.insert(record.id) }
                        else { removalIDs.remove(record.id) }
                    }
                ))
                .disabled(keepIDs.values.contains(record.id))
            }
        }
        .opacity(record.isAvailable ? 1 : 0.5)
    }

    private func scan() {
        scanTask?.cancel()
        isScanning = true
        let inputs = songs.map { song in
            DuplicateSongInput(id: song.id, title: song.title, artist: song.artist, album: song.album, duration: song.duration, fileName: song.fileName, path: LibraryStore.musicURL.appendingPathComponent(song.fileName).path)
        }
        scanTask = Task {
            let results = await DuplicateScanner.scan(inputs)
            guard !Task.isCancelled else { return }
            groups = results
            keepIDs = Dictionary(uniqueKeysWithValues: results.compactMap { group in group.records.first.map { (group.id, $0.id) } })
            removalIDs.removeAll()
            isScanning = false
        }
    }

    private func preview(_ record: DuplicateSongRecord) {
        guard let song = songs.first(where: { $0.id == record.id }) else { return }
        if player.current?.id == record.id { player.toggle() }
        else { player.play(song) }
    }

    private func deleteMarked() {
        let deletion = DuplicateScanner.safeDeletionIDs(groups: groups, removalIDs: removalIDs)
        let safeIDs = deletion.ids
        let blockedGroups = deletion.blockedGroupCount
        guard !safeIDs.isEmpty else {
            message = "Für jede Gruppe muss mindestens eine zugängliche Version behalten werden."
            return
        }
        do {
            let count = try DuplicateLibraryStore.delete(groups: groups, removalIDs: safeIDs, keepIDs: keepIDs, context: context, player: player)
            if blockedGroups > 0 { message = "\(count) Dateien gelöscht. Einige Auswahlen wurden zum Schutz der letzten Version übersprungen." }
            scan()
        } catch { message = error.localizedDescription }
    }

    private func durationText(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "–" }
        let seconds = Int(duration) % 60
        return "\(Int(duration) / 60):" + String(format: "%02d", seconds)
    }
    private func fileSizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor
enum DuplicateLibraryStore {
    private struct Receipt: Codable { let fileNames: [String] }
    private static var trashURL: URL { LibraryStore.musicURL.appendingPathComponent(".duplicate-removals", isDirectory: true) }

    static func recover(in context: ModelContext) throws {
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return }
        let referenced = Set(try context.fetch(FetchDescriptor<Song>()).map(\.fileName))
        for directory in try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            let receiptURL = directory.appendingPathComponent("receipt.json")
            guard let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { continue }
            for name in receipt.fileNames where URL(fileURLWithPath: name).lastPathComponent == name {
                let staged = directory.appendingPathComponent(name)
                let original = LibraryStore.musicURL.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                if referenced.contains(name) {
                    if !FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: staged, to: original) }
                } else { try FileManager.default.removeItem(at: staged) }
            }
            let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if leftovers == [receiptURL] {
                try FileManager.default.removeItem(at: receiptURL)
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    static func delete(groups: [DuplicateGroup], removalIDs: Set<UUID>, keepIDs: [String: UUID], context: ModelContext, player: AudioPlayer) throws -> Int {
        let safeIDs = DuplicateScanner.safeDeletionIDs(groups: groups, removalIDs: removalIDs).ids
        guard !safeIDs.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
        player.prepareForLibraryMutation()
        defer { player.finishLibraryMutation() }
        let songs = try context.fetch(FetchDescriptor<Song>())
        let lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let selected = songs.filter { safeIDs.contains($0.id) }
        let survivors = songs.filter { !safeIDs.contains($0.id) }
        var replacements: [UUID: UUID] = [:]
        for group in groups {
            let candidates = group.records.filter { !safeIDs.contains($0.id) && $0.isUnchanged && lookup[$0.id] != nil }
            guard let kept = candidates.first(where: { $0.id == keepIDs[group.id] }) ?? candidates.first else { continue }
            for record in group.records where safeIDs.contains(record.id) && replacements[record.id] == nil { replacements[record.id] = kept.id }
        }
        guard selected.count == safeIDs.count, replacements.count == safeIDs.count else { throw CocoaError(.fileReadUnknown) }
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        // Flush unrelated pending edits before this transaction so rollback is scoped.
        try context.save()
        let currentID = player.current?.id
        let queueIDs = player.queue.map(\.id)
        let directory = trashURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipt = Receipt(fileNames: Array(Set(selected.map(\.fileName))))
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        do {
            for name in receipt.fileNames {
                try FileManager.default.moveItem(at: LibraryStore.musicURL.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            }
            for playlist in playlists {
                var seen = Set<UUID>()
                playlist.songIDs = playlist.songIDs.map { replacements[$0] ?? $0 }.filter { seen.insert($0).inserted }
            }
            for song in selected {
                if let id = replacements[song.id], let kept = lookup[id] {
                    if song.isFavorite { kept.isFavorite = true }
                    kept.mergeHistory(from: song)
                }
                context.delete(song)
            }
            try context.save()
        } catch {
            context.rollback()
            try? recover(in: context)
            throw error
        }
        player.reconcileDuplicates(songs: survivors, replacements: replacements, previousCurrentID: currentID, previousQueueIDs: queueIDs)
        // A leftover receipt is safe to complete on the next launch if cleanup fails.
        try? recover(in: context)
        return safeIDs.count
    }
}
