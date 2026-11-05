// Compiled with production client/store by run_mac_connection_tests.py.
// URLProtocol mock server covers API and lifecycle; a real HTTPS fixture covers TLS.
import Foundation
import Security
import Darwin
import Vision

final class MockMacServer: @unchecked Sendable {
    static let shared = MockMacServer()
    let lock = NSLock()
    let deviceID = UUID()
    let fingerprint = String(repeating: "a", count: 64)
    let token = "omc_" + String(repeating: "t", count: 43)
    private var mode = "ok"
    private var healthRequests = 0
    private var pairRequests = 0
    private var revokeRequests = 0
    func configure(_ mode: String) { lock.lock(); self.mode = mode; lock.unlock() }
    func counts() -> (health: Int, pair: Int, revoke: Int) {
        lock.lock(); defer { lock.unlock() }; return (healthRequests, pairRequests, revokeRequests)
    }
    func handle(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        switch request.url!.path {
        case "/v1/pair":
            pairRequests += 1
            precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, try JSONSerialization.data(withJSONObject: ["device_id": deviceID.uuidString, "name": "Test iPhone", "token": token, "token_type": "Bearer", "server_certificate_sha256": fingerprint]))
        case "/v1/health":
            healthRequests += 1
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            if mode == "offline" { throw URLError(.cannotConnectToHost) }
            if mode == "onceOffline" { mode = "ok"; throw URLError(.timedOut) }
            if mode == "revoked" { return (401, Data()) }
            if mode == "large" { return (200, Data(repeating: 65, count: 65537)) }
            if mode == "invalid" { return (200, Data("not json".utf8)) }
            let id = mode == "wrongDevice" ? UUID() : deviceID
            return (200, try JSONSerialization.data(withJSONObject: ["status": "ok", "api_version": 1, "device_id": id.uuidString]))
        case "/v1/device":
            revokeRequests += 1
            precondition(request.httpMethod == "DELETE" && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            if mode == "offline" { throw URLError(.cannotConnectToHost) }
            if mode == "revoked" { return (401, Data()) }
            return (204, Data())
        default: preconditionFailure("Unexpected API request")
        }
    }
}

final class MockMacURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try MockMacServer.shared.handle(request)
            // No Content-Length: also exercise the streaming response size bound.
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor final class MemoryMacKeychain: MacCredentialStoring {
    var value: MacCredentials?
    var failSave = false
    func load() -> MacCredentials? { value }
    func save(_ credentials: MacCredentials) throws {
        if failSave { throw MacConnectionError.keychain(errSecInteractionNotAllowed) }
        // Exercise the actual persisted format and its validation, without touching a user's keychain.
        value = try JSONDecoder().decode(MacCredentials.self, from: JSONEncoder().encode(credentials)).validated()
    }
    func remove() { value = nil }
}

actor DelayedMacAPI: MacCompanionNetworking {
    private(set) var entered = false
    func pair(endpoint: MacEndpoint, fingerprint: String, secret: String) async throws -> MacCredentials { throw MacConnectionError.invalidResponse }
    func health(_ credentials: MacCredentials) async throws {
        entered = true
        // Deliberately ignore cancellation: the store must reject stale results itself.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    func revoke(_ credentials: MacCredentials) async throws { }
}

@main struct MacConnectionChecks {
    @MainActor static func wait(_ condition: () -> Bool, seconds: Double = 4) async {
        let until = Date().addingTimeInterval(seconds)
        while !condition(), Date() < until { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for connection state")
    }
    static func expect(_ expected: MacConnectionError, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch { precondition(error as? MacConnectionError == expected, "Unexpected error: \(error)") }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let mock = MockMacServer.shared
        let endpoint = try MacEndpoint("192.168.1.23:8765")
        precondition(endpoint.url.absoluteString == "https://192.168.1.23:8765")
        for invalid in ["http://192.168.1.23:8765", "https://8.8.8.8:8765", "https://0.0.0.0:8765", "https://192.168.1.23:80", "https://user:pass@192.168.1.23:8765", "https://192.168.1.23:8765/secret", "https://192.168.1.23:8765?q=1", "https://192.168.01.23:8765"] {
            do { _ = try MacEndpoint(invalid); preconditionFailure("Accepted unsafe address") } catch MacConnectionError.address { }
        }
        let normalized = try MacFingerprint.normalize(String(repeating: "AA:", count: 31) + "AA")
        precondition(normalized == mock.fingerprint)
        let payload = try JSONSerialization.data(withJSONObject: ["url": endpoint.url.absoluteString, "secret": String(repeating: "s", count: 43), "expires_at": Date().timeIntervalSince1970 + 300, "server_certificate_sha256": mock.fingerprint])
        _ = try MacPairingPayload.parse(String(decoding: payload, as: UTF8.self))
        do { _ = try MacPairingPayload.parse(String(decoding: payload, as: UTF8.self), now: Date().addingTimeInterval(600)); preconditionFailure("Accepted expired pairing") } catch MacConnectionError.expiredPairing { }
        print("PASS: private HTTPS address validation, fingerprints and expiring pairing payloads")

        let api = MacCompanionAPI(configuration: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockMacURLProtocol.self]; return config
        })
        let credentials = try await api.pair(endpoint: endpoint, fingerprint: mock.fingerprint, secret: String(repeating: "s", count: 43))
        try await api.health(credentials)
        for (mode, error) in [("revoked", MacConnectionError.unauthorized), ("offline", .unavailable), ("invalid", .invalidResponse), ("wrongDevice", .invalidResponse), ("large", .invalidResponse)] {
            mock.configure(mode)
            await expect(error) { try await api.health(credentials) }
        }
        mock.configure("ok")
        try await api.revoke(credentials)
        print("PASS: mock-server pairing, bearer authentication, health, revocation, invalid/oversized responses and network errors")

        let keychain = MemoryMacKeychain()
        let store = MacConnectionStore(keychain: keychain, api: api, monitorsNetwork: false)
        store.setActive(true)
        let before = mock.counts().pair
        store.pair(address: endpoint.url.absoluteString, fingerprint: mock.fingerprint, secret: String(repeating: "s", count: 43), identityConfirmed: false)
        precondition(store.status == .failed && mock.counts().pair == before)
        store.pair(address: endpoint.url.absoluteString, fingerprint: mock.fingerprint, secret: String(repeating: "s", count: 43), identityConfirmed: true)
        await wait { store.status == .connected }
        precondition(keychain.value == credentials)
        store.setActive(false)
        let stoppedCount = mock.counts().health
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(mock.counts().health == stoppedCount)
        mock.configure("onceOffline")
        store.setActive(true)
        await wait { store.status == .unreachable }
        await wait { store.status == .connected }
        store.setActive(false)
        let restored = MacConnectionStore(keychain: keychain, api: api, monitorsNetwork: false)
        restored.setActive(true)
        await wait { restored.status == .connected }
        precondition(mock.counts().pair == before + 1, "Restoring credentials must not create a new pairing")
        mock.configure("offline")
        restored.revokeAndRemove()
        await wait { !restored.isBusy }
        precondition(restored.isConfigured && keychain.value != nil && restored.status == .unreachable)
        mock.configure("ok")
        restored.revokeAndRemove()
        await wait { restored.status == .notConfigured }
        precondition(keychain.value == nil)
        restored.setActive(false)
        print("PASS: explicit identity approval, credential persistence, automatic reconnect, foreground lifecycle and confirmed revocation")

        keychain.value = credentials
        let delayed = DelayedMacAPI()
        let stale = MacConnectionStore(keychain: keychain, api: delayed, monitorsNetwork: false)
        stale.setActive(true)
        while !(await delayed.entered) { try await Task.sleep(nanoseconds: 10_000_000) }
        stale.removeLocally()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(stale.status == .notConfigured && keychain.value == nil)
        stale.setActive(false)
        keychain.value = credentials
        mock.configure("revoked")
        let revoked = MacConnectionStore(keychain: keychain, api: api, monitorsNetwork: false)
        revoked.setActive(true)
        await wait { revoked.status == .failed }
        let rejectedCount = mock.counts().health
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(mock.counts().health == rejectedCount && revoked.isConfigured,
                     "Revoked credentials must stop automatic retries without silently discarding the stored identity")
        revoked.revokeAndRemove()
        await wait { revoked.status == .notConfigured }
        precondition(keychain.value == nil, "An already revoked credential must still be removable")
        revoked.setActive(false); mock.configure("ok")
        print("PASS: revoked credentials stop automatic retries and can be explicitly removed")
        keychain.failSave = true
        let failing = MacConnectionStore(keychain: keychain, api: api, monitorsNetwork: false)
        failing.setActive(true)
        let revokes = mock.counts().revoke
        failing.pair(address: endpoint.url.absoluteString, fingerprint: mock.fingerprint, secret: String(repeating: "s", count: 43), identityConfirmed: true)
        await wait { failing.status == .failed && !failing.isBusy }
        precondition(keychain.value == nil && mock.counts().revoke == revokes + 1)
        failing.setActive(false)
        print("PASS: removal rejects stale async results; failed secure persistence revokes the new server credential")

        if CommandLine.arguments.count >= 3 { try await tlsChecks(address: CommandLine.arguments[1], certificatePath: CommandLine.arguments[2]) }
        if CommandLine.arguments.count >= 4 {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[3])).perform([request])
            guard let text = request.results?.first?.payloadStringValue else { preconditionFailure("Apple Vision must decode the companion QR") }
            let payload = try MacPairingPayload.parse(text)
            let certificate = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            precondition(payload.url == "https://192.168.178.40:8765" && payload.secret == String(repeating: "s", count: 43))
            precondition(payload.server_certificate_sha256 == MacFingerprint.hash(certificate))
            print("PASS: Python-generated QR decoded by Apple Vision into the production Swift pairing protocol with the exact TLS pin")
        }
    }

    static func tlsChecks(address: String, certificatePath: String) async throws {
        let endpoint = try MacEndpoint(address)
        let der = try Data(contentsOf: URL(fileURLWithPath: certificatePath))
        let fingerprint = MacFingerprint.hash(der)
        let certificate = SecCertificateCreateWithData(nil, der as CFData)!
        func trust() -> SecTrust {
            var result: SecTrust?
            precondition(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, endpoint.host as CFString), &result) == errSecSuccess)
            return result!
        }
        let approved = trust()
        if !MacTLSDelegate.verify(approved, host: endpoint.host, fingerprint: fingerprint) {
            var error: CFError?
            _ = SecTrustEvaluateWithError(approved, &error)
            FileHandle.standardError.write(Data("Trust fixture failed: \(String(describing: error))\n".utf8))
            preconditionFailure("Valid pinned certificate must pass")
        }
        precondition(!MacTLSDelegate.verify(trust(), host: "192.168.254.254", fingerprint: fingerprint))
        precondition(!MacTLSDelegate.verify(trust(), host: endpoint.host, fingerprint: String(repeating: "0", count: 64)))
        let expired = trust()
        SecTrustSetVerifyDate(expired, Date().addingTimeInterval(400 * 86400) as CFDate)
        precondition(!MacTLSDelegate.verify(expired, host: endpoint.host, fingerprint: fingerprint), "Expired pinned certificates must be rejected")
        let notYetValid = trust()
        SecTrustSetVerifyDate(notYetValid, Date(timeIntervalSince1970: 0) as CFDate)
        precondition(!MacTLSDelegate.verify(notYetValid, host: endpoint.host, fingerprint: fingerprint))
        let api = MacCompanionAPI()
        await expect(.identity) { _ = try await api.pair(endpoint: endpoint, fingerprint: String(repeating: "0", count: 64), secret: String(repeating: "s", count: 43)) }
        let credentials = try await api.pair(endpoint: endpoint, fingerprint: fingerprint, secret: String(repeating: "s", count: 43))
        try await api.health(credentials)
        // A prior successful session must not let a subsequent wrong pin pass.
        await expect(.identity) { _ = try await api.pair(endpoint: endpoint, fingerprint: String(repeating: "0", count: 64), secret: String(repeating: "R", count: 43)) }
        try await api.revoke(credentials)
        await expect(.unauthorized) { try await api.health(credentials) }
        let redirect = try await api.pair(endpoint: endpoint, fingerprint: fingerprint, secret: String(repeating: "R", count: 43))
        await expect(.server(302)) { try await api.health(redirect) }
        print("PASS: real URLSession HTTPS, matching pin, rejected wrong pin/host/expired/future certificate, revocation and refused redirects")
        if CommandLine.arguments.count >= 5 { try await downloadChecks(api, credentials: redirect) }
    }

    static func downloadChecks(_ api: MacCompanionAPI, credentials: MacCredentials) async throws {
        let manifest = try JSONDecoder().decode(MacAudioManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-check-" + UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        let job = UUID()
        func item(_ number: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000000\(number)")! }
        try await api.download(credentials, jobID: job, itemID: item(1), manifest: manifest, destination: destination, progress: { _ in })
        let receivedHash = MacFingerprint.hash(try Data(contentsOf: destination))
        precondition(receivedHash == manifest.sha256)
        try FileManager.default.removeItem(at: destination)
        await expect(.unavailable) { try await api.download(credentials, jobID: job, itemID: item(2), manifest: manifest, destination: destination, progress: { _ in }) }
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        await expect(.server(302)) { try await api.download(credentials, jobID: job, itemID: item(3), manifest: manifest, destination: destination, progress: { _ in }) }
        do {
            try await api.download(credentials, jobID: job, itemID: item(4), manifest: manifest, destination: destination, progress: { _ in })
            preconditionFailure("Oversized transfer must fail")
        } catch { precondition(error as? MacImportError == .damagedFile) }
        let wrong = MacCredentials(endpoint: credentials.endpoint, fingerprint: String(repeating: "0", count: 64), deviceID: credentials.deviceID, name: credentials.name, token: credentials.token)
        await expect(.identity) { try await api.download(wrong, jobID: job, itemID: item(1), manifest: manifest, destination: destination, progress: { _ in }) }
        let cancelled = Task { try await api.download(credentials, jobID: job, itemID: item(1), manifest: manifest, destination: destination, progress: { _ in }) }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancelled download must fail") } catch is CancellationError { }
        print("PASS: real URLSessionDownloadTask, interrupted body, size bound, rejected redirect/wrong pin and cancellation")
    }
}
