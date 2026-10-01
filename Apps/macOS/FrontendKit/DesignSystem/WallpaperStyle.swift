import SwiftUI
import AppKit
import ImageIO

struct WallpaperWindow: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.white, Color.white.opacity(0.84), Color.white.opacity(0.68))
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background {
                ZStack {
                    WallpaperBackdrop()
                    if !reduceTransparency { WallpaperScrim() }
                }
                .ignoresSafeArea()
            }
    }
}

/// One window-wide gradient, including the toolbar and gaps between panels.
struct WallpaperScrim: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.40), location: 0),
            .init(color: .black.opacity(0.65), location: 0.45),
            .init(color: .black.opacity(0.90), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The fixed product background.
///
/// It used to be a user preference: `lx.appearance.wallpaperPath` held an absolute path chosen
/// through an NSOpenPanel, and the GUI loaded whatever file that pointed at. Every colour,
/// opacity, material, scrim, shadow and separator in this app was tuned against one specific
/// backdrop, so letting the backdrop be anything meant text legibility was a matter of luck. It
/// is now a product visual asset shipped inside the bundle — no picker, no runtime substitution,
/// no theme swapping it.
///
/// The legacy preference is deliberately not read. Old installs still carrying
/// `lx.appearance.wallpaperPath` cannot change the GUI, and nothing writes the key any more (§5).
///
/// Reduce Transparency still hides the photograph and drops the scrim, exactly as it did before
/// the asset was fixed. The background freeze §11 reads as "adjust the overlay, never swap the
/// backdrop", which argues for keeping the photo and darkening the scrim instead; that variant was
/// rendered and compared, and the Owner chose the original behaviour — the accessibility setting
/// means "take the texture off", and the plain designed gradient is the more legible result. Do not
/// "correct" this back to a heavier scrim: the decision is recorded in
/// Docs/AC/GUI-Core-Closure-Report-1.2.0.md §D2 and asserted by FixedBackgroundAssetTests.
struct WallpaperBackdrop: View {
    /// Bundle resource name, without extension. `Package.swift` copies the whole
    /// `FrontendKit/Resources` directory, so the app never touches a workspace-relative path.
    static let resourceName = "Background"
    static let resourceExtension = "jpg"

    @State private var image: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Retained as the stable fallback and as the base the photo sits on: if the asset
                // cannot be decoded, this is what ships — never a random image, never a download,
                // never the desktop wallpaper (§12).
                LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.22),
                                        Color(red: 0.08, green: 0.17, blue: 0.18),
                                        Color(red: 0.10, green: 0.11, blue: 0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image, !reduceTransparency {
                    // Aspect fill, unchanged crop and alignment: the image keeps its ratio, the
                    // window clips what overflows, and resizing reveals more or less of the same
                    // picture rather than choosing another one.
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            if image == nil { image = Self.load() }
        }
    }

    /// Decodes the bundled asset off the main actor. A 3880×2320 JPEG decoded inline would be
    /// paid for on every window the app opens, so it is thumbnailed to the same ceiling the
    /// picker used, then cached.
    static func load() -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension,
                                          subdirectory: "Resources") else {
            #if DEBUG
            fatalError("LingXiFrontendKit/Resources/\(resourceName).\(resourceExtension) 不存在：固定背景是产品视觉资产，缺失必须报错而不是静默换图")
            #else
            return nil
            #endif
        }
        guard let thumb = thumbnail(at: url) else { return nil }
        return NSImage(cgImage: thumb, size: .zero)
    }

    nonisolated static func thumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

struct LXPanelBackground: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            Group {
                if !reduceTransparency {
                    Color.black.opacity(0.06)
                } else {
                    fill
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct LXFloatingChrome: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            LXColor.elevated.opacity(reduceTransparency ? 1 : 0.62)
                .clipShape(shape)
        }
        .lxRing(cornerRadius: cornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.10), radius: 12, y: 8)
    }
}
