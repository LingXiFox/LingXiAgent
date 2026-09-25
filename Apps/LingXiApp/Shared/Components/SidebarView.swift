#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Navigator panel — "where am I": workspace, session search and history,
/// settings. No execution controls; those belong to the composer.
public struct SidebarView: View {
    @ObservedObject public var runtime: RuntimeFrontend
    @ObservedObject private var model: SidebarPresentationModel

    @State private var collapsedFolders: Set<String> = []
    @State private var renaming: SessionItemPresentation?
    @State private var renameDraft = ""
    @State private var pendingDeletion: SessionItemPresentation?

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.sidebarModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(runtime: runtime, workspace: model.workspace)

            #if os(macOS)
            NativeSearchField(text: $model.searchText, prompt: "搜索会话")
                .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
                .padding(.bottom, LingXiMetrics.Space.sm)
                .disabled(runtime.link != .connected)
            #endif

            sessionList

            Divider()
                .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
            NavigatorFooter(link: runtime.link, onOpenSettings: { runtime.isShowingSettings = true })
        }
        .sheet(item: $renaming) { session in
            RenameSessionSheet(title: $renameDraft) {
                runtime.renameSession(id: session.id, title: renameDraft)
                renaming = nil
            } onCancel: {
                renaming = nil
            }
        }
        .confirmationDialog("删除会话？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { session in
            Button("删除「\(session.title)」", role: .destructive) {
                runtime.deleteSession(id: session.id)
            }
        } message: { _ in
            Text("会话记录将从 Core 中删除，无法恢复。")
        }
    }

    private var sessionList: some View {
        List(selection: selection) {
            ForEach(visibleFolders) { folder in
                Section(isExpanded: expansion(for: folder.id)) {
                    ForEach(folder.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("重命名…") {
                                    renameDraft = session.title
                                    renaming = session
                                }
                                Divider()
                                Button("删除…", role: .destructive) { pendingDeletion = session }
                            }
                    }
                } header: {
                    Text(folder.folderName)
                }
            }
        }
        .listStyle(.sidebar)
        // The panel's glass is the only background; the list must not add a second one.
        .scrollContentBackground(.hidden)
        .overlay {
            if visibleFolders.isEmpty {
                PlaceholderLine(emptyText)
                    .multilineTextAlignment(.center)
                    .padding(LingXiMetrics.Space.lg)
            }
        }
    }

    private var emptyText: String {
        if runtime.link != .connected { return "打开工作区后，这里列出它的会话。" }
        return model.searchText.isEmpty ? "还没有会话。⌘N 新建一个。" : "没有匹配「\(model.searchText)」的会话。"
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionID },
            set: { id in
                guard let id, id != model.selectedSessionID else { return }
                runtime.switchSession(id: id)
            }
        )
    }

    private func expansion(for folderID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(folderID) },
            set: { expanded in
                if expanded { collapsedFolders.remove(folderID) } else { collapsedFolders.insert(folderID) }
            }
        )
    }

    /// Search matches titles; message-body search waits for session.list to return snippets.
    private var visibleFolders: [SessionFolderPresentation] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.folders }
        return model.folders.compactMap { folder in
            let hits = folder.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return hits.isEmpty ? nil : SessionFolderPresentation(folderName: folder.folderName, sessions: hits)
        }
    }
}

/// Current workspace (switchable), its branch and index state, and New Session.
private struct WorkspaceHeader: View {
    @ObservedObject var runtime: RuntimeFrontend
    let workspace: WorkspaceSummaryPresentation

    var body: some View {
        HStack(alignment: .center, spacing: LingXiMetrics.Space.sm) {
            Menu {
                ForEach(RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) }, id: \.path) { url in
                    Button {
                        Task { await runtime.openWorkspace(url) }
                    } label: {
                        Label(url.lastPathComponent, systemImage: url == runtime.workspaceURL ? "checkmark" : "folder")
                    }
                }
                Divider()
                #if os(macOS)
                Button("打开工作区…", action: chooseWorkspace)
                #endif
                if runtime.link == .connected {
                    Button("关闭工作区") { Task { await runtime.closeWorkspace() } }
                }
            } label: {
                identity
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize(horizontal: false, vertical: true)
            .help("切换工作区")

            Spacer(minLength: 0)

            Button(action: runtime.newSession) {
                Label("新建会话", systemImage: "square.and.pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(runtime.link != .connected)
            .help("新建会话 (⌘N)")
        }
        .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
        .padding(.top, LingXiMetrics.Space.md)
        .padding(.bottom, LingXiMetrics.Space.sm)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(workspace.name)
                .font(.lxCallout.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: LingXiMetrics.Space.xs) {
                if let branch = workspace.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                }
                if runtime.link == .connected, workspace.indexingState != "ready" {
                    Text("索引 \(workspace.indexingState)")
                }
            }
            .font(.lxMeta)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
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

/// Connection state and Settings — the two global entry points that are navigation.
private struct NavigatorFooter: View {
    let link: RuntimeFrontend.Link
    var onOpenSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置 (⌘,)")
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .lxNeonGlow(color: link == .connected ? LingXiTheme.neonTeal : Color.clear, radius: 4)
                Text(linkLabel)
                    .font(.lxMicro.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
        .font(.lxCallout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
        .padding(.vertical, LingXiMetrics.Space.md)
    }

    private var statusColor: Color {
        switch link {
        case .connected: return LingXiTheme.neonTeal
        case .failed: return LingXiTheme.neonCoral
        default: return Color.secondary
        }
    }

    private var linkLabel: String {
        switch link {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }

    private var linkSymbol: String {
        switch link {
        case .connected: return "circle.fill"
        case .connecting: return "circle.dotted"
        case .failed: return "exclamationmark.circle.fill"
        case .disconnected: return "circle"
        }
    }

    private var linkTint: AnyShapeStyle {
        switch link {
        case .connected: return AnyShapeStyle(LingXiTheme.neonTeal)
        case .failed: return AnyShapeStyle(LingXiTheme.neonCoral)
        default: return AnyShapeStyle(.tertiary)
        }
    }
}

private struct SessionRow: View {
    let session: SessionItemPresentation

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Label {
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(session.isActive ? .primary : .secondary)
            } icon: {
                Image(systemName: session.isActive ? "bubble.left.fill" : "bubble.left")
                    .foregroundStyle(session.isActive ? LingXiTheme.electricCyan : .secondary)
            }
            Spacer(minLength: LingXiMetrics.Space.xs)
            if session.isActive {
                ActivityDot()
            } else {
                Text(session.mode)
                    .font(.lxMicro)
                    .foregroundStyle(.tertiary)
                Text(session.lastUpdated, format: .relative(presentation: .named, unitsStyle: .narrow))
                    .font(.lxMeta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title)，\(session.messageCount) 条消息，模式 \(session.mode)\(session.isActive ? "，执行中" : "")")
    }
}

private struct RenameSessionSheet: View {
    @Binding var title: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("重命名会话").font(.lxTitle)
            TextField("会话标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("重命名", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.xl)
    }
}

/// Small brand-tinted dot: the one place the navigator uses the accent.
struct ActivityDot: View {
    var body: some View {
        Circle()
            .fill(LingXiTheme.accentColor)
            .frame(width: LingXiMetrics.Space.sm - 2, height: LingXiMetrics.Space.sm - 2)
            .accessibilityLabel("执行中")
    }
}

/// Task state as glyph + text in secondary colour; only running and failure
/// carry colour, and state is never conveyed by colour alone.
public struct TaskStatusBadge: View {
    public let state: String

    public init(state: String) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            if state.lowercased() == "running" {
                ActivityDot()
            } else {
                Image(systemName: symbol)
            }
            Text(TaskStateLabel.chinese(for: state))
        }
        .font(.lxMeta)
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("任务状态 \(TaskStateLabel.chinese(for: state))")
    }

    private var symbol: String {
        switch state.lowercased() {
        case "completed": return "checkmark.circle"
        case "paused": return "pause.circle"
        case "waiting": return "clock"
        case "failed", "cancelled": return "xmark.circle"
        default: return "circle.dotted"
        }
    }

    private var tint: AnyShapeStyle {
        switch state.lowercased() {
        case "failed": return AnyShapeStyle(.red)
        case "waiting": return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.secondary)
        }
    }
}

/// Protocol states are English identifiers; the UI shows Chinese per spec ch.5.
enum TaskStateLabel {
    static func chinese(for state: String) -> String {
        switch state.lowercased() {
        case "queued": return "排队中"
        case "running": return "执行中"
        case "paused": return "已暂停"
        case "waiting": return "待回答"
        case "completed": return "已完成"
        case "failed": return "已失败"
        case "cancelled": return "已取消"
        default: return state
        }
    }
}

#endif
