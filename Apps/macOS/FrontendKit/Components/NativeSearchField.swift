#if os(macOS)
import SwiftUI
import AppKit

/// A borderless search cell has to be told where to draw: without the rounded
/// bezel's metrics the magnifier lands on top of the placeholder. These are the
/// insets the bezel used to supply, so the field can sit flat on a warm panel
/// instead of carrying a white AppKit box with it.
private final class LXSearchFieldCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        let side: CGFloat = 14
        return NSRect(x: rect.minX + 6,
                      y: (rect.midY - side / 2).rounded(),
                      width: side, height: side)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = ceil(font.ascender - font.descender)
        let x = searchButtonRect(forBounds: rect).maxX + 4
        return NSRect(x: x,
                      y: (rect.midY - lineHeight / 2).rounded(),
                      width: max(0, rect.maxX - x - 6),
                      height: lineHeight)
    }

    // While typing, the text lives in the field editor, which AppKit lays out over the whole
    // cell unless told otherwise — the caret and the first characters landed on the magnifier.
    private func editingRect(_ rect: NSRect) -> NSRect {
        let text = searchTextRect(forBounds: rect)
        let cancelWidth: CGFloat = 22
        return NSRect(x: text.minX, y: text.minY, width: max(0, rect.maxX - text.minX - cancelWidth), height: text.height)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editingRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: editingRect(rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

/// AppKit search field for places without a navigation container to host
/// `.searchable` (the floating navigator). Keeps native cancel button,
/// focus ring, and Escape-to-clear behaviour.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        let cell = LXSearchFieldCell(textCell: "")
        // A cell made with `init(textCell:)` is neither editable nor selectable. The default
        // search cell is; swapping in this one without these two lines left every search field
        // in the app (navigator, settings, provider picker) unable to take a single keystroke.
        cell.isEditable = true
        cell.isSelectable = true
        cell.controlSize = .regular
        cell.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.focusRingType = .none
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.isScrollable = true
        cell.lineBreakMode = .byTruncatingTail
        cell.placeholderString = prompt
        cell.searchButtonCell?.isBordered = false
        cell.searchButtonCell?.isBezeled = false
        field.cell = cell
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

extension NativeSearchField {
    /// Sidebar search chrome shared by the navigator and the settings list: a 28pt
    /// row on the neutral `fill-control`, so the field stops reading as a white
    /// inset box on the warm panel.
    @ViewBuilder func navigatorChrome() -> some View {
        self
            .frame(height: 28)
            .background(LXColor.fillControl,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous))
    }
}
/// Undoes the focus AppKit hands the first text field of a window or sheet when it opens.
/// AppKit gives a newly shown window or sheet a focused field on its own, so it would open with
/// a caret blinking in a field nobody clicked.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                let responder = window.firstResponder
                if responder is NSText || responder is NSTextField {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}

extension View {
    /// Opens without a focused text field: the user clicks the one they want.
    func lxNoInitialFocus() -> some View {
        background(NoInitialFocus().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
#endif
