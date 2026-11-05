import SwiftUI
import SwiftData

struct MacSourcesView: View {
    @ObservedObject var hub: ImportHubStore
    let onSubmitted: () -> Void
    @EnvironmentObject private var connection: MacConnectionStore
    @EnvironmentObject private var importer: MacImportCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @State private var quality = "192K"
    @State private var target: MacImportTarget = .automatic
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("MP3-Qualität", selection: $quality) {
                        ForEach(["128K", "192K", "256K", "320K"], id: \.self) { Text($0.replacingOccurrences(of: "K", with: " kbit/s")).tag($0) }
                    }
                    Picker("Importieren in", selection: $target) {
                        Text("Neue Playlist").tag(MacImportTarget.automatic)
                        Text("Nur Bibliothek").tag(MacImportTarget.library)
                        ForEach(playlists.filter { $0.artistName.isEmpty }) { Text($0.name).tag(MacImportTarget.playlist($0.id)) }
                    }
                } footer: { Text("Konvertierung auf deinem Mac. Titel, Künstler, Cover und vorhandene Metadaten werden übernommen.") }
                Section {
                    HStack {
                        Text("\(hub.selection.count) ausgewählt").font(.headline)
                        Spacer()
                        Menu("Auswahl", systemImage: "checklist") {
                            Button("Alle verfügbaren Dateien auswählen") { Task { await hub.selectAll() } }
                            Button("Auswahl aufheben") { hub.deselectAll() }
                        }.disabled(hub.isLoading || hub.isSubmitting)
                    }
                    ForEach(hub.sources) { source in
                        Button { hub.toggle(source) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: hub.selectedIDs.contains(source.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                                Image(systemName: "music.note").foregroundStyle(.secondary).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(source.importable ? "\(source.format) · \(ByteCountFormatter.string(fromByteCount: source.size ?? 0, countStyle: .file))" : "Auf dem Mac nicht verfügbar")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 4)
                        }.disabled(!source.importable || hub.isSubmitting)
                            .accessibilityValue(hub.selectedIDs.contains(source.id) ? "Ausgewählt" : "Nicht ausgewählt")
                    }
                    if hub.isLoading { ProgressView("Dateien laden …") }
                    if hub.moreSources { Button("Weitere Dateien laden") { Task { await hub.loadSources(reset: false) } }.disabled(hub.isLoading) }
                    if hub.sources.isEmpty && !hub.isLoading {
                        ContentUnavailableView("Noch keine freigegebenen Dateien", systemImage: "desktopcomputer",
                            description: Text("Stelle eigene oder entsprechend autorisierte Audiodateien auf dem Mac mit „add-file --device …“ für dieses iPhone bereit."))
                    }
                } header: { Text("Für dieses iPhone bereitgestellt") }
                if let message = hub.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                if connection.status != .connected { Section { Label(connection.status.title, systemImage: "wifi.exclamationmark") } }
            }
            .animation(.easeInOut(duration: 0.18), value: hub.selectedIDs)
            .navigationTitle("Musik importieren").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await hub.submit(quality: quality, target: target, importer: importer)
                            if hub.submittedJob != nil { onSubmitted() }
                        }
                    } label: { if hub.isSubmitting { ProgressView() } else { Text("Import starten") } }
                    .disabled(hub.selection.isEmpty || hub.isSubmitting || connection.status != .connected || scenePhase != .active)
                }
            }
            .task {
                target = importer.target
                if case .playlist(let id) = target, !playlists.contains(where: { $0.id == id }) { target = .library }
                hub.connect(connection.transferCredentials()); await hub.loadSources()
            }
        }
    }
}
