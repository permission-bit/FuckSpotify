import Foundation
import Combine
import Security
import Network

@MainActor protocol MacCredentialStoring {
    func load() throws -> MacCredentials?
    func save(_ credentials: MacCredentials) throws
    func remove() throws
}

@MainActor final class MacKeychainStore: MacCredentialStoring {
    private let service = (Bundle.main.bundleIdentifier ?? "OfflineMusic") + ".mac-companion"
    private let account = "paired-device-v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> MacCredentials? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MacConnectionError.keychain(status) }
        guard let data = result as? Data, let credentials = try? JSONDecoder().decode(MacCredentials.self, from: data) else { throw MacConnectionError.invalidResponse }
        return try credentials.validated()
    }
    func save(_ credentials: MacCredentials) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials.validated()),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw MacConnectionError.keychain(added) }
        } else if status != errSecSuccess { throw MacConnectionError.keychain(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacConnectionError.keychain(status) }
    }
}

enum MacConnectionStatus: Equatable {
    case notConfigured, checking, connected, unreachable, failed
    var title: String {
        switch self {
        case .notConfigured: return "Nicht eingerichtet"
        case .checking: return "Verbindung prüfen"
        case .connected: return "Verbunden"
        case .unreachable: return "Mac nicht erreichbar"
        case .failed: return "Verbindung fehlgeschlagen"
        }
    }
}

@MainActor final class MacConnectionStore: ObservableObject {
    @Published private(set) var status: MacConnectionStatus = .notConfigured
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    @Published private(set) var serverAddress: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var certificateFingerprint: String?
    var isConfigured: Bool { credentials != nil }
    private var credentials: MacCredentials?
    private let keychain: any MacCredentialStoring
    private let api: any MacCompanionNetworking
    private let monitorsNetwork: Bool
    private var monitor: NWPathMonitor?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var foreground = false
    func transferCredentials() -> MacCredentials? { credentials }

    init(keychain: (any MacCredentialStoring)? = nil, api: any MacCompanionNetworking = MacCompanionAPI(), monitorsNetwork: Bool = true) {
        self.keychain = keychain ?? MacKeychainStore(); self.api = api; self.monitorsNetwork = monitorsNetwork
        do {
            credentials = try self.keychain.load()
            updateSummary()
            if credentials != nil { status = .unreachable }
        } catch { status = .failed; message = error.localizedDescription }
    }
    func setActive(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active {
            if credentials != nil { startMonitoring(); reconnect() }
        } else {
            cancelWork()
            monitor?.cancel(); monitor = nil
            if status == .checking { status = isConfigured ? .unreachable : .notConfigured }
        }
    }
    private func startMonitoring() {
        guard monitorsNetwork, monitor == nil, foreground else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.foreground, !self.isBusy else { return }
                self.reconnect()
            }
        }
        monitor.start(queue: DispatchQueue(label: "OfflineMusic.mac-network"))
        self.monitor = monitor
    }
    func reconnect() {
        guard let credentials, foreground, !isBusy else { return }
        cancelWork()
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            var delay: UInt64 = 2
            while !Task.isCancelled && self.foreground && self.generation == generation {
                if self.status != .connected { self.status = .checking }
                do {
                    try await self.api.health(credentials)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.status = .connected; self.message = nil; self.lastChecked = .now
                    delay = 2
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.message = error.localizedDescription
                    let issue = error as? MacConnectionError
                    self.status = issue == .unavailable ? .unreachable : .failed
                    if issue == .identity || issue == .unauthorized || issue == .invalidResponse { return }
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                    delay = min(60, delay * 2)
                }
            }
        }
    }
    func pair(address: String, fingerprint: String, secret: String, identityConfirmed: Bool) {
        guard !isBusy, credentials == nil else { return }
        do {
            guard identityConfirmed else { throw MacConnectionError.identity }
            let endpoint = try MacEndpoint(address)
            let fingerprint = try MacFingerprint.normalize(fingerprint)
            try MacPairingPayload.validateSecret(secret)
            cancelWork(); isBusy = true; status = .checking; message = nil
            let generation = generation
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let credentials = try await self.api.pair(endpoint: endpoint, fingerprint: fingerprint, secret: secret)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    do { try self.keychain.save(credentials) }
                    catch {
                        try? await self.api.revoke(credentials)
                        throw error
                    }
                    self.credentials = credentials; self.updateSummary(); self.isBusy = false
                    self.startMonitoring(); self.reconnect()
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.isBusy = false; self.status = .failed; self.message = error.localizedDescription
                }
            }
        } catch { status = .failed; message = error.localizedDescription }
    }
    func removeLocally() {
        cancelWork()
        do { try keychain.remove(); credentials = nil; updateSummary(); status = .notConfigured; message = nil; lastChecked = nil }
        catch { status = .failed; message = error.localizedDescription }
        monitor?.cancel(); monitor = nil
    }
    func revokeAndRemove() {
        guard let credentials, !isBusy else { return }
        cancelWork(); isBusy = true; message = nil
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                do { try await self.api.revoke(credentials) }
                catch MacConnectionError.unauthorized { /* Already revoked. */ }
                guard !Task.isCancelled, self.generation == generation else { return }
                self.removeLocally()
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.isBusy = false; self.status = error as? MacConnectionError == .unavailable ? .unreachable : .failed
                self.message = "Widerruf nicht bestätigt. Der lokale Zugang bleibt für einen erneuten Versuch gespeichert. " + error.localizedDescription
            }
        }
    }
    private func cancelWork() { generation = UUID(); task?.cancel(); task = nil; isBusy = false }
    private func updateSummary() {
        serverAddress = credentials?.endpoint.url.absoluteString; deviceName = credentials?.name
        certificateFingerprint = credentials?.fingerprint
    }
}
