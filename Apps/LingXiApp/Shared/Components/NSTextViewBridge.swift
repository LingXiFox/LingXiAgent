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
    public var onSubmit: (() -> Void)?

    public init(
        text: Binding<String>,
        isEditable: Bool = true,
        isMonospace: Bool = false,
        placeholder: String? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.isMonospace = isMonospace
        self.placeholder = placeholder
        self.onSubmit = onSubmit
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
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        } else {
            textView.font = NSFont.systemFont(ofSize: 13)
        }

        textView.onSubmit = onSubmit
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
        }
    }
}

public final class KeyInterceptingTextView: NSTextView {
    public var onSubmit: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        // ⌘ + Return 发送
        if event.modifierFlags.contains(.command) && event.keyCode == 36 {
            if let onSubmit = onSubmit {
                onSubmit()
                return
            }
        }
        super.keyDown(with: event)
    }
}
#endif
