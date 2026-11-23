import SwiftUI
import MediaPlayer
import ImageIO

enum AppTheme {
    static let background = Color(red: 12/255, green: 16/255, blue: 15/255)
    static let header = Color(red: 13/255, green: 18/255, blue: 16/255)
    static let surface = Color(red: 24/255, green: 32/255, blue: 29/255)
    static let separator = Color(red: 46/255, green: 59/255, blue: 53/255)
    static let accent = Color(red: 121/255, green: 255/255, blue: 168/255)
    static let accentSurface = Color(red: 36/255, green: 60/255, blue: 48/255)
    static let text = Color(red: 245/255, green: 250/255, blue: 247/255)
    static let secondaryText = Color(red: 174/255, green: 190/255, blue: 182/255)
    static let onAccent = Color(red: 10/255, green: 25/255, blue: 17/255)
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
            .toolbarBackground(AppTheme.header, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
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

    func musicSectionHeading() -> some View {
        font(.title3.weight(.semibold))
            .foregroundStyle(AppTheme.text)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MusicIconTile: View {
    let symbol: String
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(width: size, height: size)
            .background(AppTheme.accentSurface, in: RoundedRectangle(cornerRadius: size * 0.29))
            .accessibilityHidden(true)
    }
}

struct MusicFilterPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            menu
        } else {
            ViewThatFits(in: .horizontal) {
                segments
                menu
            }
        }
    }

    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let (value, label) = options[index]
                let isSelected = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? AppTheme.onAccent : AppTheme.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isSelected ? AppTheme.accent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(AppTheme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(AppTheme.separator, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var menu: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].1).tag(options[index].0)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Decode only the pixels needed for display, off the main thread.
actor ArtworkThumbnails {
    static let shared = ArtworkThumbnails()

    private final class Key: NSObject {
        let data: NSData
        let pixels: Int

        init(data: Data, pixels: Int) {
            self.data = data as NSData
            self.pixels = pixels
        }

        override var hash: Int { data.hash &+ pixels }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return pixels == other.pixels && data.isEqual(other.data)
        }
    }

    private let cache: NSCache<Key, UIImage> = {
        let cache = NSCache<Key, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()

    func image(_ data: Data, pixels: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = Key(data: data, pixels: pixels)
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height + data.count)
        return image
    }
}

/// The system volume control preserves route handling and device-volume semantics.
struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> CenteredVolumeView { CenteredVolumeView() }
    func updateUIView(_ uiView: CenteredVolumeView, context: Context) {}

    final class CenteredVolumeView: UIView {
        private let control = MPVolumeView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            control.tintColor = UIColor(AppTheme.accent)
            addSubview(control)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { return nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let controlBounds = CGRect(origin: .zero, size: bounds.size)
            control.bounds = controlBounds
            control.layoutIfNeeded()
            // MPVolumeView can draw its track above its own vertical center.
            let track = control.volumeSliderRect(forBounds: controlBounds)
            let offset = track.isEmpty ? 0 : controlBounds.midY - track.midY
            control.center = CGPoint(x: bounds.midX, y: bounds.midY + offset)
        }
    }
}

struct LegacyMiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: AudioPlayer
    let onOpen: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 8) {
                if player.current != nil {
                    MiniPlayer(onOpen: onOpen)
                        .musicGlass(cornerRadius: 22)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
    }
}
