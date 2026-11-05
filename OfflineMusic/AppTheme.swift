import SwiftUI
import MediaPlayer
import ImageIO

enum AppTheme {
    // Neutral charcoal surfaces keep the accent green reserved for actions and active states.
    static let background = Color(red: 12/255, green: 14/255, blue: 16/255)
    static let header = Color(red: 7/255, green: 8/255, blue: 9/255)
    static let surface = Color(red: 30/255, green: 33/255, blue: 36/255)
    static let separator = Color(red: 58/255, green: 62/255, blue: 66/255)
    static let accent = Color(red: 69/255, green: 232/255, blue: 129/255)
    static let text = Color(red: 245/255, green: 255/255, blue: 246/255)
    static let secondaryText = Color(red: 164/255, green: 183/255, blue: 172/255)
    static let onAccent = background
    static let cornerRadius: CGFloat = 24
}

/// Legacy import placeholders are presented in the current language; stored tags stay intact.
enum MetadataText {
    static func artist(_ name: String) -> String {
        ["Unknown Artist", "Unbekannter Künstler"].contains(name) ? L10n.text("Unbekannter Künstler") : name
    }
    static func album(_ name: String) -> String {
        ["Unknown Album", "Unbekanntes Album"].contains(name) ? L10n.text("Unbekanntes Album") : name
    }
}

private struct MusicScreen: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .foregroundStyle(AppTheme.text)
            .tint(AppTheme.accent)
            .preferredColorScheme(.dark)
            .toolbarBackground(AppTheme.header, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .presentationBackground(AppTheme.background)
            .presentationDragIndicator(.visible)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

private struct MusicGlass: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
    }
}

extension View {
    func musicScreen() -> some View { modifier(MusicScreen()) }
    func musicGlass(cornerRadius: CGFloat = AppTheme.cornerRadius) -> some View {
        modifier(MusicGlass(cornerRadius: cornerRadius))
    }
}

/// Decode only the pixels needed for display, off the main thread.
enum ArtworkThumbnails {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()

    static func image(_ data: Data, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            // Include resolution in the key so a small row thumbnail never serves the player.
            var keyData = Data("\(pixels):".utf8)
            keyData.append(data)
            let key = keyData as NSData
            if let cached = cache.object(forKey: key) { return cached }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let image = UIImage(cgImage: thumbnail)
            cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height + data.count)
            return image
        }.value
    }
}

/// The system volume control preserves route handling and device-volume semantics.
struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor(AppTheme.accent)
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct LegacyMiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: AudioPlayer
    let onOpen: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        content
            // Keep the final row reachable above the floating player and tab bar.
            .contentMargins(.bottom, player.current == nil ? 16 : 96, for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 8) {
            if player.current != nil {
                MiniPlayer(onOpen: onOpen)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            }
    }
}

struct ModernMiniPlayerAccessory: ViewModifier {
    let onOpen: () -> Void
    func body(content: Content) -> some View { content }
}

struct MiniPlayerSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.musicGlass(cornerRadius: 22)
    }
}
