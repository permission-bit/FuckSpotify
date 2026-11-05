import Foundation

final class YouTubeMock: @unchecked Sendable {
    static let shared = YouTubeMock()
    private let lock = NSLock()
    private var mode = "ok"
    private var calls = 0
    let a = "aaaaaaaaaaa", b = "bbbbbbbbbbb", c = "ccccccccccc", playlist = "PL1234567890"
    func configure(_ value: String) { lock.lock(); mode = value; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let url = request.url!
        precondition(url.scheme == "https" && url.host == "www.googleapis.com")
        precondition(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        precondition(!url.absoluteString.contains("test-key"), "API key must not be placed in URLs")
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if mode == "quota" { return (403, try JSONSerialization.data(withJSONObject: ["error": ["errors": [["reason": "quotaExceeded"]]]])) }
        if mode == "key" { return (403, Data("{}".utf8)) }
        if mode == "invalid" { return (200, Data("not json".utf8)) }
        if mode == "network" { throw URLError(.notConnectedToInternet) }
        func snippet(_ title: String) -> [String: Any] {
            ["title": title, "channelTitle": "Fixture Channel", "thumbnails": ["medium": ["url": "https://i.ytimg.com/vi/\(a)/mqdefault.jpg"]]]
        }
        var result: [String: Any] = [:]
        switch url.lastPathComponent {
        case "search":
            precondition(query["part"] == "snippet")
            if query["type"] == "playlist" { result = ["items": [["id": ["playlistId": playlist], "snippet": snippet("Public playlist")]]] }
            else {
                precondition(query["videoEmbeddable"] == "true")
                let ids = query["pageToken"] == nil ? [a, b] : [c]
                result = ["items": ids.map { ["id": ["videoId": $0], "snippet": snippet("Title &amp; \($0)")] }]
                if query["pageToken"] == nil { result["nextPageToken"] = "TWO" }
            }
        case "videos":
            let ids = (query["id"] ?? "").split(separator: ",").map(String.init)
            result = ["items": ids.reversed().filter { $0 != c }.map { ["id": $0, "snippet": snippet("Video \($0)"), "contentDetails": ["duration": "PT1M30S"], "status": ["privacyStatus": "public", "embeddable": $0 != b]] }]
        case "playlists": result = ["items": [["id": playlist, "snippet": snippet("Public playlist")]]]
        case "playlistItems":
            let ids = query["pageToken"] == nil ? [(a, 0), (c, 1)] : [(b, 2), (a, 3)]
            result = ["items": ids.map { id, position -> [String: Any] in
                var info = snippet("Playlist entry \(position)")
                info["resourceId"] = ["videoId": id]; info["position"] = position
                return ["id": "entry-\(position)", "snippet": info]
            }]
            if query["pageToken"] == nil { result["nextPageToken"] = "NEXT" }
        default: preconditionFailure("Unexpected endpoint")
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}

final class YouTubeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try YouTubeMock.shared.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

struct DelayedYouTube: YouTubeNetworking {
    func search(_ query: String, kind: YouTubeKind, token: String?, key: String) async throws -> YouTubePage {
        if query == "old" { try? await Task.sleep(nanoseconds: 200_000_000) }
        return YouTubePage(entries: [YouTubeEntry(id: query, resourceID: "aaaaaaaaaaa", kind: .video, title: query, channel: "Fixture", thumbnail: nil)], nextToken: nil)
    }
    func playlist(_ id: String, token: String?, key: String) async throws -> YouTubePage { YouTubePage(entries: [], nextToken: nil) }
    func resolve(_ link: YouTubeLink, key: String) async throws -> [YouTubeEntry] { [] }
}

@main struct YouTubeChecks {
    static func expect(_ expected: YouTubeError, operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected error") }
        catch { precondition(error as? YouTubeError == expected, "Unexpected error: \(error)") }
    }
    @MainActor static func wait(_ store: YouTubeSearchStore) async {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!store.isLoading)
    }
    @MainActor static func main() async throws {
        let mock = YouTubeMock.shared
        for text in ["https://youtu.be/aaaaaaaaaaa", "https://www.youtube.com/watch?v=aaaaaaaaaaa", "https://youtube.com/shorts/aaaaaaaaaaa", "https://youtube.com/live/aaaaaaaaaaa", "https://youtube-nocookie.com/embed/aaaaaaaaaaa"] {
            precondition(try! YouTubeLink(text).videoID == mock.a)
        }
        let mixed = try YouTubeLink("https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PL1234567890")
        precondition(mixed.videoID == mock.a && mixed.playlistID == mock.playlist)
        for text in ["file:///etc/passwd", "https://youtube.com.evil.example/watch?v=aaaaaaaaaaa", "https://user:pass@youtube.com/watch?v=aaaaaaaaaaa", "https://example.com/song.mp3", "https://youtube.com/watch?v=bad", "https://youtube.com/watch?v=aaaaaaaaaaa&v=bbbbbbbbbbb"] {
            do { _ = try YouTubeLink(text); preconditionFailure("Unsafe link accepted") } catch { }
        }
        let api = YouTubeAPI(configuration: { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [YouTubeProtocol.self]; return config })
        let links = try await api.resolve(mixed, key: "")
        precondition(links.count == 2 && mock.count == 0, "Link preview must not require a key or fetch arbitrary URLs")
        await expect(.keyRequired) { _ = try await api.search("music", kind: .video, token: nil, key: "") }
        let page = try await api.search("music", kind: .video, token: nil, key: "test-key")
        precondition(page.entries.map(\.resourceID) == [mock.a, mock.b] && page.nextToken == "TWO")
        precondition(page.entries[0].title == "Title & aaaaaaaaaaa" && page.entries[0].durationLabel == "1:30")
        precondition(!page.entries[1].embeddable)
        let resolved = try await api.resolve(mixed, key: "test-key")
        precondition(resolved.map(\.kind) == [.video, .playlist])
        print("PASS: safe YouTube links, official API URLs/key headers, video/playlist metadata, durations and embedding eligibility")

        let store = YouTubeSearchStore(api: api, key: "test-key")
        store.search("music", kind: .playlist); await wait(store)
        let playlist = store.entries.first!
        store.openPlaylist(playlist); await wait(store)
        precondition(store.entries.map(\.position) == [0, 1] && !store.entries[1].available)
        store.selectAll(); await wait(store)
        precondition(store.selection.map(\.resourceID) == [mock.a, mock.b, mock.a], "Original order and repeated playlist entries must survive multi-selection")
        precondition(store.nextToken == nil)
        store.deselectAll(); precondition(store.selection.isEmpty)
        store.backToResults(); precondition(store.entries.first?.kind == .playlist && !store.isBrowsingPlaylist)
        print("PASS: public-playlist pagination, select-all across pages, unavailable entries, deselection and returning to results")

        for (mode, error) in [("quota", YouTubeError.quota), ("key", .keyRejected), ("invalid", .response), ("network", .network)] {
            mock.configure(mode)
            await expect(error) { _ = try await api.search("music", kind: .video, token: nil, key: "test-key") }
        }
        mock.configure("ok")
        let stale = YouTubeSearchStore(api: DelayedYouTube(), key: "test-key")
        stale.search("old", kind: .video)
        try await Task.sleep(nanoseconds: 20_000_000)
        stale.search("new", kind: .video); await wait(stale)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(stale.entries.first?.title == "new")
        stale.reset(); precondition(stale.entries.isEmpty && stale.selectedIDs.isEmpty)
        print("PASS: quota/key/network errors, cancelled/stale requests and bounded public metadata without real YouTube calls")
    }
}
