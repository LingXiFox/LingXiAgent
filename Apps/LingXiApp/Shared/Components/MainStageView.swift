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
                VStack(spacing: 0) {
                    StageTopBar(runtime: runtime)
                    ActionFlowTimelineView(items: conversation.items,
                                           isGenerating: conversation.isGenerating,
                                           hasAnyItem: !conversation.items.isEmpty,
                                           tailNotice: runtime.providerNotice,
                                           onPromptSelect: { text in
                                               runtime.composerModel.text = text
                                           })
                        .lxFloatingBar(edge: .bottom) {
                            ComposerDock(runtime: runtime)
                        }
                }
            case .disconnected, .failed, .connecting:
                WorkspaceGate(runtime: runtime)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $runtime.commandOutput) { output in
            CommandOutputSheet(output: output)
        }
    }
}

// MARK: - Stage Top Bar

private struct StageTopBar: View {
    @ObservedObject var runtime: RuntimeFrontend

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            // Workspace & Status Pulse
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LingXiTheme.auroraMint)
                        .frame(width: 7, height: 7)
                    Circle()
                        .stroke(LingXiTheme.auroraMint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                }
                .lxNeonGlow(color: LingXiTheme.auroraMint, radius: 4, opacity: 0.8)

                Text(workspaceTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

            }

            Spacer(minLength: 0)

            // Current Model & Mode Pill
            HStack(spacing: 6) {
                let model = runtime.inspectorModel.live?.modelID ?? ""
                if !model.isEmpty && model != "—" {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                            .foregroundStyle(LingXiTheme.electricCyan)
                        Text(model)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.05), in: Capsule())
                    .foregroundStyle(.secondary)
                }

                // Quick Clear Session
                Button {
                    runtime.newSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help("重置当前会话")
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .frame(height: 38)
        .background(
            Color.black.opacity(0.28)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 1)
                }
        )
    }

    private var workspaceTitle: String {
        if let url = runtime.workspaceURL {
            return url.lastPathComponent
        }
        return runtime.sidebarModel.workspace.name
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
                        CyberHeroWelcomeView(onPromptSelect: onPromptSelect)
                            .frame(maxWidth: .infinity, minHeight: max(viewport.size.height - 180, 360), alignment: .center)
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
                            key: BottomOffsetKey.self,
                            value: content.frame(in: .named("stageScroll")).maxY - viewport.size.height
                        )
                    }
                )
                .onPreferenceChange(BottomOffsetKey.self) { overshoot in
                    showJumpToBottom = overshoot > 120
                }
                .onChange(of: rows.last?.id) {
                    guard !showJumpToBottom, let lastID = rows.last?.id else { return }
                    withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showJumpToBottom {
                        Button {
                            guard let lastID = rows.last?.id else { return }
                            withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                            showJumpToBottom = false
                        } label: {
                            Label("回到底部", systemImage: "arrow.down").labelStyle(.iconOnly)
                        }
                        .lxGlassButtonStyle()
                        .buttonBorderShape(.circle)
                        .help("回到底部")
                        .padding(.bottom, LingXiMetrics.Space.md)
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

/// Distance from the last row to the viewport bottom, used to detect "pinned to bottom".
private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Rich Cyber Hero Welcome View that anchors the visual center of the main stage
struct CyberHeroWelcomeView: View {
    var onPromptSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.xl) {
            // Foxfire Cyber Emblem
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                LingXiTheme.foxfireAmber.opacity(0.32),
                                LingXiTheme.astralViolet.opacity(0.12),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 75
                        )
                    )
                    .frame(width: 150, height: 150)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [LingXiTheme.foxfireAmber.opacity(0.85), LingXiTheme.electricCyan.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 84, height: 84)

                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LingXiTheme.foxfireAmber, LingXiTheme.electricCyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, LingXiMetrics.Space.xl)

            VStack(spacing: LingXiMetrics.Space.xs) {
                Text("LingXiAgent")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, LingXiTheme.electricCyan.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("次世代赛博智能体研发环境。写清任务与验收标准，输入 / 调用命令，@ 引用上下文。")
                    .font(.lxCallout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Quick starter prompts grid
            HStack(spacing: LingXiMetrics.Space.md) {
                StarterPromptCard(
                    icon: "magnifyingglass",
                    title: "代码巡检",
                    subtitle: "审查项目架构与潜在风险",
                    prompt: "请对当前工作区的核心代码结构与依赖进行巡检，列出可以改进优化的点"
                ) { onPromptSelect?($0) }

                StarterPromptCard(
                    icon: "hammer",
                    title: "特性开发",
                    subtitle: "规划并落地新功能需求",
                    prompt: "我需要为你增加一个新功能，请先向我梳理实现方案"
                ) { onPromptSelect?($0) }

                StarterPromptCard(
                    icon: "bolt.horizontal",
                    title: "性能调优",
                    subtitle: "分析执行链路与降低开销",
                    prompt: "分析当前系统的响应瓶颈与高频路径，给出优化建议"
                ) { onPromptSelect?($0) }
            }
            .frame(maxWidth: 680)
            .padding(.top, LingXiMetrics.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LingXiMetrics.Space.xl)
    }
}

struct StarterPromptCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let prompt: String
    let onSelect: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(prompt)
        } label: {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LingXiTheme.electricCyan)
                    .padding(.bottom, 2)
                Text(title)
                    .font(.lxCallout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.lxMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LingXiMetrics.Space.md)
            .lxGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: isHovered ? LingXiTheme.obsidianSurface.opacity(0.85) : LingXiTheme.obsidianSurface.opacity(0.4)
            )
            .lxCrystalBorder(
                cornerRadius: 12,
                glowColor: isHovered ? LingXiTheme.electricCyan : nil,
                glowRadius: isHovered ? 8 : 0
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
