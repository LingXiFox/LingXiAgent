#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 侧提问快捷浮窗视图 (QuickAskPanel)
/// 绑定快捷键 ⌥Space，临时只读提问，不写回主会话历史
///
/// 视觉契约（§4 / §6）：这是一层临时浮窗表面 —— 无色 Liquid Glass + 1px
/// separator 环 + shadow-float，圆角 `surface` 20、内缩 16、子项间隙 12。
/// 玻璃只落在这一层：回答区是 fill-quinary 内嵌块，无玻璃、无描边、无阴影，
/// 整块表面上唯一的 accent 填充是「提交」。
public struct QuickAskView: View {
    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var isLoading: Bool = false
    public var onSubmit: (String) async -> String
    public var onClose: () -> Void

    private let controlShape = RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control,
                                                style: .continuous)

    public init(
        onSubmit: @escaping (String) async -> String = { _ in "" },
        onClose: @escaping () -> Void = {}
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    public var body: some View {
        surface
            .padding(LingXiMetrics.Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(LXColor.window)
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                // 浮层标题走 headline 15/20；靛/橙都只着色图标，文字恒为 text-primary。
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .foregroundStyle(LXColor.accentText)
                        .accessibilityHidden(true)
                    Text("快捷侧问")
                }
                .font(LXType.headline)
                .foregroundStyle(.primary)

                Spacer(minLength: LingXiMetrics.Space.sm)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(LXIconButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("关闭")
            }

            Text("侧边提问运行于独立只读上下文中，绝不污染当前任务的主会话历史。")
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: LingXiMetrics.Space.sm) {
                TextField("快速向 Agent 提问… (Return 提交)", text: $question)
                    .textFieldStyle(.plain)
                    .font(LXType.body)
                    .padding(.horizontal, LingXiMetrics.Space.md)
                    .padding(.vertical, LingXiMetrics.Space.xs)
                    .frame(minHeight: LXControl.regular)
                    .background(LXColor.content, in: controlShape)
                    .lxRing(cornerRadius: LingXiMetrics.Radius.control)
                    .onSubmit {
                        submit()
                    }

                Button("提交") {
                    submit()
                }
                .buttonStyle(.lxPrimary)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(LXType.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .lxInsetBlock()
            }
        }
        .padding(LingXiMetrics.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lxFloating()
    }

    private func submit() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        let q = question
        Task {
            let res = await onSubmit(q)
            await MainActor.run {
                self.answer = res
                self.isLoading = false
            }
        }
    }
}

#if os(macOS)
/// 快速浮窗控制器
public final class QuickAskPanelController: NSWindowController {
    public static let shared = QuickAskPanelController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.title = "快捷侧问"
        panel.center()
        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show(onSubmit: @escaping (String) async -> String) {
        let view = QuickAskView(onSubmit: onSubmit, onClose: { [weak self] in
            self?.close()
        })
        window?.contentView = NSHostingView(rootView: view)
        window?.center()
        showWindow(nil)
    }
}
#endif
#endif
