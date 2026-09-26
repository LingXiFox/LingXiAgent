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

    var body: some View {
        LXSettingsScrollPage(title: pageHeaderTitle, subtitle: pageHeaderSubtitle) {
            ForEach(kinds, id: \.self) { kind in
                let items = store.extensions.filter { $0.kind == kind }
                LXSettingsCard(title(kind),
                               subtitle: kind == .mcp
                                   ? "新增或修改服务器请编辑 mcp.json（「通用 › 配置文件」），然后重新加载。"
                                   : nil,
                               rowSpacing: 0,
                               accessory: {
                    if kind == kinds.first {
                        Button("重新加载") { Task { await store.reloadExtensions() } }
                            .controlSize(.small)
                            .disabled(store.client == nil)
                            .settingsAnchor("mcp.reload")
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
                .settingsAnchor(kind == .mcp ? "mcp.list" : "extensions.list")
            }
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
        case .mcp: return "查看 Core 加载的 MCP 服务器，控制各服务器的启用状态。"
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

    var isReady: Bool {
        let s = ext.lifecycleState.lowercased()
        return s.contains("ready") || s.contains("active") || s.contains("running") || (ext.enabled && !s.contains("fail") && !s.contains("err"))
    }

    var isError: Bool {
        let s = ext.lifecycleState.lowercased()
        return s.contains("fail") || s.contains("err") || s.contains("deg")
    }

    /// §1: colour lands on the 6pt dot only — the state text stays text-primary.
    var dotColor: Color {
        if !ext.enabled { return LXColor.separator }
        if isError { return LXStatus.error }
        if isReady { return LXStatus.success }
        return LXStatus.running
    }

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

            LXSettingsCard("Worktree",
                           subtitle: "Core 还没有实现 workspace.worktree.* 接口，因此这里不会有真实数据。",
                           rowSpacing: 0,
                           accessory: {
                Button("清理失效…") { confirmPrune = true }
                    .controlSize(.small)
                    .disabled(true)
                    .help("Core 尚未实现 Worktree 接口")
            }) {
                if store.worktrees.isEmpty {
                    PlaceholderLine("Worktree 能力尚未由 Core 提供；列表恒为空不代表没有 Worktree。")
                        .lxSettingsRow()
                }
                ForEach(Array(store.worktrees.enumerated()), id: \.element.id) { index, tree in
                    if index > 0 { LXSettingsDivider() }
                    HStack(spacing: LingXiMetrics.Space.md) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(LXType.body)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                            Text(tree.branch)
                                .font(LXType.monoSmall)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(tree.path)
                                .font(LXType.monoSmall)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: LingXiMetrics.Space.md)
                        if tree.isActive {
                            LXBadge("使用中", kind: .outline)
                        }
                        Text(tree.createdAt, style: .relative)
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                    }
                    .lxSettingsRow()
                }
            }
            .settingsAnchor("workspace.worktrees")
            .confirmationDialog("清理失效的 Worktree？", isPresented: $confirmPrune) {
                Button("清理", role: .destructive) { Task { await store.pruneWorktrees() } }
            } message: {
                Text("只移除 Git 已记录为失效的 Worktree 元数据，不删除仍在使用的目录。")
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var copied = false

    var body: some View {
        LXSettingsScrollPage(title: "诊断",
                             subtitle: "Core 运行时状态、后台任务与诊断工具。") {
            LXSettingsCard("运行时",
                           rowSpacing: LingXiMetrics.Space.md,
                           accessory: {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    Button("刷新") { Task { await store.refresh() } }
                        .controlSize(.small)
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
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .lxSettingsRow()
                }
            }
            .settingsAnchor("diagnostics.background")

            LXSettingsCard("工具",
                           subtitle: "诊断包包含配置摘要、近期错误、运行与 trace，分享前请自行检查。") {
                LabeledContent("诊断包") {
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.client == nil)
                }
                .lxSettingsRow()
                .settingsAnchor("diagnostics.bundle")

                LabeledContent("配置") {
                    Button("让 Core 重新加载") { Task { await store.reloadConfiguration() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.client == nil)
                }
                .lxSettingsRow()
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
/// its child, so macOS attributes them to LingXi) and the frozen status Core
/// declares for its desktop / browser tools. No toggles for disabled capabilities.
struct ComputerUseSettingsPage: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            LXSettingsPageHeader(title: "Computer Use 与浏览器",
                                 subtitle: "LingXi 获得的系统权限，与 Core 中桌面、浏览器工具的当前状态。")
                .padding(.bottom, LingXiMetrics.Space.xl)

            Section {
                PermissionStatusRow(title: "辅助功能（输入控制）", granted: accessibility,
                                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                PermissionStatusRow(title: "屏幕录制", granted: screenRecording,
                                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            } header: {
                HStack {
                    LXSettingsSectionHeader("系统权限")
                    Spacer()
                    Button("重新检测") {
                        accessibility = AXIsProcessTrusted()
                        screenRecording = CGPreflightScreenCaptureAccess()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                Text("这是 LingXi 本身获得的系统授权；桌面操作工具仍由 Core 的权限策略逐次审批。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("computer.permissions")

            // Core: BuiltinTools removes computer_batch / browser_* from the default tool list
            // ("frozen and disabled per owner directive").
            Section {
                LabeledContent("状态") {
                    LXStatusText("已冻结", systemImage: "snowflake", tone: .neutral)
                }
                .lxSettingsRow()
                PlaceholderLine("computer_batch 已从 Core 默认工具列表移除。解冻并提供允许应用与确认策略契约前，不提供开关。")
            } header: {
                LXSettingsSectionHeader("Computer Use")
            }

            Section {
                LabeledContent("状态") {
                    LXStatusText("已冻结", systemImage: "snowflake", tone: .neutral)
                }
                .lxSettingsRow()
                PlaceholderLine("browser_navigate / browser_act 已冻结，与桌面 Computer Use 分开管理；会话、Cookie、下载与站点权限待解冻后接入。")
            } header: {
                LXSettingsSectionHeader("浏览器")
            }
        }
        .lxSettingsFormChrome()
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
                        .buttonStyle(.link)
                }
            }
        }
        .lxSettingsRow()
    }
}

struct AboutSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            // 关于页的居中品牌块即页面头部：标题 + 一行说明。
            VStack(spacing: LingXiMetrics.Space.xl) {
                ZStack {
                    Circle()
                        .fill(LXColor.fillQuinary)
                        .frame(width: 96, height: 96)
                        .overlay {
                            Circle()
                                .strokeBorder(LXColor.separator, lineWidth: 1)
                        }
                    // Fox orange lands here and only here on this page: the mark,
                    // never the background.
                    Image(systemName: "flame.fill")
                        .font(LXType.display)
                        .foregroundStyle(LXColor.accentText)
                }

                VStack(spacing: LingXiMetrics.Space.sm) {
                    Text("LingXi Agent")
                        .font(LXType.title)
                        .foregroundStyle(.primary)
                    Text("LingXiAgent · 次世代智能体研发工作台")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, LingXiMetrics.Space.xxxl)
            .padding(.bottom, LingXiMetrics.Space.xxl)

            Section {
                ValueRow(title: "应用版本", value: appVersion)
                ValueRow(title: "协议版本",
                         value: store.runtimeInfo.map { "\($0.protocolVersion)" } ?? "未连接 Core 时不可知")
                ValueRow(title: "本地架构", value: Self.nativeArchitecture)
                ValueRow(title: "核心状态", value: store.client != nil ? "Core 已连接" : "Core 未连接")
            } header: {
                LXSettingsSectionHeader("系统规格")
            }

            Section {
                LabeledContent("准则", value: "以认真查询为荣，以遵循规范为荣。")
                    .lxSettingsRow()
                LabeledContent("专属标识", value: "Crafted for high-performance agentic engineering.")
                    .lxSettingsRow()
            } header: {
                LXSettingsSectionHeader("赛博契约")
            }
        }
        .lxSettingsFormChrome()
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
