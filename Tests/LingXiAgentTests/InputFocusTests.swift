#if canImport(SwiftUI)
import AppKit
import SwiftUI
import Testing
@testable import LingXiFrontendKit

@Suite("Input focus rule", .serialized)
@MainActor
struct InputFocusTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func host<V: View>(_ view: V) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: 400, height: 120))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    @Test("The search field can actually be typed into")
    func searchFieldIsEditable() throws {
        let (_, root) = host(NativeSearchField(text: .constant(""), prompt: "搜索"))
        let field = try #require(descendants(root).compactMap { $0 as? NSSearchField }.first)
        let cell = try #require(field.cell as? NSSearchFieldCell)
        #expect(cell.isEditable && cell.isSelectable, "替换后的搜索单元格必须可编辑，否则搜索框无法输入")
    }

    @Test("The composer does not take focus by itself when it appears")
    func composerDoesNotClaimFocus() throws {
        let (window, root) = host(MacNativeTextView(text: .constant("")))
        _ = try #require(descendants(root).compactMap { $0 as? KeyInterceptingTextView }.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!(window.firstResponder is KeyInterceptingTextView), "输入框不应在出现时自动获得焦点")
    }

    @Test("Focusing search keeps the editor clear of the magnifier and aligned with display text")
    func searchEditorAlignment() throws {
        let (window, root) = host(NativeSearchField(text: .constant("hello"), prompt: "Search").navigatorChrome())
        defer { window.close() }
        let field = try #require(descendants(root).compactMap { $0 as? NSSearchField }.first)
        let cell = try #require(field.cell as? NSSearchFieldCell)
        field.selectText(nil)
        let editor = try #require(field.currentEditor())
        let editorRect = field.convert(editor.bounds, from: editor)
        let textRect = cell.searchTextRect(forBounds: field.bounds)
        let iconRect = cell.searchButtonRect(forBounds: field.bounds)
        #expect(editorRect.minX >= iconRect.maxX)
        #expect(abs(editorRect.minX - textRect.minX) <= 3, "Editor \(editorRect), text \(textRect)")
        #expect(editorRect.maxX <= field.bounds.maxX)
    }
}
#endif
