import SwiftUI
import WebKit

struct YouTubePreview: View {
    let entries: [YouTubeEntry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var player: AudioPlayer
    @State private var index = 0
    @State private var webError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let entry = entries.indices.contains(index) ? entries[index] : nil {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("YouTube", systemImage: "play.rectangle.fill").font(.headline)
                        if entry.available && entry.embeddable {
                            YouTubeWebPlayer(entry: entry, onError: { webError = $0 })
                                .frame(minHeight: 230).aspectRatio(16 / 9, contentMode: .fit)
                                .id(entry.id)
                        }
                        Text(entry.title).font(.title3.bold())
                        Text(entry.channel).foregroundStyle(.secondary)
                        if let webError { Text(webError).font(.footnote).foregroundStyle(.secondary) }
                        Link("Auf YouTube öffnen", destination: entry.publicURL)
                        if entries.count > 1 {
                            HStack {
                                Button("Vorheriges", systemImage: "backward.end") { index -= 1; webError = nil }.disabled(index == 0)
                                Spacer()
                                Text("\(index + 1) / \(entries.count)").font(.caption).monospacedDigit()
                                Spacer()
                                Button("Nächstes", systemImage: "forward.end") { index += 1; webError = nil }.disabled(index + 1 == entries.count)
                            }
                        }
                    }.padding()
                }
            }
            .navigationTitle("Vorschau").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear { if player.isPlaying { player.toggle() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background { dismiss() } }
        }
    }
}

private struct YouTubeWebPlayer: UIViewRepresentable {
    let entry: YouTubeEntry
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        var parts = URLComponents(string: "https://www.youtube.com/embed/" + (entry.kind == .video ? entry.resourceID : "videoseries"))!
        let identity = "https://" + (Bundle.main.bundleIdentifier ?? "OfflineMusic").lowercased()
        parts.queryItems = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "autoplay", value: "0"), URLQueryItem(name: "origin", value: identity)]
        if entry.kind == .playlist { parts.queryItems?.append(URLQueryItem(name: "list", value: entry.resourceID)) }
        var request = URLRequest(url: parts.url!)
        // Required official embed identity for WKWebView, including private apps.
        request.setValue(identity, forHTTPHeaderField: "Referer")
        view.load(request)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void) { self.onError = onError }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError("Die Vorschau konnte nicht geladen werden. Du kannst das Video direkt auf YouTube öffnen.")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
            guard url.scheme == "https" else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame == true, let host = url.host,
               !(host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")) {
                if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
