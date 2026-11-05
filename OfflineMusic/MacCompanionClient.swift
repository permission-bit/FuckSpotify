import Foundation
import Security
import CryptoKit

enum MacConnectionError: Error, LocalizedError, Equatable {
    case address, fingerprint, pairingData, expiredPairing, identity, unauthorized, unavailable, invalidResponse
    case server(Int), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .address: return "Gib die private IPv4-Adresse deines Macs ein, z. B. https://192.168.1.23:8765. 127.0.0.1 zeigt auf das jeweilige Gerät."
        case .fingerprint: return "Der SHA-256-Fingerabdruck muss aus 64 Hexadezimalzeichen bestehen. Übernimm ihn direkt vom Mac."
        case .pairingData: return "Ungültige Kopplungsdaten. Erzeuge sie auf dem Mac erneut mit pair --name."
        case .expiredPairing: return "Die Kopplungsdaten sind abgelaufen. Erzeuge auf dem Mac einen neuen Code."
        case .identity: return "Die TLS-Identität des Macs konnte nicht bestätigt werden. Prüfe Adresse, Zertifikat und Fingerabdruck auf dem Mac."
        case .unauthorized: return "Der Zugang ist ungültig oder widerrufen. Bei der Erstkopplung kann auch der Einmalcode abgelaufen oder verbraucht sein."
        case .unavailable: return "Mac nicht erreichbar. Prüfe WLAN, lokalen Netzwerkzugriff und ob der Companion auf dem Mac läuft."
        case .invalidResponse: return "Die Antwort passt nicht zum Companion-Protokoll. Prüfe die Version des Mac-Dienstes."
        case .server(let status): return status == 429 ? "Zu viele Anfragen. Bitte warte kurz und versuche es erneut." : "Der Mac-Dienst meldet einen Fehler (HTTP \(status))."
        case .keychain: return "Der Zugang konnte nicht sicher im Schlüsselbund gelesen oder gespeichert werden. Entsperre das iPhone und versuche es erneut."
        }
    }
}

struct MacEndpoint: Codable, Equatable, Sendable {
    let url: URL
    var host: String { url.host! }
    var port: Int { url.port! }
    init(_ address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value.contains("://") ? value : "https://" + value),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host, Self.isLocalIPv4(host),
              (1024...65535).contains(parts.port ?? 8765) else { throw MacConnectionError.address }
        #if os(iOS)
        guard !host.hasPrefix("127.") else { throw MacConnectionError.address }
        #endif
        parts.port = parts.port ?? 8765; parts.path = ""
        guard let url = parts.url else { throw MacConnectionError.address }
        self.url = url
    }
    static func isLocalIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let octets = pieces.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), String(value) == part, (0...255).contains(value) else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(URL.self, forKey: .url).absoluteString)
    }
}

enum MacFingerprint {
    static func normalize(_ value: String) throws -> String {
        let compact = value.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        guard compact.count == 64, compact.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw MacConnectionError.fingerprint }
        return compact
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct MacPairingPayload: Decodable {
    let url: String
    let secret: String
    let expires_at: Double
    let server_certificate_sha256: String
    static func parse(_ text: String, now: Date = .now) throws -> Self {
        guard text.utf8.count <= 8192, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { throw MacConnectionError.pairingData }
        guard value.expires_at.isFinite, value.expires_at > now.timeIntervalSince1970 else { throw MacConnectionError.expiredPairing }
        _ = try MacEndpoint(value.url)
        _ = try MacFingerprint.normalize(value.server_certificate_sha256)
        try validateSecret(value.secret)
        return value
    }
    static func validateSecret(_ value: String) throws {
        guard (32...128).contains(value.utf8.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw MacConnectionError.pairingData }
    }
}

struct MacCredentials: Codable, Equatable, Sendable {
    let endpoint: MacEndpoint
    let fingerprint: String
    let deviceID: UUID
    let name: String
    let token: String
    func validated() throws -> Self {
        guard try MacFingerprint.normalize(fingerprint) == fingerprint,
              token.hasPrefix("omc_"), token.utf8.count == 47,
              token.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              !name.isEmpty, name.count <= 64 else { throw MacConnectionError.invalidResponse }
        return self
    }
}

// The exact certificate approved out of band becomes a private trust anchor.
// An SSL policy still validates the requested host and certificate chain.
class MacTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let endpoint: MacEndpoint
    let fingerprint: String
    private let lock = NSLock()
    private var rejected = false
    var rejectedIdentity: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    init(endpoint: MacEndpoint, fingerprint: String) { self.endpoint = endpoint; self.fingerprint = fingerprint }
    static func verify(_ trust: SecTrust, host: String, fingerprint: String) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        // CopyCertificateChain requires an evaluated trust. A self-signed server
        // normally fails this first system evaluation; it is not accepted yet.
        _ = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              MacFingerprint.hash(SecCertificateCopyData(leaf) as Data) == fingerprint,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == endpoint.host, challenge.protectionSpace.port == endpoint.port,
              let trust = challenge.protectionSpace.serverTrust,
              Self.verify(trust, host: endpoint.host, fingerprint: fingerprint) else {
            lock.lock(); rejected = true; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward secrets or credentials to redirects.
    }
}

protocol MacCompanionNetworking: Sendable {
    func pair(endpoint: MacEndpoint, fingerprint: String, secret: String) async throws -> MacCredentials
    func health(_ credentials: MacCredentials) async throws
    func revoke(_ credentials: MacCredentials) async throws
}

struct MacCompanionAPI: MacCompanionNetworking {
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    func pair(endpoint: MacEndpoint, fingerprint: String, secret: String) async throws -> MacCredentials {
        try MacPairingPayload.validateSecret(secret)
        let fingerprint = try MacFingerprint.normalize(fingerprint)
        let body = try JSONEncoder().encode(["secret": secret])
        let data = try await request(endpoint, fingerprint: fingerprint, path: "v1/pair", method: "POST", body: body)
        struct Paired: Decodable { let device_id: UUID; let name: String; let token: String; let token_type: String; let server_certificate_sha256: String }
        guard let response = try? JSONDecoder().decode(Paired.self, from: data), response.token_type == "Bearer",
              (try? MacFingerprint.normalize(response.server_certificate_sha256)) == fingerprint else { throw MacConnectionError.invalidResponse }
        return try MacCredentials(endpoint: endpoint, fingerprint: fingerprint, deviceID: response.device_id, name: response.name, token: response.token).validated()
    }
    func health(_ credentials: MacCredentials) async throws {
        let data = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/health", token: credentials.token)
        struct Health: Decodable { let status: String; let api_version: Int; let device_id: UUID }
        guard let response = try? JSONDecoder().decode(Health.self, from: data), response.status == "ok",
              response.api_version == 1, response.device_id == credentials.deviceID else { throw MacConnectionError.invalidResponse }
    }
    func revoke(_ credentials: MacCredentials) async throws {
        _ = try await request(credentials.endpoint, fingerprint: credentials.fingerprint, path: "v1/device", method: "DELETE", token: credentials.token)
    }
    func request(_ endpoint: MacEndpoint, fingerprint: String, path: String, method: String = "GET", token: String? = nil, body: Data? = nil, maximumBytes: Int = 65536, query: [URLQueryItem] = []) async throws -> Data {
        let delegate = MacTLSDelegate(endpoint: endpoint, fingerprint: try MacFingerprint.normalize(fingerprint))
        let config = configuration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false; config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var url = URLComponents(url: endpoint.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw MacConnectionError.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw MacConnectionError.unauthorized }
            guard (200...299).contains(http.statusCode) else { throw MacConnectionError.server(http.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw MacConnectionError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw MacConnectionError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch {
            if delegate.rejectedIdentity { throw MacConnectionError.identity }
            if let error = error as? URLError {
                if Task.isCancelled { throw CancellationError() }
                if [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(error.code) { throw MacConnectionError.identity }
                throw MacConnectionError.unavailable
            }
            throw error
        }
    }
}
