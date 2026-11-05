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
                        Button(item.rawValue) { page = item }.buttonStyle(.bordered)
                            .overlay(Capsule().stroke(.tint, lineWidth: page == item ? 1.5 : 0))
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.padding(.horizontal).padding(.vertical, 8)
            }
            List {
                if page == .search || page == .playlists || page == .link { youtubeContent }
                if page == .imports { importContent }
                if page == .connection {
                    Section {
                        Label(connection.status.title, systemImage: "desktopcomputer")
                        if let address = connection.serverAddress { Text(address).font(.footnote).foregroundStyle(.secondary) }
                        if let message = connection.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        Button(connection.isConfigured ? "Mac-Verbindung verwalten" : "Mac koppeln / QR-Code scannen") { showConnection = true }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.easeInOut(duration: 0.18), value: youtube.selectedIDs)
            .animation(.easeInOut(duration: 0.18), value: page)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("YouTube & Import").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("YouTube-Einstellungen", systemImage: "gearshape") { showKey = true } } }
        .sheet(isPresented: $showKey) { YouTubeSettingsView(store: youtube) }
        .sheet(isPresented: $showConnection) { MacConnectionView() }
        .sheet(isPresented: $showSources) {
            MacSourcesView(hub: hub, onSubmitted: { showSources = false; page = .imports })
        }
        .sheet(item: $preview) { YouTubePreview(entries: $0.entries) }
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
                TextField(page == .playlists ? "Öffentliche Playlists suchen" : "Videos auf YouTube suchen", text: $query)
                    .submitLabel(.search).onSubmit { runSearch() }
                Button("Auf YouTube suchen", systemImage: "magnifyingglass") { runSearch() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || youtube.isLoading)
            }
            if !youtube.hasKey {
                Button("Offizielle Suche einrichten", systemImage: "key") { showKey = true }
            }
        } footer: { Text("YouTube-Suche und Vorschau. Für einen Offline-Import wähle unter Importe deine freigegebenen Mac-Dateien.") }
        if let message = youtube.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
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
            } header: { Text(youtube.heading) }
            ForEach(youtube.entries) { entry in
                HStack(spacing: 12) {
                    Button { youtube.toggle(entry) } label: {
                        Image(systemName: youtube.selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).frame(width: 30, height: 44)
                    }.buttonStyle(.borderless).disabled(!entry.available)
                        .accessibilityLabel("\(entry.title) auswählen").accessibilityValue(youtube.selectedIDs.contains(entry.id) ? "Ausgewählt" : "Nicht ausgewählt")
                    AsyncImage(url: entry.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
                        .frame(width: 80, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(entry.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(entry.kind == .playlist ? "YouTube · Playlist" : entry.available ? "YouTube · \(entry.durationLabel ?? "Video")" : "Nicht verfügbar")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if entry.kind == .playlist {
                        Menu("Playlist", systemImage: "ellipsis") {
                            Button("Titel anzeigen") { youtube.openPlaylist(entry) }
                            Button("Vorschau") { preview = PreviewSelection(entries: [entry]) }
                            Link("Auf YouTube öffnen", destination: entry.publicURL)
                        }
                    } else {
                        Button("Vorschau", systemImage: "play.circle") { preview = PreviewSelection(entries: [entry]) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!entry.available)
                    }
                }.padding(.vertical, 3)
            }
            if youtube.nextToken != nil { Button("Weitere Ergebnisse laden") { youtube.loadMore() }.disabled(youtube.isLoading) }
        } else if !youtube.isLoading, youtube.message == nil {
            ContentUnavailableView(youtube.hasSearched ? "Keine Ergebnisse" : "Musik entdecken", systemImage: "play.rectangle",
                description: Text(youtube.hasSearched ? "Versuche einen anderen Suchbegriff oder einen öffentlichen YouTube-Link." : "Suche nach Videos oder öffentlichen Playlists oder füge einen YouTube-Link ein."))
        }
    }
    @ViewBuilder private var importContent: some View {
        Section {
            Label(connection.status.title, systemImage: "desktopcomputer")
            if connection.status == .connected {
                Button("Freigegebene Mac-Dateien auswählen", systemImage: "music.note.list") { showSources = true }
            } else { Button("Mac verbinden") { showConnection = true } }
            if let message = hub.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        if let credentials = connection.transferCredentials(), connection.status == .connected {
            Section("Aufträge auf deinem Mac") {
                ForEach(hub.jobs, id: \.id) { job in
                    NavigationLink { MacJobDetailView(job: job, credentials: credentials) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title ?? "Musikimport").font(.headline).lineLimit(2)
                            Text("\(job.total_items) Titel").font(.caption).foregroundStyle(.secondary)
                            Text("\(job.readyCount) fertig · \(job.failedCount) nicht verarbeitet\(job.isRunning ? " · läuft" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if hub.jobs.isEmpty { Text("Hier erscheinen deine Konvertierungsaufträge.").foregroundStyle(.secondary) }
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
                Section {
                    Text(store.hasKey ? "Ein API-Schlüssel ist im Schlüsselbund gespeichert." : "Für die offizielle Suche brauchst du einen Schlüssel für die YouTube Data API v3.")
                    SecureField("YouTube-API-Schlüssel", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Sicher speichern") { save(key) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if store.hasKey { Button("Schlüssel entfernen", role: .destructive) { save("") } }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                } footer: { Text("Aktiviere YouTube Data API v3 für dein Google-Cloud-Projekt und beschränke den Schlüssel auf diese API. Er wird auf diesem Gerät gespeichert und nicht an deinen Mac gesendet.") }
                Section {
                    Link("API einrichten", destination: URL(string: "https://developers.google.com/youtube/v3/getting-started")!)
                    Link("YouTube-Nutzungsbedingungen", destination: URL(string: "https://www.youtube.com/t/terms")!)
                    Link("Google-Datenschutz", destination: URL(string: "https://policies.google.com/privacy")!)
                }
            }
            .navigationTitle("YouTube-Einstellungen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onDisappear { key = "" }
        }
    }
    private func save(_ value: String) {
        do { try store.configureKey(value); key = ""; dismiss() } catch { self.error = error.localizedDescription }
    }
}
