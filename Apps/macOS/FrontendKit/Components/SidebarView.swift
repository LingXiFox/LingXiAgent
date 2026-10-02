#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Navigator — "where am I": Workspace → Session, and the way to Settings. No execution
/// controls; those live in the composer.
///
/// Two levels and only two. Every workspace is a peer row (the current one is marked, not
/// promoted into a separate header), and every session sits under the workspace it belongs
/// to. The head used to repeat the current workspace's name above a folder row of the same
/// name, so 「LingXiAgent」 appeared twice with no way to tell which was the workspace and
/// which the session folder; a 「新建会话」 button at the top never said where the session
/// would go. Creating a session is now a per-workspace action, and the top only imports.
///
/// Sidebar contract: system material, neutral ground, no ambient light.
/// Selection is `fill-control` with the row icon in `accent-text`; the only
/// other colour in the column is the 6pt Teal running dot (or the warning
/// clock when that run waits on a human).
public struct SidebarView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var model: SidebarPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel

    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var showsArchived: Set<String> = []
    @State private var showsMissing = false
    @State private var archived: Set<String> = ArchivedSessions.all
    @State private var renaming: SessionItemPresentation?
    @State private var renameDraft = ""
    @State private var pendingDeletion: SessionItemPresentation?

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.sidebarModel
        self.conversation = runtime.conversationModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            SidebarHead(count: workspaces.filter(\.exists).count)

            NativeSearchField(text: $model.searchText, prompt: "搜索工作区或会话")
                .navigatorChrome()
                .padding(.horizontal, LingXiMetrics.Space.panelInset - 4)
                .padding(.bottom, LingXiMetrics.Space.sm)

            Button {
                WorkspacePicker.choose(runtime)
            } label: {
                Label("导入工作区", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .font(LXType.meta.weight(.medium))
            .buttonStyle(LXButtonStyle(.secondary, size: .small))
            .help("选择一个文件夹作为工作区；会话都建在某个工作区之下")
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .padding(.bottom, LingXiMetrics.Space.sm)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleWorkspaces.filter(\.exists)) { workspace in
                        workspaceContent(workspace)
                    }
                    let missing = visibleWorkspaces.filter { !$0.exists }
                    if !missing.isEmpty {
                        MissingWorkspacesToggle(count: missing.count,
                                                isExpanded: showsMissing || !query.isEmpty) {
                            showsMissing.toggle()
                        }
                        if showsMissing || !query.isEmpty {
                            ForEach(missing) { workspace in workspaceContent(workspace) }
                        }
                    }
                }
                .padding(.bottom, LingXiMetrics.Space.sm)
                .background(ScrollBarDisabler())
            }
            .scrollIndicators(.hidden)
            .overlay {
                if visibleWorkspaces.isEmpty {
                    PlaceholderLine(emptyText)
                        .multilineTextAlignment(.center)
                        .padding(LingXiMetrics.Space.xl)
                }
            }

            SidebarFooter(link: runtime.link) { runtime.isShowingSettings = true }
        }
        .lxPanel()
        .padding([.top, .leading, .bottom], LingXiMetrics.Space.sm)
        .sheet(item: $renaming) { session in
            RenameSessionSheet(title: $renameDraft) {
                runtime.renameSession(id: session.id, title: renameDraft)
                renaming = nil
            } onCancel: { renaming = nil }
        }
        .confirmationDialog("删除会话？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { session in
            Button("删除「\(session.title)」", role: .destructive) {
                runtime.deleteSession(id: session.id)
                setArchived(session.id, false)
            }
        } message: { _ in
            Text("会话记录将从 Core 中删除，无法恢复。不想看到它但还要留着，用「归档」。")
        }
    }

    // MARK: Workspaces

    private struct Workspace: Identifiable {
        /// Standardised absolute path, or the projection's label when Core gave none.
        let id: String
        let name: String
        /// Parent folder, shown only when two workspaces share a name.
        var disambiguation: String?
        let isCurrent: Bool
        let sessions: [SessionItemPresentation]
        /// The folder is still on disk. A workspace whose folder is gone keeps its sessions
        /// readable, but nothing can be created in it, so it is not listed among the live ones.
        var exists: Bool { isCurrent || url.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }
        var url: URL? { id.hasPrefix("/") ? URL(fileURLWithPath: id) : nil }
    }

    private var currentPath: String? {
        runtime.workspaceURL?.standardizedFileURL.path
    }

    /// The current workspace (even with no sessions yet), every workspace that owns sessions,
    /// then recently opened ones — each exactly once.
    private var workspaces: [Workspace] {
        var order: [String] = []
        var sessions: [String: [SessionItemPresentation]] = [:]
        if let currentPath { order.append(currentPath) }
        for folder in model.folders {
            let key = folder.id.hasPrefix("/") ? URL(fileURLWithPath: folder.id).standardizedFileURL.path : folder.id
            if !order.contains(key) { order.append(key) }
            sessions[key, default: []].append(contentsOf: folder.sessions)
        }
        for url in RecentWorkspaces.all where FileManager.default.fileExists(atPath: url.path) {
            let key = url.standardizedFileURL.path
            if !order.contains(key) { order.append(key) }
        }
        var result = order.map { path in
            Workspace(id: path,
                      name: path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path,
                      isCurrent: path == currentPath,
                      sessions: sessions[path] ?? [])
        }
        let names = Dictionary(grouping: result.indices, by: { result[$0].name })
        for (_, indices) in names where indices.count > 1 {
            for index in indices {
                result[index].disambiguation = result[index].url?.deletingLastPathComponent().lastPathComponent
            }
        }
        return result
    }

    private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

    private var visibleWorkspaces: [Workspace] {
        guard !query.isEmpty else { return workspaces }
        return workspaces.compactMap { workspace in
            if workspace.name.localizedCaseInsensitiveContains(query) { return workspace }
            let hits = workspace.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            guard !hits.isEmpty else { return nil }
            return Workspace(id: workspace.id, name: workspace.name, disambiguation: workspace.disambiguation,
                             isCurrent: workspace.isCurrent, sessions: hits)
        }
    }

    private func isExpanded(_ workspace: Workspace) -> Bool {
        if collapsed.contains(workspace.id) { return false }
        if !query.isEmpty { return true }
        return workspace.isCurrent || expanded.contains(workspace.id) ||
            workspace.sessions.contains { $0.id == model.selectedSessionID }
    }

    private func toggle(_ workspace: Workspace) {
        if isExpanded(workspace) {
            collapsed.insert(workspace.id)
            expanded.remove(workspace.id)
        } else {
            collapsed.remove(workspace.id)
            expanded.insert(workspace.id)
        }
    }

    @ViewBuilder
    private func workspaceContent(_ workspace: Workspace) -> some View {
        WorkspaceHeader(name: workspace.name,
                        disambiguation: workspace.disambiguation,
                        path: workspace.id,
                        isCurrent: workspace.isCurrent,
                        branch: workspace.isCurrent ? model.workspace.gitBranch : nil,
                        isExpanded: isExpanded(workspace),
                        canCreate: workspace.url != nil && workspace.exists,
                        onToggle: { toggle(workspace) },
                        onNewSession: { newSession(in: workspace) })
            .contextMenu { workspaceMenu(workspace) }
        if isExpanded(workspace) {
            let active = workspace.sessions.filter { !archived.contains($0.id) }
            let shelved = workspace.sessions.filter { archived.contains($0.id) }
            if active.isEmpty && shelved.isEmpty {
                Text("还没有会话")
                    .font(LXType.meta)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, LingXiMetrics.Space.panelInset + 18)
                    .padding(.vertical, LingXiMetrics.Space.xs)
            }
            ForEach(active) { session in row(session, in: workspace) }
            if !shelved.isEmpty {
                ArchivedToggle(count: shelved.count, isExpanded: showsArchived.contains(workspace.id)) {
                    if showsArchived.contains(workspace.id) { showsArchived.remove(workspace.id) }
                    else { showsArchived.insert(workspace.id) }
                }
                if showsArchived.contains(workspace.id) {
                    ForEach(shelved) { session in
                        row(session, in: workspace).opacity(0.7)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: Workspace) -> some View {
        if workspace.url != nil, workspace.exists {
            Button("在此工作区新建会话") { newSession(in: workspace) }
        }
        if let url = workspace.url, workspace.exists {
            if !workspace.isCurrent {
                Button("切换到此工作区") { Task { await runtime.openWorkspace(url) } }
            }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if workspace.isCurrent, runtime.link == .connected {
            Divider()
            Button("关闭工作区") { Task { await runtime.closeWorkspace() } }
        }
    }

    private func row(_ session: SessionItemPresentation, in workspace: Workspace) -> some View {
        let isArchived = archived.contains(session.id)
        return SessionRow(session: session,
                          isSelected: session.id == model.selectedSessionID,
                          awaitingAnswer: awaitingAnswer(session)) {
            guard session.id != model.selectedSessionID else { return }
            runtime.switchSession(id: session.id)
        }
        .padding(.leading, LingXiMetrics.Space.md)
        .contextMenu {
            Button("重命名…") {
                renameDraft = session.title
                renaming = session
            }
            Button("创建分支") { fork(session, in: workspace) }
                .disabled(session.isActive)
            Button(isArchived ? "取消归档" : "归档") { setArchived(session.id, !isArchived) }
            Divider()
            Button("删除…", role: .destructive) { pendingDeletion = session }
        }
    }

    // MARK: Actions

    private func newSession(in workspace: Workspace) {
        guard let url = workspace.url else { return }
        collapsed.remove(workspace.id)
        Task { await runtime.newSession(inWorkspace: url.path) }
    }

    /// A fork is created by the Core that serves the session's workspace.
    private func fork(_ session: SessionItemPresentation, in workspace: Workspace) {
        if workspace.isCurrent || workspace.url == nil {
            runtime.forkSession(id: session.id)
            return
        }
        Task {
            if let url = workspace.url { await runtime.openWorkspace(url) }
            if runtime.link == .connected { runtime.forkSession(id: session.id) }
        }
    }

    private func setArchived(_ id: String, _ value: Bool) {
        ArchivedSessions.set(id, archived: value)
        archived = ArchivedSessions.all
    }

    private var emptyText: String {
        if !query.isEmpty { return "没有匹配「\(model.searchText)」的工作区或会话。" }
        return "还没有工作区。点「导入工作区」选择一个文件夹。"
    }

    /// A running row that is the current session and holds a real pending card.
    private func awaitingAnswer(_ session: SessionItemPresentation) -> Bool {
        guard session.isActive, session.id == conversation.sessionID else { return false }
        return conversation.items.contains {
            if case .interaction(let card) = $0.kind { return card.status == .pending }
            return false
        }
    }
}

// MARK: - Workspace header

/// One workspace row: disclosure, folder glyph, name, 「当前」 + branch for the open one, and
/// its own 「新建会话」. The full path is the tooltip, so two folders that share a name are
/// never ambiguous.
private struct WorkspaceHeader: View {
    let name: String
    let disambiguation: String?
    let path: String
    let isCurrent: Bool
    let branch: String?
    let isExpanded: Bool
    let canCreate: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Button(action: onToggle) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: isCurrent ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
                    Text(name)
                        .font(LXType.meta.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let disambiguation {
                        Text(disambiguation)
                            .font(LXType.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if isCurrent {
                        Text("当前")
                            .font(LXType.micro.weight(.medium))
                            .foregroundStyle(LXColor.accentText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(LXColor.accentSoft, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if let branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(LXType.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("Git 分支 \(branch)")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("工作区 \(name)\(isCurrent ? "，当前" : "")，\(isExpanded ? "已展开" : "已折叠")")

            if canCreate {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(isHovered ? LXColor.fillControl : .clear,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在「\(name)」中新建会话")
                .accessibilityLabel("在 \(name) 中新建会话")
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.panelInset - 4)
        .padding(.top, LingXiMetrics.Space.sm)
        .padding(.bottom, LingXiMetrics.Space.xs)
        .onHover { isHovered = $0 }
        .help(path)
    }
}

/// The workspaces whose folders were deleted (temporary directories, moved projects). Their
/// sessions stay reachable, collapsed out of the way of the ones that still exist.
private struct MissingWorkspacesToggle: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 12))
                Text("目录已不存在的工作区 · \(count)")
                    .font(LXType.meta)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, LingXiMetrics.Space.panelInset - 4)
            .padding(.top, LingXiMetrics.Space.md)
            .padding(.bottom, LingXiMetrics.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("这些工作区的文件夹已被删除或移动；会话仍可查看，不能在其中新建会话")
    }
}

private struct ArchivedToggle: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                Text(isExpanded ? "收起已归档 · \(count)" : "已归档 · \(count)")
                    .font(LXType.micro)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, LingXiMetrics.Space.panelInset + 18)
            .padding(.vertical, LingXiMetrics.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ScrollBarDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollBarDisablerView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.enclosingScrollView?.hasVerticalScroller = false
    }
}

private final class ScrollBarDisablerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.enclosingScrollView?.hasVerticalScroller = false
        }
    }
}

// MARK: - Head

/// 44 tall: names the level the list below is made of. It used to be the current workspace's
/// name as a menu, which repeated the first folder row right under it.
private struct SidebarHead: View {
    let count: Int

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Text("工作区")
                .font(LXType.body.weight(.semibold))
            if count > 0 {
                Text("\(count)")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LingXiMetrics.Space.panelInset)
        .frame(height: LingXiMetrics.Size.sidebarHead)
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: SessionItemPresentation
    let isSelected: Bool
    let awaitingAnswer: Bool
    let action: () -> Void

    var body: some View {
        LXSidebarRow(session.title, symbol: "bubble.left", isSelected: isSelected, action: action) {
            if session.isActive && awaitingAnswer {
                Image(systemName: "clock")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LXStatus.warning)
            } else if session.isActive {
                LXActivityDot(tone: .running)
            } else {
                Text(RelativeDay.label(session.lastUpdated))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(session.title)，\(session.messageCount) 条消息"
        if session.isActive { text += awaitingAnswer ? "，待回答" : "，执行中" }
        return text
    }
}

/// Today → time, yesterday →「昨天」, this week → weekday, else month-day.
enum RelativeDay {
    static func label(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let style = Date.FormatStyle(locale: Locale(identifier: "zh_CN"))
        if days < 7 { return date.formatted(style.weekday(.abbreviated)) }
        return date.formatted(style.month(.defaultDigits).day())
    }
}

// MARK: - Footer

private struct SidebarFooter: View {
    let link: RuntimeFrontend.Link
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
                    .font(LXType.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置 (⌘,)")
            Spacer(minLength: 0)
            LXStatusText(label, systemImage: symbol, tone: tone)
        }
        .padding(.horizontal, LingXiMetrics.Space.panelInset)
        .padding(.vertical, LingXiMetrics.Space.md)
        .overlay(alignment: .top) { LXHairline().padding(.horizontal, LingXiMetrics.Space.panelInset) }
    }

    private var tone: LXStatusText.Tone {
        switch link {
        case .connected: .success
        case .connecting: .warning
        case .failed: .danger
        case .disconnected: .muted
        }
    }

    private var symbol: String {
        switch link {
        case .connected: return "circle.fill"
        case .connecting: return "circle.dotted"
        case .failed: return "exclamationmark.circle.fill"
        case .disconnected: return "circle"
        }
    }

    private var label: String {
        switch link {
        case .connected: return "已连接"
        case .connecting: return "正在连接"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }
}

// MARK: - Rename

private struct RenameSessionSheet: View {
    @Binding var title: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("重命名会话").font(LXType.headline)
            TextField("会话标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(onCommit)
            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.lxSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("重命名", action: onCommit)
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.xl)
    }
}

// MARK: - Workspace picker

enum WorkspacePicker {
    @MainActor
    static func choose(_ runtime: RuntimeFrontend) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runtime.openWorkspace(url) }
        }
    }
}
#endif
