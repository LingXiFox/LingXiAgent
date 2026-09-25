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
        ForEach(kinds, id: \.self) { kind in
            let items = store.extensions.filter { $0.kind == kind }
            Section {
                if store.client != nil && items.isEmpty {
                    PlaceholderLine(emptyText(kind))
                }
                ForEach(items, id: \.id) { ext in
                    ExtensionRow(ext: ext) { enabled in
                        Task { await store.setExtension(ext.id, enabled: enabled) }
                    }
                    .settingsAnchor("extension.\(ext.id)")
                }
            } header: {
                HStack {
                    Text(title(kind))
                    Spacer()
                    if kind == kinds.first {
                        Button("重新加载") { Task { await store.reloadExtensions() } }
                            .disabled(store.client == nil)
                            .settingsAnchor("mcp.reload")
                    }
                }
            } footer: {
                if kind == .mcp {
                    Text("新增或修改服务器请编辑 mcp.json（「通用 › 配置文件」），然后重新加载。")
                }
            }
            .settingsAnchor(kind == .mcp ? "mcp.list" : "extensions.list")
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
}

private struct ExtensionRow: View {
    let ext: ExtensionInfo
    var onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { ext.enabled }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(ext.id).font(.body.monospaced())
                    Text("v\(ext.version)").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(ext.lifecycleState)
                        .foregroundStyle(ext.lifecycleState.lowercased().contains("fail") ? Color.red : Color.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(ext.scope).foregroundStyle(.secondary)
                    if let summary = ext.summary, !summary.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(summary).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Workspace

struct WorkspaceSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmPrune = false

    var body: some View {
        if let workspace = store.workspace {
            Section("当前工作区") {
                ValueRow(title: "根目录", value: workspace.rootPath, monospaced: true)
                ValueRow(title: "Git 仓库", value: workspace.isGitRepository ? "是" : "否")
                if let state = workspace.indexingState {
                    ValueRow(title: "代码索引", value: state)
                }
                if let nodes = workspace.codebaseNodes, let edges = workspace.codebaseEdges {
                    ValueRow(title: "图谱规模", value: "\(nodes) 节点 · \(edges) 边")
                }
            }
            .settingsAnchor("workspace.summary")
        }

        Section {
            if store.client != nil && store.worktrees.isEmpty {
                PlaceholderLine("没有活动的 Worktree。")
            }
            ForEach(store.worktrees) { tree in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(tree.branch, systemImage: "arrow.triangle.branch")
                            .font(.body.monospaced())
                        Text(tree.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if tree.isActive {
                        Text("使用中").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(tree.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack {
                Text("Worktree")
                Spacer()
                Button("清理失效…") { confirmPrune = true }
                    .disabled(store.client == nil)
            }
        } footer: {
            Text("任务在独立 Worktree 中执行，接受后才合并回工作区；合并与放弃在任务报告里完成。")
        }
        .settingsAnchor("workspace.worktrees")
        .confirmationDialog("清理失效的 Worktree？", isPresented: $confirmPrune) {
            Button("清理", role: .destructive) { Task { await store.pruneWorktrees() } }
        } message: {
            Text("只移除 Git 已记录为失效的 Worktree 元数据，不删除仍在使用的目录。")
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var copied = false

    var body: some View {
        Section {
            if store.client == nil {
                LabeledContent("Core") { ConnectCoreButton(store: store) }
            }
            if let info = store.runtimeInfo {
                ValueRow(title: "版本", value: "\(info.name) \(info.version)")
                ValueRow(title: "协议", value: "\(info.protocolVersion)")
                LabeledContent("启动于") { Text(info.startedAt, style: .relative).foregroundStyle(.secondary) }
            }
            if let health = store.health {
                LabeledContent("健康状态") {
                    Label(health.status.rawValue, systemImage: health.status == .healthy ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health.status == .healthy ? Color.secondary : Color.orange)
                }
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
        } header: {
            HStack {
                Text("运行时")
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await store.refresh() } }
                    .disabled(store.client == nil)
            }
        }
        .settingsAnchor("diagnostics.runtime")

        Section("后台任务") {
            if store.client != nil && store.backgroundTasks.isEmpty {
                PlaceholderLine("没有后台任务。")
            }
            ForEach(store.backgroundTasks, id: \.id) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.description ?? task.command)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(task.status.rawValue) · \(Int(task.elapsedSeconds))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if task.status == .running {
                        Button("终止") { Task { await store.terminateBackgroundTask(task.id) } }
                    }
                }
            }
        }
        .settingsAnchor("diagnostics.background")

        Section {
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
                .disabled(store.client == nil)
            }
            .settingsAnchor("diagnostics.bundle")

            LabeledContent("配置") {
                Button("让 Core 重新加载") { Task { await store.reloadConfiguration() } }
                    .disabled(store.client == nil)
            }
        } header: {
            Text("工具")
        } footer: {
            Text("诊断包包含配置摘要、近期错误、运行与 trace，分享前请自行检查。")
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
        Section {
            PermissionStatusRow(title: "辅助功能（输入控制）", granted: accessibility,
                                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            PermissionStatusRow(title: "屏幕录制", granted: screenRecording,
                                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        } header: {
            HStack {
                Text("系统权限")
                Spacer()
                Button("重新检测") {
                    accessibility = AXIsProcessTrusted()
                    screenRecording = CGPreflightScreenCaptureAccess()
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("这是 LingXi 本身获得的系统授权；桌面操作工具仍由 Core 的权限策略逐次审批。")
        }
        .settingsAnchor("computer.permissions")

        // Core: BuiltinTools removes computer_batch / browser_* from the default tool list
        // ("frozen and disabled per owner directive").
        Section("Computer Use") {
            LabeledContent("状态") { Label("已冻结", systemImage: "snowflake").foregroundStyle(.secondary) }
            PlaceholderLine("computer_batch 已从 Core 默认工具列表移除。解冻并提供允许应用与确认策略契约前，不提供开关。")
        }

        Section("浏览器") {
            LabeledContent("状态") { Label("已冻结", systemImage: "snowflake").foregroundStyle(.secondary) }
            PlaceholderLine("browser_navigate / browser_act 已冻结，与桌面 Computer Use 分开管理；会话、Cookie、下载与站点权限待解冻后接入。")
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool
    let settingsURL: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(granted ? Color.secondary : Color.orange)
                if !granted, let url = URL(string: settingsURL) {
                    Button("打开系统设置") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

struct AboutSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            VStack(spacing: LingXiMetrics.Space.md) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    LingXiTheme.foxfireAmber.opacity(0.35),
                                    LingXiTheme.astralViolet.opacity(0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 60
                            )
                        )
                        .frame(width: 100, height: 100)

                    Circle()
                        .strokeBorder(LingXiTheme.foxfireAmber.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 64, height: 64)

                    Image(systemName: "flame.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(LingXiTheme.foxfireAmber)
                        .lxNeonGlow(color: LingXiTheme.foxfireAmber, radius: 8, opacity: 0.8)
                }

                VStack(spacing: 2) {
                    Text("LingXi Agent")
                        .font(.lxTitle.weight(.bold))
                    Text("灵犀 · 主人的赛博智能体伴写小狐狸")
                        .font(.lxCallout)
                        .foregroundStyle(LingXiTheme.foxfireAmber)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LingXiMetrics.Space.md)
        }

        Section("系统规格") {
            LabeledContent("应用版本", value: "v1.0.0 (Release 1)")
            LabeledContent("协议版本", value: "vNext Wire 1.1")
            LabeledContent("本地架构", value: "Apple Silicon Native (arm64)")
            LabeledContent("核心状态", value: store.client != nil ? "Core 已连接" : "Core 未连接")
        }

        Section("赛博契约") {
            LabeledContent("准则", value: "以认真查询为荣，以遵循规范为荣。")
            LabeledContent("专属标识", value: "Crafted with passion in Cyber Space for 主人.")
        }
    }
}
#endif
