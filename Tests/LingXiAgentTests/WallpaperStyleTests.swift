#if canImport(SwiftUI)
import AppKit
import SwiftUI
import ImageIO
import Testing
@testable import LingXiFrontendKit

@Suite("Static wallpaper UI", .serialized)
@MainActor
struct WallpaperStyleTests {
    @Test("Native input stays white on dark surfaces and readable in light auxiliary windows")
    func nativeInputTextContrast() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: MacNativeTextView(text: .constant("Readable input"))
                .environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
            host.layoutSubtreeIfNeeded()
            let editor = try #require(descendants(host).compactMap { $0 as? KeyInterceptingTextView }.first)
            #expect(editor.textColor == (scheme == .dark ? NSColor.white : NSColor.textColor))
            #expect(editor.placeholderColor == (scheme == .dark ? NSColor.white.withAlphaComponent(0.84) : NSColor.secondaryLabelColor))
        }
    }

    @Test("The sole workbench hosts no native blur views and keeps the window opaque")
    func hostedWorkbenchHasNoLiveBlur() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1460, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = WarmWorkbench(runtime: RuntimeFrontend.preview(), settings: SettingsStore(), navigation: WarmNavigation())
            .modifier(WallpaperWindow())
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        #expect(!views.contains { $0 is NSVisualEffectView })
        if #available(macOS 26.0, *) {
            #expect(!views.contains { $0 is NSGlassEffectView })
        }
        #expect(window.isOpaque)
    }

    @Test("Messages and composer have equal rendered widths and leading edges at narrow and wide sizes")
    func readingColumnsAlign() throws {
        _ = NSApplication.shared
        for width in [760.0, 1460.0] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let root = ScrollView(.vertical) {
                ReadingColumn { ColumnMarker(name: "messages").frame(height: 500) }
            }
            .scrollIndicators(.never, axes: .vertical)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReadingColumn(maxWidth: LingXiMetrics.Column.composer) {
                    ColumnMarker(name: "composer").frame(height: 20)
                }
            }
            let host = NSHostingView(rootView: root)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let views = descendants(host)
            let messages = try #require(views.first { $0.identifier?.rawValue == "messages" })
            let composer = try #require(views.first { $0.identifier?.rawValue == "composer" })
            let messageFrame = messages.convert(messages.bounds, to: host)
            let composerFrame = composer.convert(composer.bounds, to: host)
            #expect(abs(messageFrame.width - min(width - 2 * LingXiMetrics.Column.gutter, LingXiMetrics.Column.composer)) < 0.5)
            #expect(messageFrame.width == composerFrame.width)
            #expect(messageFrame.minX == composerFrame.minX)
        }
    }

    @Test("The main window fills the usable display without entering fullscreen or locking its size")
    func mainWindowUsesVisibleFrame() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Color.clear.background(WorkbenchWindowPlacement()))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let screen = try #require(window.screen ?? NSScreen.main)
        #expect(window.frame == screen.visibleFrame)
        #expect(!window.styleMask.contains(.fullScreen))

        let resized = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 900, height: 600)
        window.setFrame(resized, display: false)
        host.layoutSubtreeIfNeeded()
        #expect(window.frame == resized)
    }

    @Test("Wallpaper decoding bounds texture size and rejects invalid images")
    func thumbnailIsBounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(CGContext(data: nil, width: 4096, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(bitmap.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(WallpaperBackdrop.thumbnail(at: url))
        #expect(thumbnail.width == 2048)
        try Data("invalid image".utf8).write(to: url)
        #expect(WallpaperBackdrop.thumbnail(at: url) == nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct ColumnMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
