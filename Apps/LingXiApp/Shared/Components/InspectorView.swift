#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
import LingXiApplication

/// Runtime Inspector — "what is happening inside the agent right now".
/// Read-only observability in five tabs; every value comes from `ApplicationState`,
/// and a value Core does not expose is labelled unavailable rather than guessed.
public struct InspectorView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel
    public var onOpenTraceWindow: () -> Void
    public var onRefresh: () -> Void
    public var onCompact: () -> Void
    public var onTerminateTask: (String) -> Void

    public init(model: RuntimeInspectorPresentationModel,
                onOpenTraceWindow: @escaping () -> Void = {},
                onRefresh: @escaping () -> Void = {},
                onCompact: @escaping () -> Void = {},
                onTerminateTask: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onOpenTraceWindow = onOpenTraceWindow
        self.onRefresh = onRefresh
        self.onCompact = onCompact
        self.onTerminateTask = onTerminateTask
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unified Inspector Header
            HStack(spacing: LingXiMetrics.Space.sm) {
                Label("实时监控", systemImage: "waveform.path.ecg")
                    .font(.lxCallout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let live = model.live {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(live.status == .ready ? LingXiTheme.neonTeal : LingXiTheme.foxfireAmber)
                            .frame(width: 7, height: 7)
                            .lxNeonGlow(color: live.status == .ready ? LingXiTheme.neonTeal : LingXiTheme.foxfireAmber, radius: 4)
                        Text(statusLabel(live.status))
                            .font(.lxMeta)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
            .padding(.top, LingXiMetrics.Space.md)
            .padding(.bottom, LingXiMetrics.Space.sm)

            if let live = model.live {
                ScrollView {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
                        // 1. 运行状态与模型 (Overview)
                        OverviewTab(live: live)

                        Divider()

                        // 2. 核心双核架构与缓存 (Core Context: P-Core, E-Core, Cache)
                        CoreTab(live: live, onCompact: onCompact)

                        Divider()

                        // 3. 任务与待办 (Tasks)
                        TasksTab(live: live, onTerminate: onTerminateTask)

                        if !live.subagents.isEmpty {
                            Divider()
                            AgentsTab(live: live)
                        }
                    }
                    .padding(LingXiMetrics.Split.panelContentInset)
                }
            } else {
                ContentUnavailableView("未连接 Core", systemImage: "bolt.horizontal.circle",
                                       description: Text("打开工作区后，这里显示运行状态、上下文与任务。"))
                    .frame(maxHeight: .infinity)
            }

            HStack(spacing: LingXiMetrics.Space.md) {
                Button(action: onOpenTraceWindow) {
                    Label("运行轨迹", systemImage: "waveform.path.ecg")
                }
                .keyboardShortcut("l", modifiers: [.option, .command])
                .help("打开独立运行轨迹窗口 (⌥⌘L)")
                Spacer(minLength: 0)
                if model.live != nil {
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .help("刷新诊断与工作区变更")
                }
            }
            .buttonStyle(.borderless)
            .font(.lxCallout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
            .padding(.vertical, LingXiMetrics.Space.md)
        }
    }
}

// MARK: - Shared rows

/// Label / value row; a missing value shows an explicit dash, never a guess.
private struct MetricRow: View {
    let label: String
    let value: String?
    var monospaced = false
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
            Text(label).font(.lxCallout).foregroundStyle(.secondary)
            Spacer(minLength: LingXiMetrics.Space.sm)
            Text(value ?? "—")
                .font(monospaced ? .lxMono : .lxCallout)
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint ?? .primary))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(minHeight: LingXiMetrics.Row.event)
        .accessibilityElement(children: .combine)
    }
}

private func tokens(_ n: Int?) -> String? {
    guard let n else { return nil }
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

// MARK: - Overview

private struct OverviewTab: View {
    let live: InspectorSnapshot

    var body: some View {
        LXSection("当前运行") {
            VStack(spacing: 0) {
                MetricRow(label: "状态", value: statusLabel(live.status), tint: statusTint)
                if let start = live.runStartedAt {
                    if live.status.isActiveRun {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            MetricRow(label: "已运行", value: DurationText.format(milliseconds: Date().timeIntervalSince(start) * 1000))
                        }
                    } else {
                        MetricRow(label: "已运行", value: DurationText.format(milliseconds: Date().timeIntervalSince(start) * 1000))
                    }
                }
                MetricRow(label: "模型", value: live.modelID, monospaced: true)
                MetricRow(label: "思考", value: live.reasoning)
                MetricRow(label: "权限", value: live.permission.isEmpty ? nil : live.permission)
                MetricRow(label: "Provider", value: live.providerState.map(providerLabel),
                          tint: live.providerState == .rateLimited || live.providerState == .failed ? .orange : nil)
                if let tool = live.activeTools.first {
                    MetricRow(label: "当前工具", value: live.activeTools.count > 1 ? "\(tool) +\(live.activeTools.count - 1)" : tool,
                              monospaced: true)
                }
                if let pending = live.pendingInteraction {
                    MetricRow(label: "等待", value: pending == "permission" ? "权限审批" : "用户回答", tint: .orange)
                }
                if let task = live.backgroundTasks.first(where: { $0.status == .running }) {
                    MetricRow(label: "后台任务", value: task.description ?? task.command, monospaced: true)
                }
            }
        }

        Divider()

        LXSection("用量") {
            VStack(spacing: 0) {
                MetricRow(label: "上下文", value: contextUsage)
                MetricRow(label: "本轮 Token", value: tokens(live.lastMetrics?.totalTokens))
                MetricRow(label: "缓存读取", value: tokens(live.context?.cacheReadTokens))
                MetricRow(label: "首 Token", value: live.lastMetrics?.firstTokenMs.map { DurationText.format(milliseconds: $0) })
                MetricRow(label: "生成速率", value: live.lastMetrics?.tokenRate.map { String(format: "%.1f tok/s", $0) })
            }
            if let fraction = contextFraction {
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(fraction > 0.85 ? .red : fraction > 0.65 ? .orange : LingXiTheme.tertiaryText)
                    .labelsHidden()
                    .accessibilityLabel("上下文占用 \(Int(fraction * 100))%")
            }
        }
    }

    private var contextFraction: Double? {
        guard let used = live.context?.estimatedTokens, let budget = live.contextPolicy?.addressableBudget, budget > 0 else { return nil }
        return min(1, Double(used) / Double(budget))
    }

    private var contextUsage: String? {
        guard let used = live.context?.estimatedTokens else { return nil }
        return [tokens(used), tokens(live.contextPolicy?.addressableBudget)].compactMap { $0 }.joined(separator: " / ")
    }

    private var statusTint: Color? {
        switch live.status {
        case .error, .disconnected: return .red
        case .actionRequired, .rateLimited, .reconnecting: return .orange
        default: return nil
        }
    }
}

func statusLabel(_ status: ProductRuntimeStatus) -> String {
    switch status {
    case .ready: return "空闲"
    case .thinking: return "思考中"
    case .waitingForProvider: return "等待模型"
    case .rateLimited: return "限流中"
    case .runningTool: return "执行工具"
    case .runningSubagents: return "子 Agent 运行中"
    case .paging: return "上下文换页"
    case .actionRequired: return "等待你的操作"
    case .reconnecting: return "重连中"
    case .disconnected: return "未连接"
    case .error: return "错误"
    }
}

private func providerLabel(_ state: ProviderRequestState) -> String {
    switch state {
    case .scheduled: return "已排队"
    case .waitingForRateBudget: return "等待速率预算"
    case .requesting: return "请求中"
    case .streaming: return "流式输出"
    case .rateLimited: return "限流"
    case .retryScheduled: return "等待重试"
    case .completed: return "完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    case .unknown: return "未知"
    }
}

// MARK: - Core

private struct CoreTab: View {
    let live: InspectorSnapshot
    var onCompact: () -> Void

    var body: some View {
        LXSection("P-Core", accessory: {
            Button("压缩", action: onCompact)
                .buttonStyle(.borderless)
                .font(.lxMeta)
                .help("立即压缩当前会话上下文")
        }) {
            VStack(spacing: 0) {
                let p = live.context?.pCore
                MetricRow(label: "工作集", value: p.map { "\(tokens($0.usedTokens) ?? "—") / \(tokens($0.targetTokens) ?? "—")" })
                MetricRow(label: "软限 / 硬限", value: p.map { "\(tokens($0.softLimitTokens) ?? "—") / \(tokens($0.hardLimitTokens) ?? "—")" })
                MetricRow(label: "前缀保护", value: live.context?.structuralPrefixStability.map { String(format: "%.0f%%", $0 * 100) } ?? "已就绪")
                MetricRow(label: "可寻址预算", value: tokens(live.contextPolicy?.addressableBudget))
                MetricRow(label: "压缩代数", value: live.context.map { "\($0.compactionGeneration)" })
                if let c = live.compaction {
                    MetricRow(label: "上次压缩", value: "\(tokens(c.beforeTokens) ?? "") → \(tokens(c.afterTokens) ?? "") · \(c.triggerSource)")
                }
            }
        }

        Divider()

        LXSection("E-Core") {
            VStack(spacing: 0) {
                let e = live.context?.eCore
                MetricRow(label: "对象数", value: e.map { "\($0.objectCount)" })
                MetricRow(label: "存储体积", value: e.map { ByteCountFormatter.string(fromByteCount: Int64($0.totalBytes), countStyle: .memory) })
                MetricRow(label: "热 / 冷", value: e.flatMap { e in
                    guard let hot = e.hotObjectCount, let cold = e.coldObjectCount else { return nil }
                    return "\(hot) / \(cold)"
                })
                MetricRow(label: "存储预算", value: tokens(live.contextPolicy?.eCoreStorageBudget))
            }
        }

        Divider()

        LXSection("Provider 缓存") {
            VStack(spacing: 0) {
                let cache = live.context?.providerCache
                MetricRow(label: "状态", value: cache?.cacheStatus)
                MetricRow(label: "读取 Token", value: tokens(cache?.cacheReadTokens))
                MetricRow(label: "Prompt Token", value: tokens(cache?.promptTokens))
                MetricRow(label: "Cache Debt", value: cache?.cacheDebt.map { "\($0)" })
                MetricRow(label: "Epoch", value: cache?.cacheEpoch.map { e in [String(e), cache?.epochReason].compactMap { $0 }.joined(separator: " · ") })
                MetricRow(label: "前缀稳定度", value: live.context?.structuralPrefixStability.map { String(format: "%.0f%%", $0 * 100) })
                if let miss = cache?.missDiagnostics, !miss.isEmpty {
                    Text(miss).font(.lxMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        Divider()

        LXSection("检索与分支预测") {
            PlaceholderLine("Core 尚未提供检索遥测与 Branch Prediction 快照的前端数据契约，暂不展示。")
        }
    }
}

// MARK: - Tasks

private struct TasksTab: View {
    let live: InspectorSnapshot
    var onTerminate: (String) -> Void

    var body: some View {
        LXSection("Todo", accessory: {
            if !live.todos.isEmpty {
                Text("\(live.todos.filter { $0.status == "completed" }.count)/\(live.todos.count)")
                    .font(.lxMeta).foregroundStyle(.tertiary).monospacedDigit()
            }
        }) {
            if live.todos.isEmpty {
                PlaceholderLine("Agent 还没有创建 Todo。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    ForEach(live.todos, id: \.id) { todo in
                        Label {
                            Text(todo.title)
                                .font(.lxCallout)
                                .strikethrough(todo.status == "completed")
                                .foregroundStyle(todo.status == "completed" ? .tertiary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: todoSymbol(todo.status))
                                .foregroundStyle(todoTint(todo.status))
                        }
                    }
                }
            }
        }

        Divider()

        LXSection("Workflow") {
            if live.workflows.isEmpty {
                PlaceholderLine("没有进行中的 Workflow。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    ForEach(live.workflows, id: \.id) { flow in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(flow.id.rawValue.suffix(8)).font(.lxMono)
                                Spacer()
                                Text(flow.status.rawValue).font(.lxMeta)
                                    .foregroundStyle(flow.status == .recoveryRequired || flow.status == .failed ? Color.red : Color.secondary)
                            }
                            Text("\(flow.tasks.filter { $0.status.rawValue == "completed" }.count)/\(flow.tasks.count) 个任务")
                                .font(.lxMeta).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }

        Divider()

        LXSection("后台任务") {
            if live.backgroundTasks.isEmpty {
                PlaceholderLine("没有后台任务。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    ForEach(live.backgroundTasks, id: \.id) { task in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(task.description ?? task.command)
                                    .font(.lxMono).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: LingXiMetrics.Space.xs)
                                if task.status == .running {
                                    Button("终止") { onTerminate(task.id) }
                                        .buttonStyle(.borderless).font(.lxMeta)
                                }
                            }
                            Text([task.status.rawValue,
                                  task.pid.map { "PID \($0)" },
                                  DurationText.format(milliseconds: task.elapsedSeconds * 1000),
                                  "超时 \(task.timeoutSeconds)s",
                                  task.exitCode.map { "exit \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.lxMeta).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func todoSymbol(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted.circle"
        case "failed": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private func todoTint(_ status: String) -> AnyShapeStyle {
        switch status {
        case "completed": return AnyShapeStyle(.green)
        case "in_progress": return AnyShapeStyle(.tint)
        case "failed": return AnyShapeStyle(.red)
        default: return AnyShapeStyle(.tertiary)
        }
    }
}

// MARK: - Agents

private struct AgentsTab: View {
    let live: InspectorSnapshot

    var body: some View {
        LXSection("主 Agent") {
            if let run = live.rootRun {
                VStack(spacing: 0) {
                    MetricRow(label: "Run", value: String(run.runID.rawValue.suffix(12)), monospaced: true)
                    MetricRow(label: "状态", value: run.status.rawValue)
                    MetricRow(label: "模型", value: run.model.isEmpty ? nil : run.model, monospaced: true)
                    MetricRow(label: "开始", value: run.createdAt.formatted(date: .omitted, time: .standard))
                    MetricRow(label: "结果", value: run.terminalReason?.rawValue)
                }
            } else {
                PlaceholderLine("当前会话还没有运行。")
            }
        }

        Divider()

        LXSection("子 Agent", accessory: {
            if !live.subagents.isEmpty {
                Text("\(live.subagents.count)").font(.lxMeta).foregroundStyle(.tertiary)
            }
        }) {
            if live.subagents.isEmpty {
                PlaceholderLine("没有子 Agent。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    ForEach(live.subagents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(String(agent.runID.suffix(8)), systemImage: "person.2")
                                    .font(.lxMono)
                                Spacer()
                                Text(agent.status).font(.lxMeta)
                                    .foregroundStyle(agent.status.localizedCaseInsensitiveContains("fail") ? Color.red : Color.secondary)
                            }
                            Text(["父 \(agent.parentRunID.suffix(6))", agent.model, agent.terminalReason,
                                  agent.startedAt.map { start in
                                      DurationText.format(milliseconds: (agent.completedAt ?? Date()).timeIntervalSince(start) * 1000)
                                  }].compactMap { $0 }.joined(separator: " · "))
                                .font(.lxMeta).foregroundStyle(.tertiary)
                        }
                        .padding(.leading, LingXiMetrics.Space.md)
                    }
                }
            }
        }
    }
}

// MARK: - Changes

private struct ChangesTab: View {
    let live: InspectorSnapshot
    @State private var expanded: String?

    var body: some View {
        LXSection("工作区") {
            VStack(spacing: 0) {
                MetricRow(label: "分支", value: live.branch, monospaced: true)
                MetricRow(label: "根目录", value: live.workspaceRoot.map { URL(fileURLWithPath: $0).lastPathComponent })
            }
        }

        Divider()

        LXSection("变更文件", accessory: {
            if !live.changes.isEmpty {
                Text("+\(live.changes.reduce(0) { $0 + $1.additions }) −\(live.changes.reduce(0) { $0 + $1.deletions })")
                    .font(.lxMeta.monospacedDigit()).foregroundStyle(.secondary)
            }
        }) {
            if !live.diffLoaded {
                PlaceholderLine("尚未读取工作区变更，点底部刷新。")
            } else if live.changes.isEmpty {
                PlaceholderLine("工作区没有未提交变更。")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(live.changes) { file in
                        FileChangeRow(file: file, isOpen: expanded == file.id) {
                            expanded = expanded == file.id ? nil : file.id
                        }
                    }
                }
            }
        }
    }
}

private struct FileChangeRow: View {
    let file: FileChangePresentation
    let isOpen: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Button(action: onToggle) {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(file.change.rawValue)
                        .font(.lxMono.weight(.semibold))
                        .foregroundStyle(changeTint)
                        .frame(width: 12)
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.lxCallout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: LingXiMetrics.Space.xs)
                    if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(.green) }
                    if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(.red) }
                }
                .font(.lxMeta.monospacedDigit())
                .frame(minHeight: LingXiMetrics.Row.list)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
            .accessibilityLabel("\(file.path)，新增 \(file.additions) 行，删除 \(file.deletions) 行")

            if isOpen {
                OutputBlock(text: file.patch, isDiff: true)
            }
        }
    }

    private var changeTint: Color {
        switch file.change {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .modified: return .orange
        }
    }
}

#endif
