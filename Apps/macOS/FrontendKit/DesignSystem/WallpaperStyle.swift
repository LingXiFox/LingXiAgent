import SwiftUI
import AppKit
import ImageIO

struct WallpaperWindow: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            // The whole workbench is white-on-photograph, so the hierarchy has to be lifted
            // rather than pushed down: 0.84/0.68 secondary text over a glass panel that is
            // already a blur of a mid-tone picture lands under 4.5:1, and 「文字过暗看不清」
            // was the acceptance complaint. 0.92 still separates from primary.
            .foregroundStyle(Color.white, Color.white.opacity(0.92), Color.white.opacity(0.78))
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

    /// Decoded once per process and shared by every window and sheet. Each backdrop used to
    /// decode it in its own `.task`, so a sheet's first frame was the bare gradient and the
    /// photograph popped in a moment later — the Settings flash from solid to see-through.
    @MainActor static let shared: NSImage? = load()

    @State private var image: NSImage? = WallpaperBackdrop.shared
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
            if image == nil { image = Self.shared }
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
            LXGlass(cornerRadius: cornerRadius,
                    wash: LXColor.glassWash,
                    solidFallback: fill,
                    translucent: !reduceTransparency)
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
            LXGlass(cornerRadius: cornerRadius,
                    wash: LXColor.glassLift,
                    solidFallback: LXColor.elevated,
                    translucent: !reduceTransparency)
        }
        .shapeStroke(shape, colour: LXColor.glassEdge)
        .topLitEdge(shape)
        .shadow(color: .black.opacity(LingXiMetrics.Shadow.floatOpacity),
                radius: LingXiMetrics.Shadow.floatRadius, y: LingXiMetrics.Shadow.floatY)
        // The tight contact shadow is what separates a floating layer from a panel that
        // merely has a soft glow; without it the composer floats at the same height as the
        // stage behind it.
        .shadow(color: .black.opacity(0.30), radius: 1, y: 1)
    }
}

/// The glass ground shared by panels and floating surfaces.
///
/// Static on purpose: the workbench hosts no live blur (WallpaperStyleTests, and the idle-GPU
/// budget it protects). Glass is built from what a blur would have produced over this dark,
/// scrimmed backdrop — a lift of white over it, brighter at the top where light falls — so the
/// surface reads as a pane in front of the photograph instead of a hole cut into it.
/// `translucent: false` is the Reduce Transparency path — one opaque token colour.
struct LXGlass: View {
    let cornerRadius: CGFloat
    let wash: Color
    let solidFallback: Color
    let translucent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if translucent {
            shape.fill(wash)
                .overlay(shape.fill(LinearGradient(colors: [LXColor.glassSheen, .clear],
                                                   startPoint: .top, endPoint: .bottom)))
        } else {
            shape.fill(solidFallback)
        }
    }
}

extension View {
    /// 1px stroke that follows a rounded shape, drawn on the inside so it never changes
    /// the size of what it frames.
    func shapeStroke(_ shape: some InsettableShape, colour: Color) -> some View {
        overlay(shape.strokeBorder(colour, lineWidth: 1).allowsHitTesting(false))
    }

    /// The lit rim along the top edge of a glass surface. A uniform ring reads as a
    /// sticker; light falling from above reads as a bevel, and this is the half-stop that
    /// makes the panels look three-dimensional instead of outlined.
    func topLitEdge(_ shape: some InsettableShape) -> some View {
        overlay {
            shape.strokeBorder(
                LinearGradient(colors: [LXColor.glassTopLight, .clear],
                               startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        }
    }
}
