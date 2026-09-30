import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

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

/// A static texture inside an opaque window; no desktop sampling or live blur.
struct WallpaperBackdrop: View {
    static let pathKey = "lx.appearance.wallpaperPath"
    @AppStorage(pathKey) private var path = ""
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.22),
                                        Color(red: 0.08, green: 0.17, blue: 0.18),
                                        Color(red: 0.10, green: 0.11, blue: 0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image, !reduceTransparency {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: path) {
            guard !path.isEmpty else { image = nil; return }
            let url = URL(fileURLWithPath: path)
            let thumbnail = await Task.detached(priority: .utility) { Self.thumbnail(at: url) }.value
            guard !Task.isCancelled else { return }
            image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        }
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

    @MainActor
    static func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "设为背景"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CGImageSourceCreateWithURL(url as CFURL, nil) != nil else {
            let alert = NSAlert()
            alert.messageText = "无法读取这张图片"
            alert.informativeText = "请选择有效的 PNG、JPEG 或 HEIC 图片。"
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: pathKey)
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
