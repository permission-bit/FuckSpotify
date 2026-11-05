import SwiftUI
import SwiftData

struct MacJobDetailView: View {
    @StateObject private var store: MacJobDetailsStore
    @EnvironmentObject private var importer: MacImportCoordinator
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.scenePhase) private var scenePhase
    @Query private var receipts: [MacImportedFile]
    @Query private var songs: [Song]
    @State private var showingPlayer = false
    @State private var confirmingCancel = false
    init(job: MacJobInfo, credentials: MacCredentials) {
        _store = StateObject(wrappedValue: MacJobDetailsStore(job: job, credentials: credentials))
        let scope = MacFingerprint.hash(Data((credentials.fingerprint + ":" + credentials.deviceID.uuidString).utf8))
        let batchKey = MacImportLibrary.batchKey(scope: scope, jobID: job.id)
        _receipts = Query(filter: #Predicate<MacImportedFile> { $0.batchKey == batchKey })
    }
    private var playable: [UUID: Song] {
        let library = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: Song] = [:]
        for receipt in receipts where receipt.finished {
            if let id = receipt.songID, let song = library[id], FileManager.default.isReadableFile(atPath: LibraryStore.musicURL.appendingPathComponent(song.fileName).path) { result[receipt.itemID] = song }
        }
        return result
    }
    var body: some View {
        let available = playable
        List {
            Group {
            Section {
                Text("\(store.info.readyCount) von \(store.info.total_items) auf dem Mac fertig").font(.headline)
                if store.info.failedCount > 0 { Text("\(store.info.failedCount) nicht verarbeitet").foregroundStyle(AppTheme.secondaryText) }
                if importer.isBusy { ProgressView("Bibliothek wird aktualisiert …") }
                Button("Fertige Songs in die Bibliothek übernehmen", systemImage: "arrow.down.circle") { importer.refresh() }.disabled(importer.isBusy)
                if store.info.isRunning {
                    Button("Auftrag abbrechen", systemImage: "xmark.circle", role: .destructive) { confirmingCancel = true }.disabled(store.isBusy)
                }
                if !store.info.isRunning && store.info.failedCount > 0 {
                    Button("Fehlgeschlagene Titel erneut versuchen", systemImage: "arrow.clockwise") { Task { await store.retry() } }.disabled(store.isBusy)
                }
                if let message = store.message { Text(L10n.text(message)).font(.footnote).foregroundStyle(AppTheme.secondaryText) }
            }
            Section("Titel in ursprünglicher Reihenfolge") {
                ForEach(store.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(item.position)").font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                            VStack(alignment: .leading, spacing: 3) {
                                Group {
                                    if let title = item.result?.metadata["title"] ?? item.title { Text(title) }
                                    else { Text("Musikdatei") }
                                }.font(.subheadline.weight(.semibold))
                                Text(LocalizedStringKey(available[item.id] != nil ? "In deiner Bibliothek" : item.statusTitle))
                                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                        if let fraction = item.progress.fraction, fraction.isFinite, !["completed", "reused"].contains(item.status) {
                            ProgressView(value: min(1, max(0, fraction)))
                                .accessibilityLabel(Text("\(item.title ?? item.result?.metadata["title"] ?? L10n.text("Musikdatei")): Fortschritt"))
                        }
                        if let error = item.errorMessage { Text(L10n.text(error)).font(.caption).foregroundStyle(AppTheme.secondaryText) }
                        if let song = available[item.id] {
                            Button("Song öffnen", systemImage: "play.circle") { player.play(song); showingPlayer = true }
                        }
                    }.padding(.vertical, 8).onAppear { store.visible(item) }
                }
                if store.nextOffset != nil { Button("Weitere Titel anzeigen") { Task { await store.more() } }.disabled(store.isBusy) }
            }
            }.listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .musicScreen()
        .navigationTitle("Importauftrag").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showingPlayer) { NowPlayingView().musicScreen() }
        .confirmationDialog("Verarbeitung auf dem Mac abbrechen?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Auftrag abbrechen", role: .destructive) { Task { await store.cancel() } }
        } message: { Text("Bereits fertige oder importierte Songs bleiben erhalten.") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            } while !Task.isCancelled
        }
    }
}
