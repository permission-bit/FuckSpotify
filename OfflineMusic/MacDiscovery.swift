import Foundation
import Combine
import Darwin

struct DiscoveredMac: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
}

// These Foundation delegates run on the run loop where browsing/resolving starts.
// Both operations are created on the main actor.
@MainActor final class MacDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var servers: [DiscoveredMac] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var timeout: Task<Void, Never>?
    func start() {
        stop(); servers = []; message = nil; isSearching = true
        let browser = NetServiceBrowser()
        browser.delegate = self; self.browser = browser
        browser.searchForServices(ofType: "_offlinemusic._tcp.", inDomain: "local.")
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self else { return }
            self.stop()
            if self.servers.isEmpty { self.message = "Kein Mac gefunden. Starte den Companion mit serve --bonjour oder gib die Adresse manuell ein. Prüfe auch den lokalen Netzwerkzugriff in den iOS-Einstellungen." }
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services.values { service.stop(); service.delegate = nil }
        services.removeAll(); isSearching = false
    }
    private func key(_ service: NetService) -> String { service.name + "." + service.type + service.domain }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser, services.count < 32 else { return }
        services[key(service)] = service
        service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        services.removeValue(forKey: key(service))?.stop()
        servers.removeAll { $0.id == key(service) }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        stop(); message = "Die Mac-Suche ist nicht verfügbar. Erlaube lokalen Netzwerkzugriff in den iOS-Einstellungen oder nutze die manuelle Adresse."
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[key(sender)] === sender, (1024...65535).contains(sender.port) else { return }
        for data in sender.addresses ?? [] {
            let address: String? = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, buffer.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let socket = base.assumingMemoryBound(to: sockaddr.self)
                guard socket.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(socket, socklen_t(buffer.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            guard let address, let endpoint = try? MacEndpoint("https://\(address):\(sender.port)") else { continue }
            let discovered = DiscoveredMac(id: key(sender), name: sender.name, address: endpoint.url.absoluteString)
            servers.removeAll { $0.id == discovered.id }; servers.append(discovered)
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            break
        }
    }
}
