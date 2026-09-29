#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Navigator — "where am I": the workspace, its sessions, and the way to
/// Settings. No execution controls; those live in the composer.
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
    @State private var showsOtherWorkspaces = false
    @State private var renaming: SessionItemPresentation?
    @State private var renameDraft = ""
    @State private var pendingDeletion: SessionItemPresentation?
    @State private var projectlessError: String?

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.sidebarModel
        self.conversation = runtime.conversationModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            SidebarHead(runtime: runtime, workspace: model.workspace)

            NativeSearchField(text: $model.searchText, prompt: "搜索会话")
                .navigatorChrome()
                .padding(.horizontal, LingXiMetrics.Space.panelInset - 4)
                .padding(.bottom, LingXiMetrics.Space.sm)

            HStack(spacing: LingXiMetrics.Space.sm) {
                Button {
                    runtime.newSession()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .disabled(runtime.link != .connected)
                .help("在当前工作区新建会话")

                Button {
                    Task {
                        do { try await runtime.newSessionWithoutWorkspace() }
                        catch { projectlessError = error.localizedDescription }
                    }
                } label: {
                    Label("无项目", systemImage: "plus.square")
                        .frame(maxWidth: .infinity)
                }
                .help("新建无项目会话")
                .accessibilityLabel("新建无项目会话")
            }
            .font(LXType.meta.weight(.medium))
            .buttonStyle(LXButtonStyle(.secondary, size: .small))
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .padding(.bottom, LingXiMetrics.Space.sm)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections.filter(\.isCurrent)) { section in
                        sectionContent(section)
                    }
                    if !otherSections.isEmpty {
                        disclosureHeader("其他工作区 · \(otherSections.count)", isExpanded: otherWorkspacesVisible) {
                            showsOtherWorkspaces.toggle()
                        }
                        if otherWorkspacesVisible {
                            ForEach(otherSections) { section in
                                sectionContent(section)
                                    .padding(.leading, LingXiMetrics.Space.sm)
                            }
                        }
                    }
                }
                .padding(.bottom, LingXiMetrics.Space.sm)
                .background(ScrollBarDisabler())
            }
            .scrollIndicators(.hidden)
            .overlay {
                if sections.isEmpty {
                    PlaceholderLine(emptyText)
                        .multilineTextAlignment(.center)
                        .padding(LingXiMetrics.Space.xl)
                }
            }

            SidebarFooter(link: runtime.link) { runtime.isShowingSettings = true }
        }
        .lxPanel()
        .padding([.top, .leading, .bottom], LingXiMetrics.Space.sm)
        .background(LXColor.window)
        .sheet(item: $renaming) { session in
            RenameSessionSheet(title: $renameDraft) {
                runtime.renameSession(id: session.id, title: renameDraft)
                renaming = nil
            } onCancel: { renaming = nil }
        }
        .confirmationDialog("删除会话？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { session in
            Button("删除「\(session.title)」", role: .destructive) { runtime.deleteSession(id: session.id) }
        } message: { _ in
            Text("会话记录将从 Core 中删除，无法恢复。")
        }
        .alert("无法新建无项目会话", isPresented: Binding(
            get: { projectlessError != nil }, set: { if !$0 { projectlessError = nil } }
        )) {
            Button("好") { projectlessError = nil }
        } message: {
            Text(projectlessError ?? "")
        }
    }

    // MARK: Sections

    private struct Section: Identifiable {
        let id: String
        let title: String
        let sessions: [SessionItemPresentation]
        let isCurrent: Bool
    }

    private var sections: [Section] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        return model.folders.compactMap { folder in
            let sessions = query.isEmpty || folder.folderName.localizedCaseInsensitiveContains(query) ? folder.sessions
                : folder.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            guard !sessions.isEmpty else { return nil }
            let currentPath = runtime.workspaceURL?.standardizedFileURL.path
            let isCurrent = folder.id == currentPath ||
                (currentPath == nil && folder.folderName == model.workspace.name)
            return Section(id: folder.id, title: folder.folderName, sessions: sessions, isCurrent: isCurrent)
        }
    }

    private var otherSections: [Section] { sections.filter { !$0.isCurrent } }

    private var otherWorkspacesVisible: Bool {
        showsOtherWorkspaces || !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty ||
            otherSections.contains { section in section.sessions.contains { $0.id == model.selectedSessionID } }
    }

    private func isExpanded(_ section: Section) -> Bool {
        if collapsed.contains(section.id) { return false }
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return expanded.contains(section.id) ||
            section.sessions.contains { $0.id == model.selectedSessionID }
    }

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        sectionHeader(section)
        if isExpanded(section) {
            ForEach(section.sessions) { session in row(session) }
        }
    }

    private func sectionHeader(_ section: Section) -> some View {
        disclosureHeader(section.title, isExpanded: isExpanded(section)) {
            if isExpanded(section) {
                collapsed.insert(section.id)
                expanded.remove(section.id)
            } else {
                collapsed.remove(section.id)
                expanded.insert(section.id)
            }
        }
    }

    private func disclosureHeader(_ title: String, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text(title)
                    .font(LXType.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .padding(.top, LingXiMetrics.Space.sm)
            .padding(.bottom, LingXiMetrics.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(isExpanded ? "已展开" : "已折叠")")
    }

    private func row(_ session: SessionItemPresentation) -> some View {
        SessionRow(session: session,
                   isSelected: session.id == model.selectedSessionID,
                   awaitingAnswer: awaitingAnswer(session)) {
            guard session.id != model.selectedSessionID else { return }
            runtime.switchSession(id: session.id)
        }
        .contextMenu {
            Button("重命名…") {
                renameDraft = session.title
                renaming = session
            }
            Divider()
            Button("删除…", role: .destructive) { pendingDeletion = session }
        }
    }

    private var emptyText: String {
        if runtime.link != .connected { return "打开工作区后，这里列出它的会话。" }
        return model.searchText.isEmpty ? "还没有会话。⌘N 新建一个。" : "没有匹配「\(model.searchText)」的会话。"
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

/// 44 tall: workspace name (600 13) as a menu to switch workspace, branch on
/// the right as a caption.
private struct SidebarHead: View {
    @ObservedObject var runtime: RuntimeFrontend
    let workspace: WorkspaceSummaryPresentation

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Menu {
                ForEach(RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) }, id: \.path) { url in
                    Button {
                        Task { await runtime.openWorkspace(url) }
                    } label: {
                        Label(url.lastPathComponent, systemImage: url == runtime.workspaceURL ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button("打开工作区…") { WorkspacePicker.choose(runtime) }
                if runtime.link == .connected {
                    Button("关闭工作区") { Task { await runtime.closeWorkspace() } }
                }
            } label: {
                Text(workspace.name)
                    .font(LXType.body.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .tint(.primary)
            .fixedSize()
            .help("切换工作区")

            Spacer(minLength: LingXiMetrics.Space.sm)

            if let branch = workspace.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Git 分支 \(branch)")
            }
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
