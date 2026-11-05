import SwiftUI

struct MacConnectionView: View {
    @EnvironmentObject private var connection: MacConnectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = MacDiscovery()
    @State private var address = ""
    @State private var fingerprint = ""
    @State private var secret = ""
    @State private var payload = ""
    @State private var identityConfirmed = false
    @State private var inputError: String?
    @State private var showingRemoval = false
    @State private var showingQRScanner = false
    @State private var showingQRConfirmation = false
    @State private var scannedPairing: MacPairingPayload?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(discovery.isSearching && !connection.isConfigured ? "Mac suchen" : connection.status.title,
                          systemImage: connection.status == .connected ? "checkmark.circle.fill" : "desktopcomputer")
                        .foregroundStyle(connection.status == .connected ? Color.accentColor : .primary)
                    if connection.isBusy || connection.status == .checking || discovery.isSearching { ProgressView() }
                    if let message = connection.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if let error = inputError { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Mac-Verbindung") }
                if connection.isConfigured {
                    MacImportView()
                    Section("Gekoppelter Mac") {
                        if let address = connection.serverAddress { LabeledContent("Adresse", value: address) }
                        if let name = connection.deviceName { LabeledContent("Gerätename", value: name) }
                        if let checked = connection.lastChecked { LabeledContent("Zuletzt geprüft") { Text(checked, style: .time) } }
                        if let fingerprint = connection.certificateFingerprint {
                            Text("SHA-256: \(fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Verbindung prüfen", systemImage: "arrow.clockwise") { connection.reconnect() }.disabled(connection.isBusy)
                    }
                    Section {
                        Button("Verbindung entfernen …", systemImage: "link", role: .destructive) { showingRemoval = true }.disabled(connection.isBusy)
                    } footer: { Text("Die Verbindung wird im Vordergrund automatisch geprüft. Im Hintergrund startet die App keine dauerhafte Netzwerksuche.") }
                } else {
                    Section {
                        Button("QR-Code am Mac scannen", systemImage: "qrcode.viewfinder") {
                            discovery.stop(); inputError = nil; scannedPairing = nil; showingQRScanner = true
                        }.disabled(connection.isBusy)
                        Button(discovery.isSearching ? "Suche beenden" : "Mac im Heimnetz suchen", systemImage: "network") {
                            if discovery.isSearching { discovery.stop() } else { discovery.start() }
                        }.disabled(connection.isBusy)
                        ForEach(discovery.servers) { mac in
                            Button {
                                address = mac.address; identityConfirmed = false; discovery.stop()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(mac.name); Text(mac.address).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if let message = discovery.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("Mac finden") } footer: { Text("Starte den Companion im Terminal mit „serve --bonjour“. Scanne den dort angezeigten QR-Code, um dich direkt zu verbinden. Beide Geräte müssen im selben erreichbaren Heimnetz sein.") }
                    Section {
                        TextEditor(text: $payload).frame(minHeight: 90).font(.caption.monospaced())
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel("Kopplungsdaten vom Mac als JSON")
                        Button("Kopplungsdaten übernehmen") { readPayload() }.disabled(payload.isEmpty || connection.isBusy)
                    } header: { Text("Kopplungsdaten einfügen") } footer: {
                        Text("Auf dem Mac „pair --name \"Mein iPhone\"“ ausführen. Die gesamte JSON-Ausgabe hier einfügen oder die Felder unten manuell ausfüllen. Der Code ist fünf Minuten gültig.")
                    }
                    Section {
                        TextField("https://192.168.1.23:8765", text: $address).keyboardType(.URL)
                            .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel("Manuelle Mac-Adresse")
                        SecureField("Einmaliger Kopplungscode", text: $secret).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("SHA-256-Fingerabdruck vom Mac", text: $fingerprint, axis: .vertical)
                            .font(.caption.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Toggle("Fingerabdruck mit der Anzeige auf meinem Mac abgeglichen", isOn: $identityConfirmed)
                        Button("Sicher koppeln", systemImage: "lock.shield") {
                            inputError = nil; discovery.stop()
                            connection.pair(address: address, fingerprint: fingerprint, secret: secret, identityConfirmed: identityConfirmed)
                            secret = ""; payload = ""
                        }.disabled(connection.isBusy || !identityConfirmed || address.isEmpty || fingerprint.isEmpty || secret.isEmpty)
                    } header: { Text("Sichere Erstkopplung") } footer: {
                        Text("Verwende nur Kopplungsdaten direkt von deinem Mac. 127.0.0.1 funktioniert nicht zwischen iPhone und Mac. Der dauerhafte Zugang wird ausschließlich im iOS-Schlüsselbund gespeichert.")
                    }
                }
                Section("Netzwerkzugriff erlauben") {
                    Button("iPhone-App-Einstellungen öffnen", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("Falls die Verbindung blockiert ist: Einstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → Offline Music einschalten. In den App-Einstellungen auch die Kamera für den QR-Code erlauben.").font(.footnote).foregroundStyle(.secondary)
                    Text("Mac: Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk. Beide Geräte müssen im gleichen erreichbaren WLAN sein.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mac-Verbindung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $showingQRScanner, onDismiss: { showingQRConfirmation = scannedPairing != nil }) {
                MacQRCodeScanner { text in
                    do { scannedPairing = try MacPairingPayload.parse(text); inputError = nil }
                    catch { scannedPairing = nil; inputError = error.localizedDescription }
                    showingQRScanner = false
                }
            }
            .alert("Mit diesem Mac verbinden?", isPresented: $showingQRConfirmation) {
                Button("Verbinden") {
                    guard let scanned = scannedPairing else { return }
                    scannedPairing = nil
                    guard scanned.expires_at > Date().timeIntervalSince1970 else {
                        inputError = MacConnectionError.expiredPairing.localizedDescription; return
                    }
                    connection.pair(address: scanned.url, fingerprint: scanned.server_certificate_sha256,
                                    secret: scanned.secret, identityConfirmed: true)
                }
                Button("Abbrechen", role: .cancel) { scannedPairing = nil }
            } message: {
                Text("\(scannedPairing?.url ?? "")\n\nBestätige nur, wenn du den QR-Code gerade direkt vom Terminal deines eigenen Macs gescannt hast. Die TLS-Identität wird anhand des Codes geprüft.")
            }
            .confirmationDialog("Mac-Verbindung entfernen?", isPresented: $showingRemoval, titleVisibility: .visible) {
                Button("Auf Mac widerrufen und entfernen", role: .destructive) { connection.revokeAndRemove() }
                Button("Nur auf diesem iPhone entfernen", role: .destructive) { connection.removeLocally() }
                Button("Abbrechen", role: .cancel) { }
            } message: { Text("Ein Widerruf benötigt eine Verbindung zum Mac. Beim rein lokalen Entfernen bleibt der Zugang dort aktiv und kann mit „revoke“ widerrufen werden.") }
            .onChange(of: address) { _, _ in identityConfirmed = false }
            .onChange(of: fingerprint) { _, _ in identityConfirmed = false }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    discovery.stop(); secret = ""; payload = ""; scannedPairing = nil
                    showingQRScanner = false; showingQRConfirmation = false
                }
            }
            .onDisappear { discovery.stop(); secret = ""; payload = "" }
        }
    }
    private func readPayload() {
        do {
            let value = try MacPairingPayload.parse(payload)
            address = value.url; fingerprint = value.server_certificate_sha256; secret = value.secret
            payload = ""; identityConfirmed = false; inputError = nil
        } catch { inputError = error.localizedDescription }
    }
}
