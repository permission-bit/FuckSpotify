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
                Group {
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
                                Image(systemName: hub.selectedIDs.contains(source.id) ? "checkmark.circle.fill" : "circle").font(.title3).accessibilityHidden(true)
                                Image(systemName: "music.note").foregroundStyle(AppTheme.secondaryText).frame(width: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title).foregroundStyle(AppTheme.text).lineLimit(2)
                                    Group {
                                        if source.importable { Text("\(source.format) · \(ByteCountFormatter.string(fromByteCount: source.size ?? 0, countStyle: .file))") }
                                        else { Text("Auf dem Mac nicht verfügbar") }
                                    }.font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44).padding(.vertical, 8).contentShape(Rectangle())
                        }.disabled(!source.importable || hub.isSubmitting)
                            .accessibilityValue(Text(LocalizedStringKey(hub.selectedIDs.contains(source.id) ? "Ausgewählt" : "Nicht ausgewählt")))
                            .accessibilityAddTraits(hub.selectedIDs.contains(source.id) ? .isSelected : [])
                    }
                    if hub.isLoading { ProgressView("Dateien laden …") }
                    if hub.moreSources { Button("Weitere Dateien laden") { Task { await hub.loadSources(reset: false) } }.disabled(hub.isLoading) }
                    if hub.sources.isEmpty && !hub.isLoading {
                        ContentUnavailableView("Noch keine freigegebenen Dateien", systemImage: "desktopcomputer",
                            description: Text("Stelle eigene oder entsprechend autorisierte Audiodateien auf dem Mac mit „add-file --device …“ für dieses iPhone bereit."))
                    }
                } header: { Text("Für dieses iPhone bereitgestellt") }
                if let message = hub.message { Section { Text(L10n.text(message)).font(.footnote).foregroundStyle(AppTheme.secondaryText) } }
                if connection.status != .connected {
                    Section { Label { Text(LocalizedStringKey(connection.status.title)) } icon: { Image(systemName: "wifi.exclamationmark") } }
                }
                }.listRowBackground(AppTheme.surface)
            }
            .listStyle(.insetGrouped)
            .musicScreen()
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
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text("Import starten"))
                    .accessibilityValue(Text(LocalizedStringKey(hub.isSubmitting ? "Import wird gestartet …" : "Bereit")))
                    .disabled(hub.selection.isEmpty || hub.isSubmitting || connection.status != .connected || scenePhase != .active)
                }
            }
            .task {
                target = importer.target
                if case .playlist(let id) = target, !playlists.contains(where: { $0.id == id }) { target = .library }
                hub.connect(connection.transferCredentials()); await hub.loadSources()
            }
        }.musicScreen()
    }
}
