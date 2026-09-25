#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
#if os(macOS)
import AppKit
#endif

/// Main stage — "what the agent did and is doing": the Agent Timeline fills the
/// column; the composer dock floats over its foot. Without a workspace the stage
/// shows the connection state instead of sample data.
public struct MainStageView: View {
    @ObservedObject public var runtime: RuntimeFrontend
    @ObservedObject private var conversation: ConversationPresentationModel

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.conversation = runtime.conversationModel
    }

    public var body: some View {
        Group {
            switch runtime.link {
            case .connected:
                ActionFlowTimelineView(
                    items: conversation.items,
                    isGenerating: conversation.isGenerating,
                    hasAnyItem: !conversation.items.isEmpty,
                    tailNotice: runtime.providerNotice,
                    onPromptSelect: { text in
                        runtime.composerModel.text = text
                    }
                )
                .lxFloatingBar(edge: .bottom) {
                    ComposerDock(runtime: runtime)
                }
            case .disconnected, .failed, .connecting:
                WorkspaceGate(runtime: runtime)
            }
        }
        .environment(\.runtimeFrontend, runtime)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $runtime.commandOutput) { output in
            CommandOutputSheet(output: output)
        }
    }
}

// MARK: - Reading column

/// Centres content on a readable measure with a small fixed gutter.
struct ReadingColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: LingXiMetrics.Column.measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LingXiMetrics.Column.gutter)
    }
}

// MARK: - Workspace gate

/// Shown until a Core is attached: open a workspace, reopen a recent one, or
/// read why the last attempt failed. Never a fake conversation.
struct WorkspaceGate: View {
    @ObservedObject var runtime: RuntimeFrontend

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.xl) {
            VStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(title).font(.lxTitle)
                Text(detail)
                    .font(.lxCallout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }

            if case .connecting = runtime.link {
                ProgressView().controlSize(.regular)
            } else {
                #if os(macOS)
                Button("打开工作区…", action: chooseWorkspace)
                    .lxPrimaryButtonStyle()
                    .controlSize(.large)
                #endif

                let recents = RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                        Text("最近").font(.lxMeta.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(recents, id: \.path) { url in
                            Button {
                                Task { await runtime.openWorkspace(url) }
                            } label: {
                                HStack {
                                    Label(url.lastPathComponent, systemImage: "folder")
                                    Spacer(minLength: LingXiMetrics.Space.lg)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.lxMeta)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                .frame(width: 380)
                                .frame(minHeight: LingXiMetrics.Row.list)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(LingXiMetrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch runtime.link {
        case .connecting: return "正在启动 Core…"
        case .failed: return "无法连接 Core"
        default: return "打开一个工作区开始"
        }
    }

    private var detail: String {
        switch runtime.link {
        case .connecting(let path):
            let folder = URL(fileURLWithPath: path).lastPathComponent
            return "工作区: \(folder)"
        case .failed(let message): return message
        default: return "LingXi 会在所选目录启动 Core，会话、工具调用与变更都来自真实运行。"
        }
    }

    #if os(macOS)
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runtime.openWorkspace(url) }
        }
    }
    #endif
}

// MARK: - Action flow timeline

public struct ActionFlowTimelineView: View {
    public let items: [TimelineItemPresentation]
    public let isGenerating: Bool
    public var hasAnyItem: Bool = true
    public var tailNotice: NoticePresentation?

    /// Paused auto-follow once the user scrolls up; "jump to bottom" appears.
    @State private var showJumpToBottom = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var onPromptSelect: ((String) -> Void)? = nil

    public init(items: [TimelineItemPresentation], isGenerating: Bool, hasAnyItem: Bool = true,
                tailNotice: NoticePresentation? = nil, onPromptSelect: ((String) -> Void)? = nil) {
        self.items = items
        self.isGenerating = isGenerating
        self.hasAnyItem = hasAnyItem
        self.tailNotice = tailNotice
        self.onPromptSelect = onPromptSelect
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                let rows = items.foldedIntoRows()
                ScrollView {
                    if !hasAnyItem {
                        VStack {
                            Spacer()
                            CyberHeroWelcomeView(onPromptSelect: onPromptSelect)
                                .padding(.bottom, 72)
                        }
                        .frame(maxWidth: .infinity, minHeight: max(viewport.size.height - 130, 260), alignment: .bottom)
                    } else {
                        LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                            ForEach(rows) { row in
                                TimelineRowView(row: row)
                                    .id(row.id)
                                    .padding(.top, row.isTurnBoundary ? LingXiMetrics.Space.xl : 0)
                            }

                            if let tailNotice {
                                TimelineRowView(row: .notice(TimelineItemPresentation(id: "tail-notice",
                                                                                       kind: .notice(tailNotice))))
                            }

                            if isGenerating {
                                ReadingColumn {
                                    HStack(spacing: LingXiMetrics.Space.sm) {
                                        ProgressView().controlSize(.small)
                                        Text("执行中…")
                                            .font(.lxMeta)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(height: LingXiMetrics.Row.event)
                                }
                            }
                        }
                        .padding(.vertical, LingXiMetrics.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }
                }
                .coordinateSpace(name: "stageScroll")
                .background(
                    GeometryReader { content in
                        Color.clear.preference(
                            key: StageScrollOffsetKey.self,
                            value: content.frame(in: .named("stageScroll")).minY
                        )
                    }
                )
                .onPreferenceChange(StageScrollOffsetKey.self) { offset in
                    let scrolledUp = offset < -120
                    if showJumpToBottom != scrolledUp {
                        withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                            showJumpToBottom = scrolledUp
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showJumpToBottom, let last = rows.last {
                        Button {
                            withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        } label: {
                            Label("回到底部", systemImage: "arrow.down")
                                .font(.lxMeta)
                        }
                        .lxGlassButtonStyle()
                        .padding(.trailing, LingXiMetrics.Space.xl)
                        .padding(.bottom, LingXiMetrics.Space.xxl * 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .onChange(of: items.count) { _, _ in
                    guard !showJumpToBottom, let last = rows.last else { return }
                    withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: isGenerating) { _, generating in
                    guard generating, !showJumpToBottom, let last = rows.last else { return }
                    withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct StageScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Welcome View (IDE Workspace Style)

private struct CyberHeroWelcomeView: View {
    var onPromptSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.lg) {
            // Refined, professional brand mark
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(LingXiTheme.foxfireAmber)
                Text("LingXiAgent")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Text("次世代赛博智能体研发环境。写清任务与验收标准，输入 / 调用命令，@ 引用上下文。")
                .font(.lxCallout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            // Lightweight, restrained starter prompt options
            HStack(spacing: LingXiMetrics.Space.sm) {
                StarterPromptButton(
                    icon: "magnifyingglass",
                    title: "代码巡检",
                    prompt: "请对当前工作区的核心代码结构与依赖进行巡检，列出可以改进优化的点"
                ) { onPromptSelect?($0) }

                StarterPromptButton(
                    icon: "hammer",
                    title: "特性开发",
                    prompt: "我需要为你增加一个新功能，请先向我梳理实现方案"
                ) { onPromptSelect?($0) }

                StarterPromptButton(
                    icon: "bolt.horizontal",
                    title: "性能调优",
                    prompt: "分析当前系统的响应瓶颈与高频路径，给出优化建议"
                ) { onPromptSelect?($0) }
            }
            .padding(.top, LingXiMetrics.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LingXiMetrics.Space.xl)
    }
}

private struct StarterPromptButton: View {
    let icon: String
    let title: String
    let prompt: String
    let onSelect: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(prompt)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(LingXiTheme.electricCyan)
                Text(title)
                    .font(.lxCallout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, LingXiMetrics.Space.md)
            .padding(.vertical, LingXiMetrics.Space.sm)
            .background(
                Color.white.opacity(isHovered ? 0.08 : 0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Slash-command output (status cards, /diff, /context …) in a native sheet.
struct CommandOutputSheet: View {
    let output: CommandOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text(output.title).font(.lxTitle)
            ScrollView {
                Text(output.text)
                    .font(.lxMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LingXiMetrics.Space.md)
            }
            .lxInsetBlock()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(LingXiMetrics.Space.xl)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 360, idealHeight: 520)
    }
}

#endif
