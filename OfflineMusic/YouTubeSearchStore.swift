import Foundation
import Combine

@MainActor final class YouTubeSearchStore: ObservableObject {
    @Published private(set) var entries: [YouTubeEntry] = []
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var isLoading = false
    @Published private(set) var nextToken: String?
    @Published private(set) var message: String?
    @Published private(set) var heading = "YouTube entdecken"
    @Published private(set) var hasKey = false
    @Published private(set) var isBrowsingPlaylist = false
    @Published private(set) var hasSearched = false
    private var parent: (entries: [YouTubeEntry], selection: Set<String>, next: String?, heading: String)?
    private var key = ""
    private var query = ""
    private var kind: YouTubeKind = .video
    private var playlistID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let api: any YouTubeNetworking

    init(api: any YouTubeNetworking = YouTubeAPI(), key: String? = nil) {
        self.api = api
        if let key { self.key = key; hasKey = !key.isEmpty; return }
        do { self.key = try YouTubeKeyStore().load(); hasKey = !self.key.isEmpty }
        catch { message = error.localizedDescription }
    }
    var selection: [YouTubeEntry] { entries.filter { selectedIDs.contains($0.id) && $0.available } }
    func configureKey(_ value: String) throws {
        try YouTubeKeyStore().save(value)
        key = try YouTubeKeyStore().load(); hasKey = !key.isEmpty
        reset()
    }
    func toggle(_ entry: YouTubeEntry) {
        guard entry.available else { return }
        if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
    }
    func deselectAll() { selectedIDs = [] }
    func selectAll() {
        selectedIDs = Set(entries.filter(\.available).map(\.id))
        if nextToken != nil, !isLoading { loadMore(selectFollowing: true) }
    }
    func search(_ text: String, kind: YouTubeKind) {
        cancel(); entries = []; selectedIDs = []; nextToken = nil; playlistID = nil
        parent = nil; isBrowsingPlaylist = false
        hasSearched = true
        query = text.trimmingCharacters(in: .whitespacesAndNewlines); self.kind = kind
        heading = kind == .video ? "YouTube-Videos" : "Öffentliche Playlists"
        guard !query.isEmpty, query.count <= 200 else { message = "Gib einen Suchbegriff mit höchstens 200 Zeichen ein."; return }
        loadMore()
    }
    func openPlaylist(_ entry: YouTubeEntry) {
        parent = (entries, selectedIDs, nextToken, heading)
        cancel(); entries = []; selectedIDs = []; nextToken = nil; playlistID = entry.resourceID
        isBrowsingPlaylist = true
        heading = entry.title; loadMore()
    }
    func backToResults() {
        guard let parent else { return }
        cancel(); entries = parent.entries; selectedIDs = parent.selection; nextToken = parent.next; heading = parent.heading
        playlistID = nil; self.parent = nil; isBrowsingPlaylist = false; message = nil
    }
    func openLink(_ text: String) {
        cancel(); entries = []; selectedIDs = []; nextToken = nil; playlistID = nil
        parent = nil; isBrowsingPlaylist = false
        heading = "YouTube-Link"
        hasSearched = true
        let generation = generation
        isLoading = true; message = nil
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            do {
                let link = try YouTubeLink(text)
                let results = try await self.api.resolve(link, key: self.key)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.entries = results; self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.message = error.localizedDescription; self.isLoading = false
            }
        }
    }
    func loadMore(selectFollowing: Bool = false) {
        guard !isLoading else { return }
        let generation = generation
        isLoading = true; message = nil
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            do {
                repeat {
                    let page: YouTubePage
                    if let id = self.playlistID { page = try await self.api.playlist(id, token: self.nextToken, key: self.key) }
                    else { page = try await self.api.search(self.query, kind: self.kind, token: self.nextToken, key: self.key) }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    var seen = Set(self.entries.map(\.id))
                    let new = page.entries.filter { seen.insert($0.id).inserted }
                    self.entries += new
                    if selectFollowing { self.selectedIDs.formUnion(new.filter(\.available).map(\.id)) }
                    let previous = self.nextToken
                    self.nextToken = page.nextToken == previous ? nil : page.nextToken
                    if self.entries.count >= 1000 {
                        self.nextToken = nil; self.message = "Die ersten 1.000 Listeneinträge sind geladen. Öffne längere Playlists direkt auf YouTube."; break
                    }
                    if !selectFollowing || self.nextToken == nil { break }
                } while !Task.isCancelled
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.isLoading = false; self.message = error.localizedDescription
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; isLoading = false }
    func reset() { cancel(); entries = []; selectedIDs = []; nextToken = nil; playlistID = nil; parent = nil; isBrowsingPlaylist = false; hasSearched = false; message = nil; heading = "YouTube entdecken" }
}
