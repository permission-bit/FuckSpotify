import Foundation

enum MacImportError: Error, LocalizedError, Equatable {
    case invalidManifest, damagedFile, noSpace, missingPlaylist, stateUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Die Dateiangaben des Macs sind ungültig oder haben sich geändert."
        case .damagedFile: return "Die Datei ist unvollständig oder beschädigt. Größe, Prüfsumme oder Audioformat stimmen nicht."
        case .noSpace: return "Nicht genug freier Speicherplatz. Gib Speicher frei und versuche den Import erneut."
        case .missingPlaylist: return "Die Ziel-Playlist wurde gelöscht. Wähle ein neues Importziel."
        case .stateUnavailable: return "Der gespeicherte Importstatus kann nicht gelesen werden. Es werden keine Dateien automatisch erneut importiert."
        }
    }
}

struct MacAudioManifest: Codable, Equatable, Sendable {
    let format: String
    let duration: Double
    let size: Int64
    let sha256: String
    let metadata: [String: String]
    func validate() throws {
        guard format.split(separator: ",").contains("mp3"), duration.isFinite, duration > 0, duration <= 7202,
              size > 0, size <= 512 * 1024 * 1024, sha256.count == 64,
              sha256.allSatisfy({ "0123456789abcdef".contains($0) }), metadata.count <= 32,
              metadata.values.allSatisfy({ $0.utf8.count <= 8192 }) else { throw MacImportError.invalidManifest }
    }
}

struct MacReadyItem: Codable, Sendable {
    let id: UUID
    let position: Int
    let status: String
    let title: String?
    let playlist_title: String?
    let playlist_index: Int?
    let result: MacAudioManifest?
}

struct MacJobInfo: Codable, Sendable {
    let id: UUID
    let status: String
    let counts: [String: Int]
    let total_items: Int
    var request_id: UUID? = nil
    var title: String? = nil
    var created_at: Double? = nil
    var readyCount: Int { (counts["completed"] ?? 0) + (counts["reused"] ?? 0) }
    var failedCount: Int { ["failed", "unavailable", "cancelled", "interrupted"].reduce(0) { $0 + (counts[$1] ?? 0) } }
    var isRunning: Bool { ["queued", "running", "expanding"].contains(status) }
}

struct MacDelivery: Decodable, Sendable {
    let sequence: Int64
    let job: MacJobInfo
    let item: MacReadyItem
}
struct MacDeliveryPage: Decodable, Sendable {
    let deliveries: [MacDelivery]
    let next_after: Int64
    let has_more: Bool
}

protocol MacTransferNetworking: Sendable {
    func deliveries(_ credentials: MacCredentials, after: Int64) async throws -> MacDeliveryPage
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo
    func download(_ credentials: MacCredentials, jobID: UUID, itemID: UUID, manifest: MacAudioManifest,
                  destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

extension MacCompanionAPI: MacTransferNetworking {
    func deliveries(_ credentials: MacCredentials, after: Int64) async throws -> MacDeliveryPage {
        // Query construction is explicit: a server-provided path is never followed.
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint,
            path: "v1/deliveries", token: credentials.token, maximumBytes: 262144, query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "10")])
        guard let page = try? JSONDecoder().decode(MacDeliveryPage.self, from: data), page.deliveries.count <= 10,
              page.next_after >= after, !page.has_more || page.next_after > after,
              page.deliveries.allSatisfy({ $0.sequence > after && $0.sequence <= page.next_after && $0.item.position > 0 && $0.item.position <= $0.job.total_items && $0.job.total_items <= 1000 }) else { throw MacImportError.invalidManifest }
        for delivery in page.deliveries { try delivery.item.result?.validate() }
        return page
    }
    func jobInfo(_ credentials: MacCredentials, jobID: UUID) async throws -> MacJobInfo {
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/jobs/\(jobID.uuidString)",
                                     token: credentials.token, query: [URLQueryItem(name: "limit", value: "1")])
        guard let job = try? JSONDecoder().decode(MacJobInfo.self, from: data), job.id == jobID else { throw MacImportError.invalidManifest }
        return job
    }
    func download(_ credentials: MacCredentials, jobID: UUID, itemID: UUID, manifest: MacAudioManifest,
                  destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try manifest.validate()
        let delegate = MacDownloadDelegate(credentials: credentials, manifest: manifest, destination: destination, progress: progress)
        let config = configuration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = false; config.tlsMinimumSupportedProtocolVersion = .TLSv12
        // A daemon background session needs separately validated trust/relaunch
        // handling for this private anchor. Resume durable receipts in the
        // foreground and keep the existing checked TLS delegate in this phase.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: credentials.endpoint.url.appendingPathComponent("v1/jobs/\(jobID.uuidString)/items/\(itemID.uuidString)/file"))
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in delegate.start(session: session, request: request, continuation: continuation) }
        } onCancel: { delegate.cancel() }
    }
}

private final class MacDownloadDelegate: MacTLSDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private let manifest: MacAudioManifest
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?
    private var moved = false
    private var lastProgress: Double = -1

    init(credentials: MacCredentials, manifest: MacAudioManifest, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.manifest = manifest; self.destination = destination; self.progress = progress
        super.init(endpoint: credentials.endpoint, fingerprint: credentials.fingerprint)
    }
    func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Void, Error>) {
        stateLock.lock()
        if cancelled { stateLock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let task = session.downloadTask(with: request)
        self.task = task
        stateLock.unlock()
        task.resume()
    }
    func cancel() { stateLock.lock(); cancelled = true; let task = task; stateLock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > manifest.size || totalBytesExpectedToWrite > manifest.size {
            failure = MacImportError.damagedFile; downloadTask.cancel(); return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(manifest.size))
        if fraction - lastProgress >= 0.01 { lastProgress = fraction; progress(fraction) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw MacImportError.damagedFile }
            if response.statusCode == 401 || response.statusCode == 403 { throw MacConnectionError.unauthorized }
            guard response.statusCode == 200 else { throw MacConnectionError.server(response.statusCode) }
            guard response.url == downloadTask.originalRequest?.url,
                  response.mimeType == "audio/mpeg", response.expectedContentLength == manifest.size,
                  response.value(forHTTPHeaderField: "X-Content-SHA256") == manifest.sha256,
                  response.value(forHTTPHeaderField: "ETag") == "\"\(manifest.sha256)\"" else { throw MacImportError.damagedFile }
            // Move before returning: URLSession owns/deletes the temporary URL.
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let continuation = continuation; self.continuation = nil
        let cancelled = cancelled
        stateLock.unlock()
        guard let continuation else { return }
        if rejectedIdentity { continuation.resume(throwing: MacConnectionError.identity) }
        else if let failure { continuation.resume(throwing: failure) }
        else if cancelled { continuation.resume(throwing: CancellationError()) }
        else if let error {
            let ns = error as NSError
            if Self.diskFull(ns) { continuation.resume(throwing: MacImportError.noSpace) }
            else if ns.domain == NSURLErrorDomain, [-1200, -1201, -1202, -1203, -1204].contains(ns.code) { continuation.resume(throwing: MacConnectionError.identity) }
            else { continuation.resume(throwing: MacConnectionError.unavailable) }
        } else if !moved { continuation.resume(throwing: MacImportError.damagedFile) }
        else { continuation.resume() }
    }
    private static func diskFull(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == 28 || error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return diskFull(underlying, depth: depth + 1) }
        return false
    }
}
