import SwiftUI
import SwiftData

struct MacImportView: View {
    @EnvironmentObject private var imports: MacImportCoordinator
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    var body: some View {
        Section {
            Toggle("Fertige Songs automatisch importieren", isOn: Binding(get: { imports.automatic }, set: imports.setAutomatic))
            Picker("Ziel für neue Aufträge", selection: Binding(get: { imports.target }, set: imports.setTarget)) {
                Text("Playlist pro Songgruppe").tag(MacImportTarget.automatic)
                Text("Nur Bibliothek").tag(MacImportTarget.library)
                ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in
                    Text(playlist.name).tag(MacImportTarget.playlist(playlist.id))
                }
            }
            .disabled(imports.isBusy)
            Button("Fertige Aufträge jetzt abrufen", systemImage: "arrow.down.circle") { imports.refresh() }.disabled(imports.isBusy)
            if let title = imports.currentTitle {
                Text(title).font(.subheadline).lineLimit(2)
                ProgressView(value: imports.progress)
            } else if imports.isBusy { ProgressView("Aufträge prüfen …") }
            if let message = imports.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Musik vom Mac") } footer: {
            Text("Die App übernimmt fertige MP3-Dateien im Vordergrund. Bei Unterbrechungen setzt sie den Import beim nächsten Öffnen fort. Geprüfte Downloads und Importzuordnungen bleiben erhalten.")
        }
        ForEach(imports.summaries) { summary in
            Section(summary.title) {
                Text("\(summary.imported) importiert · \(summary.reused) bereits vorhanden").font(.subheadline)
                if summary.pending > 0 { Text("\(summary.pending) ausstehend").foregroundStyle(.secondary) }
                if summary.running { Text("Der Mac verarbeitet den Auftrag noch.").font(.footnote).foregroundStyle(.secondary) }
                if summary.remoteFailed > 0 { Text("\(summary.remoteFailed) Titel auf dem Mac fehlgeschlagen oder nicht verfügbar. Fertige Titel bleiben erhalten.").font(.footnote).foregroundStyle(.secondary) }
                if let message = summary.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if summary.failed > 0 {
                    Button("\(summary.failed) fehlgeschlagene Imports erneut versuchen") { imports.retry(batchKey: summary.id) }.disabled(imports.isBusy)
                }
                Menu("Importziel / Playlist", systemImage: "text.badge.plus") {
                    Button("Playlist für diese Songgruppe") { imports.assign(batchKey: summary.id, target: .automatic) }
                    Button("Nur Bibliothek") { imports.assign(batchKey: summary.id, target: .library) }
                    ForEach(playlists.filter { $0.artistName.isEmpty }) { playlist in
                        Button(playlist.name) { imports.assign(batchKey: summary.id, target: .playlist(playlist.id)) }
                    }
                }.disabled(imports.isBusy)
            }
        }
    }
}
