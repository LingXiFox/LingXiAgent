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
            // Inspector Header
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
            .padding(.bottom, LingXiMetrics.Space.xs)

            // Segmented Tab Picker
            Picker("监控分栏", selection: $model.selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LingXiMetrics.Split.panelContentInset)
            .padding(.bottom, LingXiMetrics.Space.sm)

            Divider()

            // Tab Content: Strict Single-Tab Rendering
            if let live = model.live {
                ScrollView {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
                        switch model.selectedTab {
                        case .overview:
                            OverviewTab(live: live)
                        case .core:
                            CoreTab(live: live, onCompact: onCompact)
                        case .tasks:
                            TasksTab(live: live, onTerminate: onTerminateTask)
                        case .agents:
                            AgentsTab(live: live)
                        case .changes:
                            ChangesTab(live: live)
                        }
                    }
                    .padding(LingXiMetrics.Split.panelContentInset)
                }
            } else {
                ContentUnavailableView("未连接 Core", systemImage: "bolt.horizontal.circle",
                                       description: Text("打开工作区后，这里显示运行状态、上下文与任务。"))
                    .frame(maxHeight: .infinity)
            }

            Divider()

            // Inspector Bottom Bar
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
            .padding(.vertical, LingXiMetrics.Space.sm)
        }
    }
}

// MARK: - Metric Tile

private struct MetricTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var subtitle: String? = nil
    var systemImage: String? = nil
    var tint: Color = LingXiTheme.neonTeal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.lxMeta.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.lxMeta)
                        .foregroundStyle(.secondary)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LingXiMetrics.Space.sm)
        .lxInsetBlock()
    }
}

// MARK: - Token Stacked Bar

private struct TokenStackedBarView: View {
    let prompt: Int
    let completion: Int
    let cache: Int

    private var total: Int { prompt + completion + cache }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            HStack {
                Text("Token 分布")
                    .font(.lxCallout)
                    .foregroundStyle(.primary)
                Spacer()
                Text("共 \(tokens(total) ?? "0")")
                    .font(.lxMono.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        if cache > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LingXiTheme.foxfireAmber)
                                .frame(width: max(4, geo.size.width * CGFloat(cache) / CGFloat(total)))
                                .help("缓存读取: \(tokens(cache) ?? "")")
                        }
                        if prompt > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LingXiTheme.electricCyan)
                                .frame(width: max(4, geo.size.width * CGFloat(prompt) / CGFloat(total)))
                                .help("输入: \(tokens(prompt) ?? "")")
                        }
                        if completion > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LingXiTheme.neonTeal)
                                .frame(width: max(4, geo.size.width * CGFloat(completion) / CGFloat(total)))
                                .help("生成输出: \(tokens(completion) ?? "")")
                        }
                    }
                }
                .frame(height: 8)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 4))

                // Compact Legend
                HStack(spacing: LingXiMetrics.Space.sm) {
                    if cache > 0 {
                        LegendDot(label: "缓存", value: tokens(cache), color: LingXiTheme.foxfireAmber)
                    }
                    if prompt > 0 {
                        LegendDot(label: "输入", value: tokens(prompt), color: LingXiTheme.electricCyan)
                    }
                    if completion > 0 {
                        LegendDot(label: "输出", value: tokens(completion), color: LingXiTheme.neonTeal)
                    }
                }
            } else {
                Text("暂无 Token 消耗")
                    .font(.lxMeta)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(LingXiMetrics.Space.sm)
        .lxInsetBlock()
    }
}

private struct LegendDot: View {
    let label: String
    let value: String?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label) \(value ?? "0")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared rows

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

// MARK: - Overview Tab

private struct OverviewTab: View {
    let live: InspectorSnapshot

    var body: some View {
        // 1. Performance Metric Tiles
        HStack(spacing: LingXiMetrics.Space.sm) {
            MetricTile(
                title: "首字延迟 (TTFT)",
                value: live.lastMetrics?.firstTokenMs.map { DurationText.format(milliseconds: $0) } ?? "—",
                subtitle: live.lastMetrics?.firstTokenMs != nil ? "响应耗时" : "等待生成",
                systemImage: "bolt.horizontal.fill",
                tint: LingXiTheme.neonTeal
            )
            MetricTile(
                title: "生成速率",
                value: live.lastMetrics?.tokenRate.map { String(format: "%.1f", $0) } ?? "—",
                unit: live.lastMetrics?.tokenRate != nil ? "tok/s" : nil,
                subtitle: live.lastMetrics?.tokenRate != nil ? "实时流式" : "空闲",
                systemImage: "gauge.with.dots.needle.bottom.50percent",
                tint: LingXiTheme.electricCyan
            )
        }

        // 2. Context Linear Progress Gauge
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("上下文窗口", systemImage: "chart.bar.xaxis")
                    .font(.lxCallout)
                    .foregroundStyle(.primary)
                Spacer()
                Text(contextUsage ?? "—")
                    .font(.lxMono.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let fraction = contextFraction {
                Gauge(value: fraction) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(fraction > 0.85 ? LingXiTheme.neonCoral : fraction > 0.65 ? LingXiTheme.foxfireAmber : LingXiTheme.neonTeal)
                .labelsHidden()
                .accessibilityLabel("上下文占用 \(Int(fraction * 100))%")

                HStack {
                    Text("已占用 \(Int(fraction * 100))%")
                        .font(.lxMeta)
                        .foregroundStyle(fraction > 0.85 ? LingXiTheme.neonCoral : .secondary)
                    Spacer()
                    if let budget = live.contextPolicy?.addressableBudget {
                        Text("预算上限 \(tokens(budget) ?? "")")
                            .font(.lxMeta)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(LingXiMetrics.Space.sm)
        .lxInsetBlock()

        // 3. Token Compact Stacked Bar
        TokenStackedBarView(
            prompt: live.context?.providerCache?.promptTokens ?? 0,
            completion: max(0, (live.lastMetrics?.totalTokens ?? 0) - (live.context?.providerCache?.promptTokens ?? 0)),
            cache: live.context?.providerCache?.cacheReadTokens ?? 0
        )

        Divider()

        // 4. Runtime & Model Details
        LXSection("运行状态") {
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
                MetricRow(label: "思考模式", value: live.reasoning)
                MetricRow(label: "权限预设", value: live.permission.isEmpty ? nil : live.permission)
                MetricRow(label: "Provider 状态", value: live.providerState.map(providerLabel),
                          tint: live.providerState == .rateLimited || live.providerState == .failed ? .orange : nil)
                if let tool = live.activeTools.first {
                    MetricRow(label: "当前工具", value: live.activeTools.count > 1 ? "\(tool) +\(live.activeTools.count - 1)" : tool,
                              monospaced: true)
                }
                if let pending = live.pendingInteraction {
                    MetricRow(label: "等待交互", value: pending == "permission" ? "权限审批" : "用户回答", tint: .orange)
                }
                if let task = live.backgroundTasks.first(where: { $0.status == .running }) {
                    MetricRow(label: "后台任务", value: task.description ?? task.command, monospaced: true)
                }
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

// MARK: - Core Tab

private struct CoreTab: View {
    let live: InspectorSnapshot
    var onCompact: () -> Void

    var body: some View {
        // 1. P-Core Meter
        LXSection("P-Core (主上下文)", accessory: {
            Button("立即压缩", action: onCompact)
                .buttonStyle(.borderless)
                .font(.lxMeta)
                .help("触发上下文压缩")
        }) {
            VStack(spacing: LingXiMetrics.Space.xs) {
                let p = live.context?.pCore
                let used = p?.usedTokens ?? live.context?.estimatedTokens ?? 0
                let target = p?.targetTokens ?? live.contextPolicy?.addressableBudget ?? 1
                let fraction = target > 0 ? min(1.0, Double(used) / Double(target)) : 0.0

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("工作集占用")
                            .font(.lxCallout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(tokens(used) ?? "0") / \(tokens(target) ?? "0")")
                            .font(.lxMono.weight(.medium))
                    }
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(fraction > 0.85 ? LingXiTheme.neonCoral : LingXiTheme.neonTeal)
                        .labelsHidden()
                }
                .padding(LingXiMetrics.Space.sm)
                .lxInsetBlock()

                VStack(spacing: 0) {
                    MetricRow(label: "软限 / 硬限", value: p.map { "\(tokens($0.softLimitTokens) ?? "—") / \(tokens($0.hardLimitTokens) ?? "—")" })
                    MetricRow(label: "前缀保护稳定度", value: live.context?.structuralPrefixStability.map { String(format: "%.0f%%", $0 * 100) } ?? "已就绪")
                    MetricRow(label: "可寻址预算", value: tokens(live.contextPolicy?.addressableBudget))
                    MetricRow(label: "压缩代数", value: live.context.map { "\($0.compactionGeneration)" })
                }
            }
        }

        Divider()

        // 2. E-Core Meter
        LXSection("E-Core (分级记忆与索引)") {
            VStack(spacing: LingXiMetrics.Space.xs) {
                let e = live.context?.eCore
                HStack(spacing: LingXiMetrics.Space.sm) {
                    MetricTile(
                        title: "对象数量",
                        value: e.map { "\($0.objectCount)" } ?? "0",
                        subtitle: "结构化记忆",
                        systemImage: "cylinder.split.1x2",
                        tint: LingXiTheme.neonTeal
                    )
                    MetricTile(
                        title: "存储体积",
                        value: e.map { ByteCountFormatter.string(fromByteCount: Int64($0.totalBytes), countStyle: .memory) } ?? "0 B",
                        subtitle: "内存占用",
                        systemImage: "internaldrive",
                        tint: LingXiTheme.electricCyan
                    )
                }

                VStack(spacing: 0) {
                    MetricRow(label: "热对象 / 冷对象", value: e.flatMap { e in
                        guard let hot = e.hotObjectCount, let cold = e.coldObjectCount else { return nil }
                        return "\(hot) / \(cold)"
                    })
                    MetricRow(label: "存储预算", value: tokens(live.contextPolicy?.eCoreStorageBudget))
                }
            }
        }

        Divider()

        // 3. Provider Cache Efficiency Meter
        LXSection("Provider 缓存效率") {
            VStack(spacing: LingXiMetrics.Space.xs) {
                let cache = live.context?.providerCache
                let read = cache?.cacheReadTokens ?? 0
                let prompt = cache?.promptTokens ?? 0
                let hitRatio: Double? = (read + prompt > 0) ? Double(read) / Double(read + prompt) : nil

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("缓存命中率")
                            .font(.lxCallout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(hitRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                            .font(.lxMono.weight(.bold))
                            .foregroundStyle(hitRatio != nil && hitRatio! > 0.5 ? LingXiTheme.neonTeal : .primary)
                    }
                    if let ratio = hitRatio {
                        Gauge(value: ratio) { EmptyView() }
                            .gaugeStyle(.linearCapacity)
                            .tint(LingXiTheme.neonTeal)
                            .labelsHidden()
                    }
                }
                .padding(LingXiMetrics.Space.sm)
                .lxInsetBlock()

                VStack(spacing: 0) {
                    MetricRow(label: "缓存状态", value: cache?.cacheStatus)
                    MetricRow(label: "读取 Token", value: tokens(read))
                    MetricRow(label: "Prompt Token", value: tokens(prompt))
                    MetricRow(label: "Cache Debt", value: cache?.cacheDebt.map { "\($0)" })
                }
            }
        }

        Divider()

        // 4. Advanced Strategies Disclosure Group
        DisclosureGroup("高级缓存与架构策略") {
            VStack(spacing: 0) {
                let cache = live.context?.providerCache
                MetricRow(label: "Cache Epoch", value: cache?.cacheEpoch.map { e in [String(e), cache?.epochReason].compactMap { $0 }.joined(separator: " · ") })
                MetricRow(label: "稳定前缀 Hash", value: cache?.stablePrefixHash, monospaced: true)
                MetricRow(label: "客户端健康状态", value: cache?.clientHealthStatus)
                MetricRow(label: "前缀破坏率", value: live.context?.clientCausedBustRate.map { String(format: "%.1f%%", $0 * 100) })
                MetricRow(label: "挥发性尾部字节", value: live.context?.volatileTailBytes.map { "\($0) B" })
                if let c = live.compaction {
                    MetricRow(label: "上次压缩记录", value: "\(tokens(c.beforeTokens) ?? "") → \(tokens(c.afterTokens) ?? "") · \(c.triggerSource)")
                }
                if let miss = cache?.missDiagnostics, !miss.isEmpty {
                    Text(miss)
                        .font(.lxMeta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(.top, LingXiMetrics.Space.xs)
        }
        .font(.lxCallout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Tasks Tab

private struct TasksTab: View {
    let live: InspectorSnapshot
    var onTerminate: (String) -> Void

    private var completedTodosCount: Int {
        live.todos.filter { $0.status == "completed" }.count
    }

    private var todoProgress: Double {
        guard !live.todos.isEmpty else { return 0 }
        return Double(completedTodosCount) / Double(live.todos.count)
    }

    var body: some View {
        // 1. Overall Task Progress Gauge
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("任务清单进度", systemImage: "checklist")
                    .font(.lxCallout)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(completedTodosCount) / \(live.todos.count)")
                    .font(.lxMono.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !live.todos.isEmpty {
                Gauge(value: todoProgress) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(LingXiTheme.neonTeal)
                    .labelsHidden()

                HStack {
                    Text("已完成 \(Int(todoProgress * 100))%")
                        .font(.lxMeta)
                        .foregroundStyle(completedTodosCount == live.todos.count ? LingXiTheme.neonTeal : .secondary)
                    Spacer()
                }
            }
        }
        .padding(LingXiMetrics.Space.sm)
        .lxInsetBlock()

        // 2. Todo Items List
        LXSection("待办事项") {
            if live.todos.isEmpty {
                PlaceholderLine("Agent 还没有创建待办任务。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    ForEach(live.todos, id: \.id) { todo in
                        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
                            Image(systemName: todoSymbol(todo.status))
                                .foregroundStyle(todoTint(todo.status))
                                .font(.system(size: 13))
                            Text(todo.title)
                                .font(.lxCallout)
                                .strikethrough(todo.status == "completed")
                                .foregroundStyle(todo.status == "completed" ? .tertiary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }

        Divider()

        // 3. Workflows
        LXSection("工作流 (Workflow)") {
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

        // 4. Background Tasks
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

// MARK: - Agents Tab

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

// MARK: - Changes Tab

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

func statusLabel(_ status: ProductRuntimeStatus) -> String {
    switch status {
    case .ready: return "空闲"
    case .thinking: return "思考中"
    case .waitingForProvider: return "等待模型"
    case .rateLimited: return "限流中"
    case .runningTool: return "执行工具"
    case .runningSubagents: return "子 Agent 运行中"
    case .paging: return "上下文换页"
    case .actionRequired: return "等待操作"
    case .reconnecting: return "重连中"
    case .disconnected: return "未连接"
    case .error: return "错误"
    }
}

private func providerLabel(_ state: ProviderRequestState) -> String {
    switch state {
    case .scheduled: return "已排队"
    case .waitingForRateBudget: return "等待预算"
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

#endif
