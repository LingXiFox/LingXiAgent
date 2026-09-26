#if canImport(SwiftUI)
import SwiftUI

/// The stage — "what the agent did and is doing". A rounded bg-content panel
/// inset 8pt from the window, with its own ambient light: the ONLY surface in
/// the product that carries the brand atmosphere.
public struct MainStageView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var conversation: ConversationPresentationModel

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.conversation = runtime.conversationModel
    }

    private var isEmptyWorkspace: Bool {
        runtime.link == .connected && conversation.items.isEmpty && !conversation.isGenerating
    }

    public var body: some View {
        ZStack {
            AtmosphereBackdrop(mode: isEmptyWorkspace ? .empty : .workspace)
            Group {
                if isEmptyWorkspace {
                    EmptyWorkspaceStage(runtime: runtime)
                } else if runtime.link == .connected {
                    TimelineStage(runtime: runtime)
                } else {
                    WorkspaceGate(runtime: runtime)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LingXiMetrics.Radius.panel, style: .continuous))
        .lxRing(cornerRadius: LingXiMetrics.Radius.panel)
        .padding([.horizontal, .bottom], LingXiMetrics.Space.sm)
        .environment(\.runtimeFrontend, runtime)
        .sheet(item: $runtime.commandOutput) { CommandOutputSheet(output: $0) }
    }
}

/// Centres content on measure-prose with the 28pt gutter. Timeline, empty
/// state and dock share it, so they share one leading edge.
struct ReadingColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: LingXiMetrics.Column.prose, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LingXiMetrics.Column.gutter)
    }
}

// MARK: - Timeline stage

private struct TimelineStage: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var conversation: ConversationPresentationModel
    @State private var isAwayFromBottom = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.conversation = runtime.conversationModel
    }

    var body: some View {
        let rows = conversation.items.foldedIntoRows()
        ScrollViewReader { proxy in
            ScrollView {
                ReadingColumn {
                    LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
                        ForEach(rows) { row in
                            TimelineRowView(row: row)
                                .id(row.id)
                                .padding(.top, row.isTurnBoundary && row.id != rows.first?.id ? LingXiMetrics.Space.md : 0)
                        }
                        if let notice = runtime.providerNotice {
                            TimelineRowView(row: .notice(TimelineItemPresentation(id: "tail-notice", kind: .notice(notice))))
                        }
                        if conversation.isGenerating && !rows.isStreamingTail {
                            HStack(spacing: LingXiMetrics.Space.sm) {
                                LXSpinner(tone: .running)
                                    .frame(width: LingXiMetrics.Size.glyphColumn)
                                Text("执行中…").font(LXType.callout).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: LingXiMetrics.Size.rowEvent)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.top, LingXiMetrics.Space.xxxl)
                    .padding(.bottom, LingXiMetrics.Space.md)
                }
            }
            .defaultScrollAnchor(.bottom)
            .modifier(BottomTracking(isAwayFromBottom: $isAwayFromBottom))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReadingColumn { ComposerDock(runtime: runtime) }
                    .padding(.bottom, LingXiMetrics.Space.lg)
            }
            .overlay(alignment: .bottom) {
                if isAwayFromBottom {
                    Button {
                        withAnimation(LXMotion.animation(reduceMotion: reduceMotion)) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    } label: {
                        Label("回到底部", systemImage: "arrow.down")
                    }
                    .buttonStyle(.lxSecondary)
                    .lxFloating(cornerRadius: LingXiMetrics.Radius.control)
                    .padding(.bottom, 200)
                    .transition(.opacity)
                }
            }
            .onChange(of: conversation.items.count) { _, _ in
                guard !isAwayFromBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    static let bottomID = "timeline-bottom"
}

private extension Array where Element == TimelineRow {
    /// The streaming assistant message is its own progress signal.
    var isStreamingTail: Bool {
        guard case .assistant(let item) = last, case .assistant(_, let streaming) = item.kind else { return false }
        return streaming
    }
}

/// Flags when the reader has scrolled away from the tail (macOS 15+).
private struct BottomTracking: ViewModifier {
    @Binding var isAwayFromBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > 240
            } action: { _, away in
                isAwayFromBottom = away
            }
        } else {
            content
        }
    }
}

// MARK: - Empty workspace

/// A centred composition, not a landing page: one question whose object is the
/// workspace itself → the composer → a row of starters. The lower half of the
/// window stays empty on purpose; an empty workspace is not a dashboard.
private struct EmptyWorkspaceStage: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var sidebar: SidebarPresentationModel

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.sidebar = runtime.sidebarModel
    }

    var body: some View {
        ReadingColumn {
            VStack(spacing: LingXiMetrics.Space.xl) {
                VStack(spacing: LingXiMetrics.Space.md) {
                    LXBrandMark(side: 34)
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text("想在")
                        workspaceMenu
                        Text("里做什么？")
                    }
                    .font(LXType.display)
                    .kerning(-0.28)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    Text(caption)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, LingXiMetrics.Space.md)

                ComposerDock(runtime: runtime)

                HStack(spacing: LingXiMetrics.Space.sm) {
                    ForEach(StarterPrompt.all) { starter in
                        GhostChip(starter: starter) { runtime.composerModel.text = starter.prompt }
                    }
                }
            }
        }
        .offset(y: -40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The workspace is the subject of the question, so switching it lives here
    /// rather than buried in the sidebar footer.
    private var workspaceMenu: some View {
        Menu {
            Button("打开其他工作区…") { WorkspacePicker.choose(runtime) }
            Divider()
            ForEach(RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) },
                    id: \.path) { url in
                Button(url.lastPathComponent) {
                    Task { await runtime.openWorkspace(url) }
                }
            }
        } label: {
            Text(sidebar.workspace.name)
                .foregroundStyle(LXColor.accentText)
                .padding(.horizontal, LingXiMetrics.Space.sm)
                .background(LXColor.accentSoft, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control,
                                                                     style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换工作区")
        .accessibilityLabel("工作区 \(sidebar.workspace.name)")
    }

    /// Workspace, branch and index state, all from the runtime.
    private var caption: String {
        var parts: [String] = []
        if let branch = sidebar.workspace.gitBranch, !branch.isEmpty { parts.append(branch) }
        switch sidebar.workspace.indexingState.lowercased() {
        case "ready": parts.append("索引就绪")
        case "indexing", "running", "in_progress", "pending": parts.append("索引进行中")
        case "failed", "error": parts.append("索引失败")
        case let other where !other.isEmpty: parts.append("索引 \(other)")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// Product starter prompts — a product choice, not design-sample data. Each one
/// names a capability the Core really has.
private struct StarterPrompt: Identifiable {
    let id: String
    let symbol: String
    let label: String
    let prompt: String

    static let all = [
        StarterPrompt(id: "architecture", symbol: "point.3.connected.trianglepath.dotted", label: "梳理架构",
                      prompt: "请梳理当前工作区的整体架构：模块划分、依赖关系和关键数据流。"),
        StarterPrompt(id: "plan", symbol: "list.bullet.rectangle", label: "制定计划",
                      prompt: "请阅读当前工作区，为下一个里程碑拟一份分步实施计划，并列出验收标准。"),
        StarterPrompt(id: "changes", symbol: "plus.forwardslash.minus", label: "审查改动",
                      prompt: "请审查当前工作区的未提交改动，指出风险、遗漏的测试和可以简化的地方。"),
        StarterPrompt(id: "debug", symbol: "ladybug", label: "定位问题",
                      prompt: "我来描述一个现象，请先复现、再定位根因，最后给出最小修复。"),
        StarterPrompt(id: "context", symbol: "square.stack.3d.up", label: "上下文体检",
                      prompt: "请汇报本会话的上下文占用：P-Core 工作集、E-Core 对象、Provider 缓存命中与 Cache Debt。"),
    ]
}

/// Transparent chip with a 1px separator ring; hover adds fill-quinary.
private struct GhostChip: View {
    let starter: StarterPrompt
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous)
        Button(action: action) {
            Label(starter.label, systemImage: starter.symbol)
                .font(LXType.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: LXControl.regular)
                .background(isHovered ? LXColor.fillQuinary : .clear, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .lxRing(cornerRadius: LingXiMetrics.Radius.control)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Workspace gate

/// Until a Core is attached: open a workspace, reopen a recent one, or read
/// why the last attempt failed. Never a fake conversation.
private struct WorkspaceGate: View {
    @ObservedObject var runtime: RuntimeFrontend

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.xl) {
            VStack(spacing: LingXiMetrics.Space.lg) {
                LXBrandMark(side: 48)
                Text(title).font(LXType.title)
                Text(detail)
                    .font(LXType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
            }

            if case .connecting = runtime.link {
                ProgressView().controlSize(.small)
            } else {
                Button("打开工作区…") { WorkspacePicker.choose(runtime) }
                    .buttonStyle(LXButtonStyle(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)

                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                        LXSectionHead("最近")
                        VStack(spacing: 0) {
                            ForEach(Array(recents.enumerated()), id: \.element.path) { index, url in
                                RecentRow(url: url) { Task { await runtime.openWorkspace(url) } }
                                    .overlay(alignment: .top) { if index > 0 { LXHairline() } }
                            }
                        }
                        .lxPanel(LXColor.content, cornerRadius: LingXiMetrics.Radius.control)
                    }
                    .frame(width: 400)
                }
            }
        }
        .padding(LingXiMetrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recents: [URL] {
        RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) }
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
        case .connecting(let path): return "工作区 \(URL(fileURLWithPath: path).lastPathComponent)"
        case .failed(let message): return message
        default: return "灵犀会在所选目录启动 Core；会话、工具调用和改动都来自真实运行。"
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(url.lastPathComponent).font(LXType.body).foregroundStyle(.primary)
                Spacer(minLength: LingXiMetrics.Space.lg)
                Text(url.deletingLastPathComponent().path)
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, LingXiMetrics.Space.md)
            .frame(height: LingXiMetrics.Size.rowList + 4)
            .background(isHovered ? LXColor.fillQuinary : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Command output

/// Slash-command output (status, /diff, /context …) in a native sheet.
struct CommandOutputSheet: View {
    let output: CommandOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            HStack {
                Text(output.title).font(LXType.headline)
                Spacer()
                LXCopyButton(output.text, label: "复制")
            }
            ScrollView {
                Text(output.text)
                    .font(LXType.monoSmall)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LingXiMetrics.Space.md)
            }
            .background(LXColor.fillQuinary,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LingXiMetrics.Space.xl)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 360, idealHeight: 520)
    }
}
#endif
