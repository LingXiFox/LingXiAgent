#if os(macOS)
import SwiftUI
import AppKit

/// AppKit 原生 NSTextView 桥接
/// 解决纯 SwiftUI TextEditor 针对中文输入法、智能引号干扰、快捷键拦截和代码展示的体验局限
public struct MacNativeTextView: NSViewRepresentable {
    @Binding public var text: String
    public var isEditable: Bool
    public var isMonospace: Bool
    public var placeholder: String?
    /// When true, plain Return inserts a newline and only ⌘Return submits.
    public var submitRequiresCommand: Bool
    public var onSubmit: (() -> Void)?

    public init(
        text: Binding<String>,
        isEditable: Bool = true,
        isMonospace: Bool = false,
        placeholder: String? = nil,
        submitRequiresCommand: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.isMonospace = isMonospace
        self.placeholder = placeholder
        self.submitRequiresCommand = submitRequiresCommand
        self.onSubmit = onSubmit
    }

    /// Line height of the body font, used by callers to size the view per line.
    public static var bodyLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: bodyFont) + LXType.Leading.editor
    }

    /// Kept in step with `LXType.editor` (prompt body 15/regular); AppKit cannot
    /// read SwiftUI's `Font`.
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: 15, weight: .regular) }
    static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }

    static var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = LXType.Leading.editor
        return style
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textView = KeyInterceptingTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.drawsBackground = false

        // 关闭智能引号和智能破折号干扰
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true

        if isMonospace {
            textView.font = Self.monoFont
        } else {
            textView.font = Self.bodyFont
        }
        textView.defaultParagraphStyle = Self.bodyParagraphStyle
        textView.typingAttributes = [
            .font: textView.font ?? Self.bodyFont,
            .paragraphStyle: Self.bodyParagraphStyle,
            .foregroundColor: NSColor.textColor
        ]
        // The composer layer owns the inset: no extra AppKit side padding, so the
        // first line lines up with the goal chip and the action bar below it.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero

        textView.placeholderString = placeholder
        textView.onSubmit = onSubmit
        textView.submitRequiresCommand = submitRequiresCommand
        context.coordinator.textView = textView
        scrollView.documentView = textView

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? KeyInterceptingTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.submitRequiresCommand = submitRequiresCommand
        textView.placeholderString = placeholder
        textView.needsDisplay = true
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacNativeTextView
        weak var textView: KeyInterceptingTextView?

        init(_ parent: MacNativeTextView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

public final class KeyInterceptingTextView: NSTextView {
    public var onSubmit: (() -> Void)?
    public var submitRequiresCommand = false
    public var placeholderString: String? {
        didSet { if placeholderString != oldValue { needsDisplay = true } }
    }

    /// Default: Return sends, ⇧Return inserts a newline, ⌘Return sends.
    /// With `submitRequiresCommand`: only ⌘Return sends, Return inserts a newline.
    /// Without an onSubmit handler every key falls through to the default behaviour.
    public override func keyDown(with event: NSEvent) {
        // Return while an IME is composing commits the candidate, never submits.
        if onSubmit != nil, isEditable, event.keyCode == 36, !hasMarkedText() {
            let command = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if command || (!submitRequiresCommand && !shift) {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// The placeholder is drawn manually, so redraw it when light/dark flips.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placeholder = placeholderString, string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? MacNativeTextView.bodyFont,
            // Placeholder copy is readable text, so it sits on text-secondary
            // (`placeholderTextColor` reads below contrast on the glass layer).
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]
        placeholder.draw(in: placeholderBounds, withAttributes: attributes)
    }

    private var placeholderBounds: NSRect {
        let inset = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        let resolvedFont = font ?? MacNativeTextView.bodyFont
        let height = layoutManager?.defaultLineHeight(for: resolvedFont) ?? resolvedFont.pointSize
        return NSRect(x: origin.x + inset,
                      y: origin.y,
                      width: max(0, visibleRect.width - inset * 2),
                      height: max(0, height))
    }
}
#endif
