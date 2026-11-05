import Foundation
import Security

enum YouTubeError: Error, LocalizedError, Equatable {
    case keyRequired, invalidLink, unavailable, quota, keyRejected, response, network
    var errorDescription: String? {
        switch self {
        case .keyRequired: return "Hinterlege unter YouTube-Einstellungen deinen Schlüssel für die YouTube Data API v3. Einen Link kannst du auch direkt als Vorschau öffnen."
        case .invalidLink: return "Füge einen gültigen YouTube-Video- oder Playlist-Link ein. Andere Webseiten werden nicht als Medienquelle geöffnet."
        case .unavailable: return "Dieses Video oder diese öffentliche Playlist ist nicht verfügbar."
        case .quota: return "Das YouTube-API-Kontingent ist erreicht. Versuche es später erneut und prüfe dein Kontingent in der Google Cloud Console."
        case .keyRejected: return "YouTube hat den API-Schlüssel abgelehnt. Prüfe Schlüssel, API-Aktivierung und Einschränkungen in der Google Cloud Console."
        case .response: return "Die YouTube-Antwort konnte nicht gelesen werden. Bitte versuche es erneut."
        case .network: return "YouTube ist nicht erreichbar. Prüfe deine Internetverbindung und versuche es erneut."
        }
    }
}

enum YouTubeKind: String, Codable, CaseIterable, Sendable { case video, playlist }

struct YouTubeLink: Equatable, Sendable {
    let videoID: String?
    let playlistID: String?
    static func validVideo(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil }
    static func validPlaylist(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{10,128}$", options: .regularExpression) != nil }
    init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048, let parts = URLComponents(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(parts.scheme ?? ""), parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be", "www.youtube-nocookie.com", "youtube-nocookie.com"].contains(host) else { throw YouTubeError.invalidLink }
        let query = parts.queryItems ?? []
        guard query.filter({ $0.name == "v" }).count <= 1, query.filter({ $0.name == "list" }).count <= 1 else { throw YouTubeError.invalidLink }
        let path = parts.path.split(separator: "/").map(String.init)
        var video: String?
        if host.hasSuffix("youtu.be"), path.count == 1 { video = path.first }
        else if path.count == 1, path[0] == "watch" { video = query.first { $0.name == "v" }?.value }
        else if path.count == 2, ["embed", "shorts", "live"].contains(path[0]), path[1] != "videoseries" { video = path[1] }
        let playlist = query.first { $0.name == "list" }?.value
        videoID = video.flatMap { Self.validVideo($0) ? $0 : nil }
        playlistID = playlist.flatMap { Self.validPlaylist($0) ? $0 : nil }
        guard videoID != nil || playlistID != nil else { throw YouTubeError.invalidLink }
    }
}

struct YouTubeEntry: Identifiable, Equatable, Sendable {
    let id: String
    let resourceID: String
    let kind: YouTubeKind
    let title: String
    let channel: String
    let thumbnail: URL?
    var duration: String?
    var available = true
    var embeddable = true
    var position: Int?
    var publicURL: URL {
        var url = URLComponents(string: "https://www.youtube.com/" + (kind == .video ? "watch" : "playlist"))!
        url.queryItems = [URLQueryItem(name: kind == .video ? "v" : "list", value: resourceID)]
        return url.url!
    }
    var durationLabel: String? {
        guard let duration, let expression = try? NSRegularExpression(pattern: "^PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?$"),
              let match = expression.firstMatch(in: duration, range: NSRange(duration.startIndex..., in: duration)) else { return nil }
        let values = (1...3).map { group -> Int in
            guard let range = Range(match.range(at: group), in: duration) else { return 0 }
            return Int(duration[range]) ?? 0
        }
        guard values.allSatisfy({ $0 >= 0 && $0 < 100000 }) else { return nil }
        let seconds = values[0] * 3600 + values[1] * 60 + values[2]
        guard seconds > 0 else { return "Live / ohne Dauer" }
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func link(_ id: String, kind: YouTubeKind) -> Self {
        Self(id: kind.rawValue + ":" + id, resourceID: id, kind: kind,
             title: kind == .video ? "YouTube-Video" : "YouTube-Playlist", channel: "YouTube", thumbnail: nil)
    }
}

struct YouTubePage: Sendable { var entries: [YouTubeEntry]; let nextToken: String? }

protocol YouTubeNetworking: Sendable {
    func search(_ query: String, kind: YouTubeKind, token: String?, key: String) async throws -> YouTubePage
    func playlist(_ id: String, token: String?, key: String) async throws -> YouTubePage
    func resolve(_ link: YouTubeLink, key: String) async throws -> [YouTubeEntry]
}

private final class YouTubeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct YouTubeAPI: YouTubeNetworking {
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    private struct Page: Decodable { let items: [Item]; let nextPageToken: String? }
    private struct Item: Decodable {
        struct Identifier: Decodable { let videoId: String?; let playlistId: String? }
        struct Snippet: Decodable {
            struct Thumbnail: Decodable { let url: String }
            let title: String; let channelTitle: String?
            let videoOwnerChannelTitle: String?; let resourceId: Identifier?; let position: Int?
            let thumbnails: [String: Thumbnail]?
        }
        struct Details: Decodable { let duration: String? }
        struct Status: Decodable { let embeddable: Bool?; let privacyStatus: String? }
        let id: String
        let snippet: Snippet
        let contentDetails: Details?
        let status: Status?
        enum CodingKeys: String, CodingKey { case id, snippet, contentDetails, status }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(String.self, forKey: .id) { id = value }
            else {
                let value = try container.decode(Identifier.self, forKey: .id)
                id = value.videoId ?? value.playlistId ?? ""
            }
            snippet = try container.decode(Snippet.self, forKey: .snippet)
            contentDetails = try container.decodeIfPresent(Details.self, forKey: .contentDetails)
            status = try container.decodeIfPresent(Status.self, forKey: .status)
        }
        func entry(kind: YouTubeKind, playlistItem: Bool = false) -> YouTubeEntry? {
            let resource = playlistItem ? snippet.resourceId?.videoId : id
            guard let resource, kind == .video ? YouTubeLink.validVideo(resource) : YouTubeLink.validPlaylist(resource) else { return nil }
            let raw = snippet.thumbnails?["medium"]?.url ?? snippet.thumbnails?["default"]?.url
            let thumbnail = raw.flatMap(URL.init(string:)).flatMap { url -> URL? in
                guard url.scheme == "https", ["i.ytimg.com", "img.youtube.com", "yt3.ggpht.com"].contains(url.host ?? "") else { return nil }
                return url
            }
            return YouTubeEntry(id: (playlistItem ? "entry:" : kind.rawValue + ":") + id, resourceID: resource, kind: kind,
                title: Self.text(snippet.title), channel: Self.text(snippet.videoOwnerChannelTitle ?? snippet.channelTitle ?? "YouTube"),
                thumbnail: thumbnail, duration: contentDetails?.duration,
                available: status?.privacyStatus != "private", embeddable: status?.embeddable ?? true, position: snippet.position)
        }
        static func text(_ value: String) -> String {
            var text = value
            for (entity, replacement) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: replacement) }
            return text
        }
    }
    private func page(_ endpoint: String, query: [URLQueryItem], key: String) async throws -> Page {
        guard !key.isEmpty else { throw YouTubeError.keyRequired }
        var url = URLComponents(string: "https://www.googleapis.com/youtube/v3/" + endpoint)!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let identifier = Bundle.main.bundleIdentifier { request.setValue(identifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        let config = configuration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        let delegate = YouTubeSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse, http.url == request.url, response.expectedContentLength <= 1_048_576 else { throw YouTubeError.response }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw YouTubeError.response }
                data.append(byte)
            }
            if !(200...299).contains(http.statusCode) {
                let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let details = error?["error"] as? [String: Any]
                let reasons = (details?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
                if http.statusCode == 429 || reasons.contains(where: { ["quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded"].contains($0) }) { throw YouTubeError.quota }
                if reasons.contains(where: { ["playlistNotFound", "videoNotFound", "playlistItemsNotAccessible", "playlistForbidden"].contains($0) }) { throw YouTubeError.unavailable }
                if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 { throw YouTubeError.keyRejected }
                if http.statusCode == 404 { throw YouTubeError.unavailable }
                throw YouTubeError.response
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data), page.items.count <= 50 else { throw YouTubeError.response }
            return page
        } catch is CancellationError { throw CancellationError() }
        catch let error as YouTubeError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw YouTubeError.network }
    }
    func search(_ query: String, kind: YouTubeKind, token: String?, key: String) async throws -> YouTubePage {
        var parameters = [URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "type", value: kind.rawValue),
                          URLQueryItem(name: "maxResults", value: "25"), URLQueryItem(name: "q", value: query)]
        if kind == .video { parameters.append(URLQueryItem(name: "videoEmbeddable", value: "true")) }
        if let token { parameters.append(URLQueryItem(name: "pageToken", value: token)) }
        let response = try await page("search", query: parameters, key: key)
        var entries = response.items.compactMap { $0.entry(kind: kind) }
        if kind == .video { entries = try await enrich(entries, key: key) }
        return YouTubePage(entries: entries, nextToken: response.nextPageToken)
    }
    func playlist(_ id: String, token: String?, key: String) async throws -> YouTubePage {
        guard YouTubeLink.validPlaylist(id) else { throw YouTubeError.invalidLink }
        var parameters = [URLQueryItem(name: "part", value: "snippet,contentDetails,status"), URLQueryItem(name: "playlistId", value: id), URLQueryItem(name: "maxResults", value: "50")]
        if let token { parameters.append(URLQueryItem(name: "pageToken", value: token)) }
        let response = try await page("playlistItems", query: parameters, key: key)
        let entries = try await enrich(response.items.compactMap { $0.entry(kind: .video, playlistItem: true) }, key: key)
        return YouTubePage(entries: entries.sorted { ($0.position ?? 0) < ($1.position ?? 0) }, nextToken: response.nextPageToken)
    }
    private func enrich(_ entries: [YouTubeEntry], key: String) async throws -> [YouTubeEntry] {
        guard !entries.isEmpty else { return [] }
        let response = try await page("videos", query: [URLQueryItem(name: "part", value: "snippet,contentDetails,status"), URLQueryItem(name: "id", value: entries.map(\.resourceID).joined(separator: ","))], key: key)
        let details = Dictionary(response.items.compactMap { $0.entry(kind: .video) }.map { ($0.resourceID, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { entry in
            var result = entry
            if let detail = details[entry.resourceID] { result.duration = detail.duration; result.available = detail.available; result.embeddable = detail.embeddable }
            else { result.available = false; result.embeddable = false }
            return result
        }
    }
    func resolve(_ link: YouTubeLink, key: String) async throws -> [YouTubeEntry] {
        if key.isEmpty {
            return [link.videoID.map { .link($0, kind: .video) }, link.playlistID.map { .link($0, kind: .playlist) }].compactMap { $0 }
        }
        var result: [YouTubeEntry] = []
        if let video = link.videoID {
            let response = try await page("videos", query: [URLQueryItem(name: "part", value: "snippet,contentDetails,status"), URLQueryItem(name: "id", value: video)], key: key)
            result += response.items.compactMap { $0.entry(kind: .video) }
        }
        if let playlist = link.playlistID {
            let response = try await page("playlists", query: [URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "id", value: playlist)], key: key)
            result += response.items.compactMap { $0.entry(kind: .playlist) }
        }
        guard !result.isEmpty else { throw YouTubeError.unavailable }
        return result
    }
}

@MainActor final class YouTubeKeyStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "OfflineMusic") + ".youtube-api",
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> String {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw MacConnectionError.keychain(status) }
        return value
    }
    func save(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try remove(); return }
        guard value.utf8.count <= 256, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw YouTubeError.keyRejected }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw MacConnectionError.keychain(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacConnectionError.keychain(status) }
    }
}
