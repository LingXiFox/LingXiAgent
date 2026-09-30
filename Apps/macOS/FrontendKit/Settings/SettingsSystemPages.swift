#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
#if os(macOS)
import AppKit
#endif

// MARK: - MCP / Skills / Plugins

struct ExtensionsSettingsPage: View {
    @ObservedObject var store: SettingsStore
    let kinds: [ExtensionKind]
    @Environment(\.settingsSelection) private var selection
    @Environment(\.settingsAddTrigger) private var addTrigger
    @Environment(\.settingsSelect) private var select
    @State private var isAdding = false

    var body: some View {
        LXSettingsScrollPage(title: pageHeaderTitle, subtitle: pageHeaderSubtitle) {
            if kinds == [.mcp] {
                mcpDetail
            } else {
                ForEach(kinds, id: \.self) { kind in
                    list(kind)
                }
            }
        }
        .onChange(of: addTrigger) { _, _ in if kinds == [.mcp] { isAdding = true } }
        .sheet(isPresented: $isAdding) {
            AddMCPServerSheet(store: store) { added in
                isAdding = false
                if let added { select(added.id) }
            }
        }
    }

    /// Skills / Plugins / Hooks: one row per object, collection action on the head.
    private func list(_ kind: ExtensionKind) -> some View {
        let items = store.extensions.filter { $0.kind == kind }
        return LXSettingsCard(title: HStack(spacing: LingXiMetrics.Space.xs) {
            LXSettingsSectionHeader(title(kind))
            Text("\(items.count)").font(LXType.sectionHead).foregroundStyle(.secondary)
        }, rowSpacing: 0, accessory: {
            if kind == kinds.first {
                Button("重新加载") { Task { await store.reloadExtensions() } }
                    .disabled(store.client == nil)
                    .settingsAnchor("extensions.reload")
            }
        }) {
            if store.client != nil && items.isEmpty {
                PlaceholderLine(emptyText(kind))
                    .lxSettingsRow()
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, ext in
                if index > 0 { LXSettingsDivider() }
                ExtensionRow(ext: ext) { enabled in
                    Task { await store.setExtension(ext.id, enabled: enabled) }
                }
                .settingsAnchor("extension.\(ext.id)")
            }
        }
        .settingsAnchor("extensions.list")
    }

    /// MCP is master–detail: the middle column lists every server (from
    /// mcp.json), this page edits only the selected one.
    @ViewBuilder
    private var mcpDetail: some View {
        MCPRestartBanner(store: store)
        if let server = store.mcpServers.first(where: { $0.id == selection }) ?? store.mcpServers.first {
            MCPServerEditor(store: store, server: server)
                .id(server.id)
        } else if store.client != nil {
            PlaceholderLine("mcp.json 里还没有服务器。用中间列的「＋」添加一个。")
        }
    }

    private func title(_ kind: ExtensionKind) -> String {
        switch kind {
        case .mcp: return "MCP 服务器"
        case .skill: return "Skills"
        case .plugin: return "插件"
        case .command: return "命令"
        case .hook: return "Hooks"
        }
    }

    private func emptyText(_ kind: ExtensionKind) -> String {
        "Core 未加载任何\(title(kind))。"
    }

    /// Header text follows the sidebar label for the page these kinds route to.
    private var pageHeaderTitle: String {
        switch kinds.first {
        case .mcp: return "MCP"
        case .skill: return "Skills 技能"
        case .plugin: return "Plugins 插件"
        case .hook: return "Hooks 钩子"
        case .command: return "命令"
        case nil: return "扩展"
        }
    }

    private var pageHeaderSubtitle: String {
        switch kinds.first {
        case .mcp: return "查看与配置 Core 加载的 MCP 服务器。"
        case .skill: return "查看 Core 加载的 Skills，控制各技能的启用状态。"
        case .plugin: return "查看 Core 加载的插件与命令，控制各自的启用状态。"
        case .hook: return "查看 Core 加载的 Hooks，控制各钩子的启用状态。"
        case .command: return "查看 Core 加载的命令，控制各命令的启用状态。"
        case nil: return "查看 Core 加载的扩展，控制各自的启用状态。"
        }
    }
}

private struct ExtensionRow: View {
    let ext: ExtensionInfo
    var onToggle: (Bool) -> Void

    /// §1: colour lands on the 6pt dot only — the state text stays text-primary.
    var dotColor: Color { ExtensionState(ext: ext).tone }

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Circle()
                .fill(dotColor)
                .frame(width: LXControl.dot, height: LXControl.dot)
                .accessibilityLabel(ext.enabled ? "已启用" : "已停用")

            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(ext.id)
                        .font(LXType.monoSmall.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    LXBadge("v\(ext.version)", kind: .outline)
                }
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(ext.lifecycleState)
                        .foregroundStyle(.primary)
                        .font(LXType.meta)
                    Text("·")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                    Text(ext.scope)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                    if let summary = ext.summary, !summary.isEmpty {
                        Text("·")
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: LingXiMetrics.Space.md)

            Toggle("", isOn: Binding(get: { ext.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(LXColor.accent)
                .labelsHidden()
                .accessibilityLabel("\(ext.id) 启用状态")
        }
        .lxSettingsRow()
    }
}

// MARK: - Workspace

struct WorkspaceSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmPrune = false
    @State private var pendingAction: PendingWorktreeAction?

    struct PendingWorktreeAction {
        enum Action { case apply, discard }
        let tree: WorkspaceWorktreeInfo
        let action: Action
    }

    private func isCurrent(_ tree: WorkspaceWorktreeInfo) -> Bool {
        guard let current = store.runtime?.workspaceURL else { return false }
        return URL(fileURLWithPath: tree.path).resolvingSymlinksInPath() == current.resolvingSymlinksInPath()
    }

    /// The Core serving a worktree workspace cannot keep running inside a
    /// removed directory, so that case goes through the main window's runtime.
    private func perform(_ pending: PendingWorktreeAction) async {
        if isCurrent(pending.tree), let runtime = store.runtime {
            if pending.action == .apply { await runtime.applyCurrentWorktree() } else { await runtime.discardCurrentWorktree() }
            await store.refresh()
        } else if pending.action == .apply {
            _ = await store.applyWorktree(pending.tree.id)
        } else {
            _ = await store.discardWorktree(pending.tree.id)
        }
    }

    var body: some View {
        LXSettingsScrollPage(title: "工作区与 Worktree",
                             subtitle: "当前工作区与 Git 仓库的状态，以及任务使用的 Worktree。") {
            if let workspace = store.workspace {
                LXSettingsCard("当前工作区", rowSpacing: 0) {
                    ValueRow(title: "根目录", value: workspace.rootPath, monospaced: true)
                    LXSettingsDivider()
                    ValueRow(title: "Git 仓库", value: workspace.isGitRepository ? "是" : "否")
                    if let state = workspace.indexingState {
                        LXSettingsDivider()
                        ValueRow(title: "代码索引", value: state)
                    }
                    if let nodes = workspace.codebaseNodes, let edges = workspace.codebaseEdges {
                        LXSettingsDivider()
                        ValueRow(title: "图谱规模", value: "\(nodes) 节点 · \(edges) 边")
                    }
                }
                .settingsAnchor("workspace.summary")
            }

            LXSettingsCard(title: HStack(spacing: LingXiMetrics.Space.xs) {
                LXSettingsSectionHeader("Worktree 列表")
                Text("\(store.worktrees.count)").font(LXType.sectionHead).foregroundStyle(.secondary)
            }, rowSpacing: 0, accessory: {
                Button("清理失效…") { confirmPrune = true }
                    .disabled(store.client == nil)
            }) {
                if store.worktrees.isEmpty {
                    PlaceholderLine(store.workspace?.isGitRepository == false
                                    ? "当前工作区不是 Git 仓库，无法使用独立 Worktree。"
                                    : "还没有独立 Worktree。在 Composer 的执行环境里选择「独立 Worktree」即可创建。")
                        .lxSettingsRow()
                }
                ForEach(Array(store.worktrees.enumerated()), id: \.element.id) { index, tree in
                    if index > 0 { LXSettingsDivider() }
                    WorktreeRow(tree: tree,
                                isCurrent: isCurrent(tree),
                                onApply: { pendingAction = PendingWorktreeAction(tree: tree, action: .apply) },
                                onDiscard: { pendingAction = PendingWorktreeAction(tree: tree, action: .discard) })
                }
            } footer: {
                Text("应用会把 Worktree 的改动以「已暂存、未提交」的形式放进主工作区，由你审阅后提交，随后移除该 Worktree。")
            }
            .settingsAnchor("workspace.worktrees")
            .confirmationDialog(pendingAction?.action == .apply ? "应用这个 Worktree？" : "丢弃这个 Worktree？",
                                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                                presenting: pendingAction) { pending in
                if pending.action == .apply {
                    Button("应用") { Task { await perform(pending) } }
                } else {
                    Button("丢弃", role: .destructive) { Task { await perform(pending) } }
                }
            } message: { pending in
                Text(pending.action == .apply
                     ? "\(pending.tree.branch) 的改动会落到主工作区，随后删除该 Worktree。"
                     : "\(pending.tree.branch) 与其目录会被删除，未应用的改动无法恢复。")
            }
            .confirmationDialog("清理失效的 Worktree？", isPresented: $confirmPrune) {
                Button("清理", role: .destructive) { Task { await store.pruneWorktrees() } }
            } message: {
                Text("只移除 Git 已记录为失效的 Worktree 元数据，不删除仍在使用的目录。")
            }
        }
    }
}

// MARK: - Diagnostics

private struct WorktreeRow: View {
    let tree: WorkspaceWorktreeInfo
    let isCurrent: Bool
    let onApply: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Image(systemName: "arrow.triangle.branch")
                .font(LXType.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(tree.branch).font(LXType.monoSmall).foregroundStyle(.primary).lineLimit(1)
                    if isCurrent { LXBadge("当前", kind: .accent) }
                    if !tree.isActive { LXBadge("已失效", kind: .outline) }
                }
                Text([tree.path, tree.baseCommit.map { "基于 \($0.prefix(7))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: LingXiMetrics.Space.md)
            Text(tree.createdAt, style: .relative)
                .font(LXType.meta)
                .foregroundStyle(.secondary)
            Button("应用…", action: onApply)
                .buttonStyle(LXButtonStyle(.secondary, size: .small))
                .disabled(!tree.isActive)
            Button("丢弃…", action: onDiscard)
                .buttonStyle(LXButtonStyle(.destructive, size: .small))
        }
        .lxSettingsRow()
    }
}

struct DiagnosticsSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var copied = false

    var body: some View {
        LXSettingsScrollPage(title: "诊断",
                             subtitle: "Core 运行时状态、后台任务与诊断工具。") {
            LXSettingsCard("运行时状态", accessory: {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    Button("刷新") { Task { await store.refresh() } }
                        .disabled(store.client == nil)
                }
            }) {
                if store.client == nil {
                    LabeledContent("Core") { ConnectCoreButton(store: store) }
                        .lxSettingsRow()
                }
                if let info = store.runtimeInfo {
                    ValueRow(title: "版本", value: "\(info.name) \(info.version)")
                    ValueRow(title: "协议", value: "\(info.protocolVersion)")
                    LabeledContent("启动于") {
                        Text(info.startedAt, style: .relative)
                            .font(LXType.meta)
                            .foregroundStyle(.primary)
                    }
                    .lxSettingsRow()
                }
                if let health = store.health {
                    LabeledContent("健康状态") {
                        LXStatusText(health.status.rawValue,
                                     systemImage: health.status == .healthy ? "checkmark.circle" : "exclamationmark.triangle",
                                     tone: health.status == .healthy ? .success : .warning)
                    }
                    .lxSettingsRow()
                    ValueRow(title: "活动会话 / 运行", value: "\(health.activeSessions) / \(health.activeRuns)")
                }
                if let metrics = store.providerMetrics {
                    ValueRow(title: "Provider 请求 / 错误",
                             value: "\(metrics.requestCount) / \(metrics.errorCount) · 平均 \(Int(metrics.averageLatencyMs)) ms")
                }
                if let caps = store.capabilities {
                    ValueRow(title: "附件上限", value: ByteCountFormatter.string(fromByteCount: Int64(caps.maxAttachmentBytes), countStyle: .file))
                    ValueRow(title: "协议特性", value: caps.supportedFeatures.map(\.rawValue).joined(separator: ", "))
                }
            }
            .settingsAnchor("diagnostics.runtime")

            LXSettingsCard("后台任务", rowSpacing: 0) {
                if store.client != nil && store.backgroundTasks.isEmpty {
                    PlaceholderLine("没有后台任务。")
                        .lxSettingsRow()
                }
                ForEach(Array(store.backgroundTasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { LXSettingsDivider() }
                    HStack(spacing: LingXiMetrics.Space.md) {
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                            Text(task.description ?? task.command)
                                .font(LXType.monoSmall)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(task.status.rawValue) · \(Int(task.elapsedSeconds))s")
                                .font(LXType.meta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: LingXiMetrics.Space.md)
                        if task.status == .running {
                            Button("终止") { Task { await store.terminateBackgroundTask(task.id) } }
                                .buttonStyle(LXButtonStyle(.destructive, size: .small))
                        }
                    }
                    .lxSettingsRow()
                }
            }
            .settingsAnchor("diagnostics.background")

            LXSettingsCard("配置",
                           subtitle: "所有设置都在设置窗口里修改，不需要编辑文件。某个配置文件损坏时，这里会指出是哪一个。") {
                LabeledContent("配置状态") {
                    if store.isConfigReadable {
                        LXStatusText("全部可读", systemImage: "checkmark.circle", tone: .success)
                    } else {
                        LXStatusText("config.json 无法解析，设置不会覆盖它", systemImage: "exclamationmark.triangle",
                                     tone: .danger)
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("diagnostics.config")
                #if os(macOS)
                LabeledContent("数据目录") {
                    Button("在 Finder 中显示") { NSWorkspace.shared.open(LingXiDataRoot.url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(LXColor.accentText)
                }
                .lxSettingsRow()
                .settingsAnchor("files")
                #endif
                LabeledContent("让 Core 重新读取配置") {
                    Button("重新加载") { Task { await store.reloadConfiguration() } }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                        .disabled(store.client == nil)
                }
                .lxSettingsRow()
            }

            LXSettingsCard("诊断包") {
                LabeledContent {
                    Button(copied ? "已复制" : "复制 JSON") {
                        Task {
                            guard let json = await store.diagnosticsBundleJSON() else { return }
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                            #endif
                            copied = true
                        }
                    }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    .disabled(store.client == nil)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("诊断包")
                        Text("包含配置摘要、近期错误、运行与 trace，分享前请自行检查。")
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("diagnostics.bundle")
            }
        }
    }
}

#endif

#if os(macOS)
import ApplicationServices
import CoreGraphics

// MARK: - Computer use & browser

/// Real capability state only: system permissions this app holds (Core runs as
/// its child, so macOS attributes them to LingXiAgent) and what Core itself reports
/// about its desktop and browser tools. No toggles, no verdicts of this window's
/// own.
struct ComputerUseSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        LXSettingsScrollPage(title: "Computer Use 与浏览器", subtitle: "LingXiAgent 获得的系统权限，与 Core 中桌面、浏览器工具的当前状态。") {
            LXSettingsCard(title: LXSettingsSectionHeader("系统权限"), accessory: {
                Button("重新检测") {
                    accessibility = AXIsProcessTrusted()
                    screenRecording = CGPreflightScreenCaptureAccess()
                }
            }) {
                PermissionStatusRow(title: "辅助功能（输入控制）", granted: accessibility,
                                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                PermissionStatusRow(title: "屏幕录制", granted: screenRecording,
                                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            } footer: {
                Text("这是 LingXiAgent 本身获得的系统授权；桌面操作工具仍由 Core 的权限策略逐次审批。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("computer.permissions")

            // Core answers what these tools are; the window only renders it.
            LXSettingsCard(title: LXSettingsSectionHeader("Computer Use")) {
                toolRows(["computer_batch"])
            }

            LXSettingsCard(title: LXSettingsSectionHeader("浏览器")) {
                toolRows(["browser_navigate", "browser_act"])
            }
        }
    }

    @ViewBuilder private func toolRows(_ ids: [String]) -> some View {
        ForEach(ids, id: \.self) { id in
            if let entry = store.toolStatus?[id] {
                LabeledContent(id) {
                    LXStatusText(Self.exposureText(entry), systemImage: Self.exposureImage(entry),
                                 tone: Self.exposureTone(entry))
                }
                .lxSettingsRow()
                let detail = Self.detailText(entry)
                if !detail.isEmpty { PlaceholderLine(detail) }
            } else {
                LabeledContent(id) {
                    LXStatusText(store.toolStatus == nil ? "尚未从 Core 读取" : "Core 未报告该工具",
                                 systemImage: "questionmark.circle", tone: .neutral)
                }
                .lxSettingsRow()
            }
        }
    }

    private static func exposureText(_ entry: ToolStatusEntry) -> String {
        switch entry.exposure {
        case .core: return "默认可用"
        case .onDemand: return "按需加载"
        case .unavailable: return "未注册"
        }
    }

    private static func exposureImage(_ entry: ToolStatusEntry) -> String {
        switch entry.exposure {
        case .core: return "checkmark.circle"
        case .onDemand: return "circle.dashed"
        case .unavailable: return "xmark.circle"
        }
    }

    private static func exposureTone(_ entry: ToolStatusEntry) -> LXStatusText.Tone {
        switch entry.exposure {
        case .core: return .success
        case .onDemand: return .neutral
        case .unavailable: return .warning
        }
    }

    private static func detailText(_ entry: ToolStatusEntry) -> String {
        var parts: [String] = []
        if entry.exposure == .onDemand { parts.append("不在默认工具列表，模型先调用 load_tool 载入") }
        if let permission = entry.permission {
            parts.append(permission == .allow ? "权限：自动允许"
                    : permission == .ask ? "权限：每次询问" : "权限：拒绝")
        }
        if let detail = entry.backendDetail {
            parts.append(entry.backendReady ? "后端：\(detail)" : "后端不可用：\(detail)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool
    let settingsURL: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                // Only the glyph carries the status colour; the words stay primary.
                LXStatusText(granted ? "已授权" : "未授权",
                             systemImage: granted ? "checkmark.circle" : "xmark.circle",
                             tone: granted ? .success : .warning)
                if !granted, let url = URL(string: settingsURL) {
                    Button("打开系统设置") { NSWorkspace.shared.open(url) }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                }
            }
        }
        .lxSettingsRow()
    }
}

struct AboutSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            SettingsContentColumn {
                // The one display title on this page, beside the official icon.
                HStack(spacing: LingXiMetrics.Space.lg) {
                    LXAppIcon(side: 64)
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                        Text("LingXiAgent")
                            .font(LXType.display)
                            .foregroundStyle(.primary)
                        Text("LingXiAgent · 次世代智能体研发工作台")
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, LingXiMetrics.Space.xxl)

                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                    LXSettingsCard("系统规格") {
                        ValueRow(title: "应用版本", value: appVersion)
                        ValueRow(title: "协议版本",
                                 value: store.runtimeInfo.map { "\($0.protocolVersion)" } ?? "未连接 Core 时不可知")
                        ValueRow(title: "本地架构", value: Self.nativeArchitecture)
                        ValueRow(title: "核心状态", value: store.client != nil ? "Core 已连接" : "Core 未连接")
                    }
                }
            }
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.bottom, LingXiMetrics.Space.xxxl)
        }
    }

    /// Read from the built bundle, never typed in here.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (version?, release?): return "\(version) (\(release))"
        case let (version?, nil): return version
        default: return "—"
        }
    }

    private static var nativeArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }
}
#endif
