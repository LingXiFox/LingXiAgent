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
                ActionFlowTimelineView(items: conversation.items,
                                       isGenerating: conversation.isGenerating,
                                       hasAnyItem: !conversation.items.isEmpty,
                                       tailNotice: runtime.providerNotice)
                    .lxFloatingBar(edge: .bottom) {
                        ComposerDock(runtime: runtime)
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
        case .connecting(let path): return path
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

    public init(items: [TimelineItemPresentation], isGenerating: Bool, hasAnyItem: Bool = true,
                tailNotice: NoticePresentation? = nil) {
        self.items = items
        self.isGenerating = isGenerating
        self.hasAnyItem = hasAnyItem
        self.tailNotice = tailNotice
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                let rows = items.foldedIntoRows()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                        if !hasAnyItem {
                            StageEmptyState()
                        }

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
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: BottomOffsetKey.self,
                                value: content.frame(in: .named("stageScroll")).maxY - viewport.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: "stageScroll")
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

/// Empty session: one statement and a hint.
struct StageEmptyState: View {
    var body: some View {
        ReadingColumn {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                Text("下达一个任务，本狐接着干活")
                    .font(.lxTitle)
                Text("写清目标与验收标准。输入 / 查看命令，@ 引用文件，⌘K 打开命令面板。")
                    .font(.lxCallout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, LingXiMetrics.Space.lg)
        }
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
