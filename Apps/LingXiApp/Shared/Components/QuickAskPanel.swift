#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 侧提问快捷浮窗视图 (QuickAskPanel)
/// 绑定快捷键 ⌥Space，临时只读提问，不写回主会话历史
public struct QuickAskView: View {
    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var isLoading: Bool = false
    public var onSubmit: (String) async -> String
    public var onClose: () -> Void

    public init(
        onSubmit: @escaping (String) async -> String = { _ in "" },
        onClose: @escaping () -> Void = {}
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("快捷侧问", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.headline)
                    .foregroundColor(LingXiTheme.accentColor)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(LingXiTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            Text("侧边提问运行于独立只读上下文中，绝不污染当前任务的主会话历史。")
                .font(.caption2)
                .foregroundColor(LingXiTheme.secondaryText)

            HStack {
                TextField("快速向 Agent 提问… (Return 提交)", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submit()
                    }

                Button("提交") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(LingXiTheme.accentColor)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(.body)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LingXiTheme.surfaceBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .frame(width: 480)
        .background(LingXiTheme.windowBackground)
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
