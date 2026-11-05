import SwiftUI
import VisionKit
import AVFoundation

struct MacQRCodeScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var cameraAllowed = false
    @State private var message: String?
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Scanne den QR-Code im Terminal deines Macs.")
                    .font(.headline).multilineTextAlignment(.center).padding(.horizontal)
                if let message {
                    ContentUnavailableView("Kamera nicht verfügbar", systemImage: "camera", description: Text(message))
                    Button("App-Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Text("Du kannst die Kopplungsdaten weiterhin manuell einfügen.").font(.footnote).foregroundStyle(.secondary)
                } else if cameraAllowed {
                    CameraScanner(isActive: scenePhase == .active, onScan: onScan, onFailure: { message = $0 })
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Kamera zum Scannen des Companion-QR-Codes")
                } else { ProgressView("Kamerazugriff prüfen …").frame(maxHeight: .infinity) }
            }
            .padding()
            .navigationTitle("QR-Code scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task {
                guard DataScannerViewController.isSupported else {
                    message = "QR-Scannen wird auf diesem Gerät nicht unterstützt. Im Simulator steht keine Kamera zur Verfügung."
                    return
                }
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                default: allowed = false
                }
                guard !Task.isCancelled else { return }
                guard allowed, DataScannerViewController.isAvailable else {
                    message = "Erlaube Offline Music den Kamerazugriff in den iPhone-Einstellungen. Auch eine Bildschirmzeit-Beschränkung kann die Kamera sperren."
                    return
                }
                cameraAllowed = true
            }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let isActive: Bool
    let onScan: (String) -> Void
    let onFailure: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerHost {
        ScannerHost(onScan: onScan, onFailure: onFailure)
    }
    func updateUIViewController(_ controller: ScannerHost, context: Context) { controller.setActive(isActive) }
    static func dismantleUIViewController(_ controller: ScannerHost, coordinator: ()) { controller.setActive(false) }
}

private final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
    private let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
    private let onScan: (String) -> Void
    private let onFailure: (String) -> Void
    private var active = false
    private var delivered = false

    init(onScan: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onScan = onScan; self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
        scanner.delegate = self
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(onScan:onFailure:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor), scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        scanner.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
    override func viewWillDisappear(_ animated: Bool) { scanner.stopScanning(); super.viewWillDisappear(animated) }
    func setActive(_ value: Bool) {
        active = value
        if !value { scanner.stopScanning() }
        else { Task { @MainActor [weak self] in self?.refresh() } }
    }
    private func refresh() {
        guard active, !delivered, isViewLoaded, view.window != nil, !scanner.isScanning else { return }
        do { try scanner.startScanning() }
        catch { onFailure("Die Kamera konnte nicht gestartet werden. Schließe andere Kamera-Apps und versuche es erneut.") }
    }
    private func accept(_ items: [RecognizedItem]) {
        guard active, !delivered else { return }
        for item in items {
            if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                delivered = true; scanner.stopScanning(); onScan(text); return
            }
        }
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { accept(addedItems) }
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { accept([item]) }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        scanner.stopScanning(); onFailure("Die Kamera ist momentan nicht verfügbar. Öffne den Scanner erneut oder füge die Kopplungsdaten manuell ein.")
    }
}
