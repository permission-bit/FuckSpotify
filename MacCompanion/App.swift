import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import Darwin

private final class ErrorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value); data = data.suffix(4096) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

@MainActor final class CompanionModel: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/OfflineMusicCompanion").path
    @Published var host = ""
    @Published var running = false
    @Published var busy = false
    @Published var message = "Mac starten, dann den QR-Code mit der Musik-App scannen."
    @Published var qr: NSImage?
    @Published var expires = Date.distantPast
    @Published var devices: [Device] = []
    @Published var selectedDevice = ""
    @Published var confirmingRevoke = false
    private var server: Process?
    var ownsService: Bool { server != nil }
    private var log = Data()
    private var runID = UUID()
    struct Device: Decodable, Identifiable { let id: String; let name: String; let revoked_at: Double? }
    var runtime: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime/companion-runtime") }
    init() {
        root = UserDefaults.standard.string(forKey: "companion.root") ?? root
        host = Self.addresses().first ?? ""
    }
    nonisolated static func execute(_ executable: URL, _ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = executable; process.arguments = args
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        // CLI responses are small. Drain errors concurrently to avoid a full pipe.
        let errorOutput = ErrorOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorOutput.append(data)
        }
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); errors.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let text = errorOutput.text
            throw NSError(domain: "Companion", code: 1, userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Der Vorgang ist fehlgeschlagen. Prüfe Adresse und Arbeitsordner." : text])
        }
        return result
    }
    private func call(_ arguments: [String]) async throws -> Data {
        let executable = runtime, args = ["--root", root] + arguments
        return try await Task.detached { try Self.execute(executable, args) }.value
    }
    func start() {
        guard !busy, server == nil else { return }
        busy = true; message = "Mac wird vorbereitet …"; runID = UUID()
        let id = runID
        Task { [self] in
            do {
                let config = URL(fileURLWithPath: root).appendingPathComponent(".companion/config.json")
                if FileManager.default.fileExists(atPath: config.path) {
                    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
                    host = settings?["host"] as? String ?? ""
                } else { _ = try await call(["init", "--host", host]) }
                guard !host.hasPrefix("127."), !host.isEmpty else { throw NSError(domain: "Companion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Dieser Ordner ist nur für diesen Mac eingerichtet. Wähle einen neuen Arbeitsordner für die Heimnetz-Verbindung. Vorhandene Daten bleiben erhalten."]) }
                UserDefaults.standard.set(root, forKey: "companion.root")
                let executable = runtime, directory = root
                let existing = try await Task.detached { try Self.execute(executable, ["--desktop-status", directory]) }.value
                if (try JSONSerialization.jsonObject(with: existing) as? [String: Bool])?["ready"] == true {
                    running = true; busy = false
                    message = "Vorhandener Dienst wird verwendet. Schließen dieser App beendet den separat gestarteten Dienst nicht."
                    await refreshDevices(); await pair(); return
                }
                let process = Process(); process.executableURL = runtime
                process.arguments = ["--root", root, "serve", "--bonjour", "--no-qr"]
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe(); process.standardError = errors; log = Data()
                errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    Task { @MainActor in self?.log.append(data); if let self, self.log.count > 4096 { self.log = self.log.suffix(4096) } }
                }
                process.terminationHandler = { [weak self] _ in
                    errors.fileHandleForReading.readabilityHandler = nil
                    Task { @MainActor in
                        guard let self, self.runID == id else { return }
                        self.server = nil; self.running = false; self.qr = nil; self.busy = false
                        if process.terminationStatus != 0 { self.message = "Start fehlgeschlagen. Eventuell läuft der Dienst bereits oder die IP hat sich geändert.\n" + String(decoding: self.log, as: UTF8.self) }
                    }
                }
                try process.run(); server = process
                for _ in 0..<12 {
                    guard process.isRunning else { throw NSError(domain: "Companion", code: 3, userInfo: [NSLocalizedDescriptionKey: "Dienst konnte nicht gestartet werden. Prüfe, ob bereits eine Instanz läuft."]) }
                    let executable = runtime, directory = root
                    let data = try await Task.detached { try Self.execute(executable, ["--desktop-status", directory]) }.value
                    if (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["ready"] == true {
                        running = true; busy = false; message = "Bereit. Beide Geräte müssen im selben WLAN sein."
                        await refreshDevices(); await pair(); return
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                throw NSError(domain: "Companion", code: 4, userInfo: [NSLocalizedDescriptionKey: "Mac nicht erreichbar. Prüfe Lokales Netzwerk und Firewall. Bestehende Zertifikate werden nicht verändert."])
            } catch { message = error.localizedDescription; stop() }
            busy = false
        }
    }
    func stop() { qr = nil; running = false; server?.terminate() }
    func shutdown() { server?.terminate(); server?.waitUntilExit() }
    func pair() async {
        guard running else { return }
        do {
            let data = try await call(["pair", "--name", "Mein iPhone"])
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expires = Date(timeIntervalSince1970: value?["expires_at"] as? Double ?? 0)
            let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
            if let image = filter.outputImage, let cg = CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 7, y: 7)), from: image.extent.applying(CGAffineTransform(scaleX: 7, y: 7))) {
                qr = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
            }
        } catch { message = error.localizedDescription }
    }
    func refreshDevices() async {
        do {
            devices = try JSONDecoder().decode([Device].self, from: await call(["devices"])).filter { $0.revoked_at == nil }
            if !devices.contains(where: { $0.id == selectedDevice }) { selectedDevice = devices.first?.id ?? "" }
        } catch { message = error.localizedDescription }
    }
    func addFiles() {
        guard !selectedDevice.isEmpty else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        busy = true; let device = selectedDevice, urls = panel.urls
        Task {
            defer { busy = false }
            var count = 0
            do { for url in urls { _ = try await call(["add-file", "--device", device, url.path]); count += 1 }; message = "\(count) Dateien freigegeben. Auf dem iPhone: YouTube & Import → Importe." }
            catch { message = "\(count) Dateien freigegeben. " + error.localizedDescription }
        }
    }
    func revoke() async {
        do { _ = try await call(["revoke", selectedDevice]); await refreshDevices(); message = "Gerät widerrufen." }
        catch { message = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { root = url.path; UserDefaults.standard.set(root, forKey: "companion.root") }
    }
    static func settings(_ location: String) { if let url = URL(string: "x-apple.systempreferences:" + location) { NSWorkspace.shared.open(url) } }
    static func addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }; var current = pointer; var result: [String] = []
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name).hasPrefix("en"), let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer); let parts = ip.split(separator: ".").compactMap { Int($0) }
                if parts.count == 4 && (parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))) { result.append(ip) }
            }
        }
        return result
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CompanionModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct CompanionDesktop: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        WindowGroup("OfflineMusic Companion") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("OfflineMusic Companion", systemImage: "desktopcomputer").font(.largeTitle.bold())
                    Text("1. Mac starten  →  2. Mit iPhone scannen  →  3. Eigene Musik freigeben").foregroundStyle(.secondary)
                    GroupBox("Verbindung") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Private Mac-IP", text: $model.host).disabled(model.running || model.busy)
                            Text(model.root).font(.caption).textSelection(.enabled)
                            Button("Arbeitsordner wählen …") { model.chooseFolder() }.disabled(model.running || model.busy)
                            HStack {
                                Button("Mac starten") { model.start() }.buttonStyle(.borderedProminent).disabled(model.running || model.busy)
                                Button(model.ownsService ? "Stoppen" : "Verbindung schließen") { model.stop() }.disabled(!model.running)
                                if model.busy { ProgressView().controlSize(.small) }
                            }
                            Text(model.message).font(.callout).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if model.running {
                        GroupBox("iPhone verbinden") {
                            VStack(spacing: 10) {
                                if let qr = model.qr, model.expires > Date() {
                                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 280, height: 280).padding(20).background(.white)
                                }
                                Text("iPhone: Musik-App → Start → Mac-Symbol → QR-Code scannen")
                                Text("Der Code gilt 5 Minuten. Nur direkt von deinem eigenen Mac scannen.").font(.caption)
                                Button("Neuen QR-Code anzeigen") { Task { await model.pair() } }
                            }.padding(8).frame(maxWidth: .infinity)
                        }
                        GroupBox("Eigene Musik freigeben") {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("iPhone", selection: $model.selectedDevice) {
                                    Text("Gerät auswählen").tag("")
                                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                                }
                                Button("Geräteliste aktualisieren") { Task { await model.refreshDevices() } }
                                Button("Audiodateien auswählen …") { model.addFiles() }.disabled(model.selectedDevice.isEmpty || model.busy)
                                Text("Nur eigene oder entsprechend autorisierte Dateien. Originale bleiben erhalten. Danach auf dem iPhone unter Importe auswählen.").font(.caption)
                                Button("Ausgewähltes Gerät widerrufen", role: .destructive) { model.confirmingRevoke = true }.disabled(model.selectedDevice.isEmpty)
                            }.padding(8)
                        }
                    }
                    GroupBox("Verbindung klappt nicht?") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Mac: Lokales Netzwerk öffnen") { CompanionModel.settings("com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") }
                            Text("Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → OfflineMusic Companion erlauben (falls angezeigt).")
                            Button("Mac: Netzwerkeinstellungen öffnen") { CompanionModel.settings("com.apple.Network-Settings.extension") }
                            Text("Bei Firewall-Rückfrage eingehende Verbindungen für diese App erlauben. Netzwerk → Firewall → Optionen. Firewall eingeschaltet lassen.")
                            Text("iPhone: Einstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → Offline Music. Kamerazugriff in den App-Einstellungen erlauben. Gleiches WLAN verwenden; Gastnetze/VPN können Geräte trennen.")
                        }.font(.callout).padding(8)
                    }
                }.padding(24)
            }.frame(minWidth: 560, minHeight: 650)
                .onAppear { delegate.model = model }
                .confirmationDialog("Gerät wirklich widerrufen?", isPresented: $model.confirmingRevoke) { Button("Widerrufen", role: .destructive) { Task { await model.revoke() } } }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard !Task.isCancelled else { return }
                        if model.running && model.expires <= Date() { await model.pair() }
                    }
                }
        }
    }
}
