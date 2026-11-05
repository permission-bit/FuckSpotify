import SwiftUI
import SwiftData

struct ImportHubView: View {
    private enum Page: String, CaseIterable { case search = "Suche", link = "Link einfügen", playlists = "Playlists", imports = "Importe", connection = "Verbindung" }
    @EnvironmentObject private var connection: MacConnectionStore
    @EnvironmentObject private var imports: MacImportCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var youtube = YouTubeSearchStore()
    @StateObject private var hub = ImportHubStore()
    @State private var page: Page = .search
    @State private var query = ""
    @State private var link = ""
    @State private var showConnection = false
    @State private var showKey = false
    @State private var showSources = false
    @State private var preview: PreviewSelection?
    private struct PreviewSelection: Identifiable { let id = UUID(); let entries: [YouTubeEntry] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Button { page = item } label: {
                            Text(LocalizedStringKey(item.rawValue))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(page == item ? AppTheme.onAccent : AppTheme.text)
                                .background(page == item ? AppTheme.accent : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                            .musicGlass(cornerRadius: 24)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.padding(.horizontal).padding(.vertical, 8)
            }
            List {
                Group {
                    if page == .search || page == .playlists || page == .link { youtubeContent }
                    if page == .imports { importContent }
                    if page == .connection {
                        Section {
                            Label { Text(LocalizedStringKey(connection.status.title)) } icon: { Image(systemName: "desktopcomputer") }
                            if let address = connection.serverAddress { Text(address).font(.footnote).foregroundStyle(AppTheme.secondaryText) }
                            if let message = connection.message { Text(L10n.text(message)).font(.footnote).foregroundStyle(AppTheme.secondaryText) }
                            Button { showConnection = true } label: {
                                Text(LocalizedStringKey(connection.isConfigured ? "Mac-Verbindung verwalten" : "Mac koppeln / QR-Code scannen"))
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                }.listRowBackground(AppTheme.surface)
            }
            .listStyle(.insetGrouped)
            .musicScreen()
            .animation(.easeInOut(duration: 0.18), value: youtube.selectedIDs)
            .animation(.easeInOut(duration: 0.18), value: page)
        }
        .musicScreen()
        .navigationTitle("YouTube & Import").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("YouTube-Einstellungen", systemImage: "gearshape") { showKey = true } } }
        .sheet(isPresented: $showKey) { YouTubeSettingsView(store: youtube).musicScreen() }
        .sheet(isPresented: $showConnection) { MacConnectionView().musicScreen() }
        .sheet(isPresented: $showSources) {
            MacSourcesView(hub: hub, onSubmitted: { showSources = false; page = .imports }).musicScreen()
        }
        .sheet(item: $preview) { YouTubePreview(entries: $0.entries).musicScreen() }
        .onChange(of: page) { old, new in
            if old != new { youtube.reset() }
        }
        .task(id: "\(page.rawValue)-\(connection.status.title)-\(scenePhase)") {
            guard scenePhase == .active else { youtube.cancel(); return }
            if connection.status == .connected { hub.connect(connection.transferCredentials()) }
            else if !connection.isConfigured { hub.connect(nil) }
            guard page == .imports, connection.status == .connected else { return }
            repeat {
                await hub.loadJobs()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { youtube.cancel() }
    }

    @ViewBuilder private var youtubeContent: some View {
        Section {
            if page == .link {
                TextField("YouTube-Link einfügen", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit { youtube.openLink(link) }
                Button("Link öffnen", systemImage: "link") { youtube.openLink(link) }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || youtube.isLoading)
            } else {
                TextField(text: $query) {
                    Text(LocalizedStringKey(page == .playlists ? "Öffentliche Playlists suchen" : "Videos auf YouTube suchen"))
                }
                    .submitLabel(.search).onSubmit { runSearch() }
                Button("Auf YouTube suchen", systemImage: "magnifyingglass") { runSearch() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || youtube.isLoading)
            }
            if !youtube.hasKey {
                Button("Offizielle Suche einrichten", systemImage: "key") { showKey = true }
            }
        } footer: { Text("YouTube-Suche und Vorschau. Für einen Offline-Import wähle unter Importe deine freigegebenen Mac-Dateien.") }
        if let message = youtube.message { Section { Text(L10n.text(message)).font(.footnote).foregroundStyle(AppTheme.secondaryText) } }
        if youtube.isLoading { Section { ProgressView("YouTube laden …"); Button("Laden abbrechen") { youtube.cancel() } } }
        if youtube.isBrowsingPlaylist {
            Button("Zurück zu den Ergebnissen", systemImage: "chevron.left") { youtube.backToResults() }
        }
        if !youtube.entries.isEmpty {
            Section {
                HStack {
                    Text("\(youtube.selectedIDs.count) ausgewählt").font(.subheadline)
                    Spacer()
                    Menu("Auswahl", systemImage: "checklist") {
                        Button("Alle auswählen (weitere Seiten laden)") { youtube.selectAll() }
                        Button("Auswahl aufheben") { youtube.deselectAll() }
                    }.disabled(youtube.isLoading)
                }
                if !youtube.selection.isEmpty {
                    Button("Auswahl als Vorschau öffnen", systemImage: "play.rectangle") { preview = PreviewSelection(entries: youtube.selection) }
                }
            } header: {
                if youtube.isBrowsingPlaylist { Text(youtube.heading) }
                else { Text(LocalizedStringKey(youtube.heading)) }
            }
            ForEach(youtube.entries) { entry in
                HStack(spacing: 12) {
                    Button { youtube.toggle(entry) } label: {
                        Image(systemName: youtube.selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.borderless).disabled(!entry.available)
                        .accessibilityLabel(Text("\(entry.title) auswählen"))
                        .accessibilityValue(Text(LocalizedStringKey(youtube.selectedIDs.contains(entry.id) ? "Ausgewählt" : "Nicht ausgewählt")))
                        .accessibilityAddTraits(youtube.selectedIDs.contains(entry.id) ? .isSelected : [])
                    AsyncImage(url: entry.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "play.rectangle").foregroundStyle(AppTheme.secondaryText) }
                        .frame(width: 80, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(entry.channel).font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
                        Group {
                            if entry.kind == .playlist { Text("YouTube · Playlist") }
                            else if !entry.available { Text("Nicht verfügbar") }
                            else if let duration = entry.durationLabel { Text("YouTube · \(duration)") }
                            else { Text("YouTube · Video") }
                        }.font(.caption2).foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if entry.kind == .playlist {
                        Menu("Playlist", systemImage: "ellipsis") {
                            Button("Titel anzeigen") { youtube.openPlaylist(entry) }
                            Button("Vorschau") { preview = PreviewSelection(entries: [entry]) }
                            Link("Auf YouTube öffnen", destination: entry.publicURL)
                        }.frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(Text("Playlist: \(entry.title)"))
                    } else {
                        Button { preview = PreviewSelection(entries: [entry]) } label: {
                            Label("Vorschau", systemImage: "play.circle").frame(minWidth: 44, minHeight: 44)
                        }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!entry.available)
                            .accessibilityLabel(Text("Vorschau: \(entry.title)"))
                    }
                }.padding(.vertical, 8)
            }
            if youtube.nextToken != nil { Button("Weitere Ergebnisse laden") { youtube.loadMore() }.disabled(youtube.isLoading) }
        } else if !youtube.isLoading, youtube.message == nil {
            ContentUnavailableView {
                Label { Text(LocalizedStringKey(youtube.hasSearched ? "Keine Ergebnisse" : "Musik entdecken")) } icon: { Image(systemName: "play.rectangle") }
            } description: {
                Text(LocalizedStringKey(youtube.hasSearched ? "Versuche einen anderen Suchbegriff oder einen öffentlichen YouTube-Link." : "Suche nach Videos oder öffentlichen Playlists oder füge einen YouTube-Link ein."))
            }
        }
    }
    @ViewBuilder private var importContent: some View {
        Section {
            Label { Text(LocalizedStringKey(connection.status.title)) } icon: { Image(systemName: "desktopcomputer") }
            if connection.status == .connected {
                Button("Freigegebene Mac-Dateien auswählen", systemImage: "music.note.list") { showSources = true }
            } else { Button("Mac verbinden") { showConnection = true } }
            if let message = hub.message { Text(L10n.text(message)).font(.footnote).foregroundStyle(AppTheme.secondaryText) }
        }
        if let credentials = connection.transferCredentials(), connection.status == .connected {
            Section("Aufträge auf deinem Mac") {
                ForEach(hub.jobs, id: \.id) { job in
                    NavigationLink { MacJobDetailView(job: job, credentials: credentials).musicScreen() } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                if let title = job.title { Text(title) } else { Text("Musikimport") }
                            }.font(.headline).lineLimit(2)
                            Text("\(job.total_items) Titel").font(.caption).foregroundStyle(AppTheme.secondaryText)
                            Group {
                                if job.isRunning { Text("\(job.readyCount) fertig · \(job.failedCount) nicht verarbeitet · läuft") }
                                else { Text("\(job.readyCount) fertig · \(job.failedCount) nicht verarbeitet") }
                            }.font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }.padding(.vertical, 8)
                    }
                }
                if hub.jobs.isEmpty { Text("Hier erscheinen deine Konvertierungsaufträge.").foregroundStyle(AppTheme.secondaryText) }
                if hub.moreJobs { Button("Weitere Aufträge") { Task { await hub.loadJobs(more: true) } } }
            }
        }
        MacImportView()
    }
    private func runSearch() { youtube.search(query, kind: page == .playlists ? .playlist : .video) }
}

private struct YouTubeSettingsView: View {
    @ObservedObject var store: YouTubeSearchStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Text(LocalizedStringKey(store.hasKey ? "Ein API-Schlüssel ist im Schlüsselbund gespeichert." : "Für die offizielle Suche brauchst du einen Schlüssel für die YouTube Data API v3."))
                    SecureField("YouTube-API-Schlüssel", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Sicher speichern") { save(key) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if store.hasKey { Button("Schlüssel entfernen", role: .destructive) { save("") } }
                    if let error { Text(L10n.text(error)).foregroundStyle(.red).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                } footer: { Text("Aktiviere YouTube Data API v3 für dein Google-Cloud-Projekt und beschränke den Schlüssel auf diese API. Er wird auf diesem Gerät gespeichert und nicht an deinen Mac gesendet.") }
                Section {
                    Link("API einrichten", destination: URL(string: "https://developers.google.com/youtube/v3/getting-started")!)
                    Link("YouTube-Nutzungsbedingungen", destination: URL(string: "https://www.youtube.com/t/terms")!)
                    Link("Google-Datenschutz", destination: URL(string: "https://policies.google.com/privacy")!)
                }
                }.listRowBackground(AppTheme.surface)
            }
            .musicScreen()
            .navigationTitle("YouTube-Einstellungen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onDisappear { key = "" }
        }.musicScreen()
    }
    private func save(_ value: String) {
        do { try store.configureKey(value); key = ""; dismiss() } catch { self.error = L10n.error(error) }
    }
}
