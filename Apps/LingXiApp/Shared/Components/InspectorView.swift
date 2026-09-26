#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
import LingXiApplication

/// Inspector — "what is the agent doing", readable in two seconds.
///
/// A 340pt bg-window panel, ring, no shadow, no ambient, no tint. Three tabs:
/// 概览 (run, context, todos, changes, agents), 变更 (per-file diffs) and
/// 上下文 (P-Core / E-Core / cache / tokens). Every number binds to
/// `InspectorSnapshot`; what Core has not reported says so in words.
public struct InspectorView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var model: RuntimeInspectorPresentationModel
    @ObservedObject private var composer: ComposerModel
    let onOpenTraceWindow: () -> Void

    public init(runtime: RuntimeFrontend, onOpenTraceWindow: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.model = runtime.inspectorModel
        self.composer = runtime.composerModel
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabs
            if let live = model.live {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch model.selectedTab {
                        case .overview:
                            OverviewTab(live: live, mode: composer.selectedMode, contextWindow: contextWindow,
                                        onTerminate: runtime.terminateBackgroundTask)
                        case .changes:
                            ChangesTab(live: live)
                        case .context:
                            ContextTab(live: live, contextWindow: contextWindow, onCompact: runtime.compactContext)
                        }
                    }
                    .padding(.horizontal, LingXiMetrics.Space.lg)
                    .padding(.bottom, LingXiMetrics.Space.md)
                }
            } else {
                ContentUnavailableView("未连接 Core", systemImage: "bolt.horizontal.circle",
                                       description: Text("打开工作区后，这里显示运行状态、上下文窗口与变更。"))
                    .frame(maxHeight: .infinity)
            }
            footer
        }
        .lxPanel(LXColor.window)
        .padding([.bottom, .trailing], LingXiMetrics.Space.sm)
    }

    /// The selected model's context window from its catalog metadata.
    private var contextWindow: Int? {
        guard let id = model.live?.modelID ?? composer.selectedModelID else { return nil }
        return composer.models.first { $0.id == id || $0.modelID == id }?.contextWindow
    }

    /// Text tabs: 24 tall, radius-sm, meta; selected = fill-control + primary medium.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                let isOn = model.selectedTab == tab
                Button { model.selectedTab = tab } label: {
                    Text(tab.displayName)
                        .font(LXType.meta.weight(isOn ? .medium : .regular))
                        .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 10)
                        .frame(height: LXControl.tab)
                        .background(isOn ? LXColor.fillControl : .clear,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.top, LingXiMetrics.Space.md)
        .padding(.bottom, LingXiMetrics.Space.sm)
    }

    private var footer: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Button(action: onOpenTraceWindow) {
                Label("运行轨迹", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(LXButtonStyle(.plain, size: .small))
            .help("打开运行轨迹窗口 (⌥⌘L)")
            Spacer(minLength: 0)
            if model.live != nil {
                Button(action: runtime.refreshRuntimeDetails) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                .help("刷新诊断与工作区变更")
                .accessibilityLabel("刷新")
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .overlay(alignment: .top) { LXHairline() }
    }
}

// MARK: - Formatting

private let notReported = "未上报"

private func tokens(_ n: Int?) -> String {
    guard let n else { return notReported }
    func compact(_ v: Double) -> String {
        let s = String(format: v >= 100 ? "%.0f" : "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
    if n >= 1_000_000 { return compact(Double(n) / 1_000_000) + "M" }
    if n >= 1_000 { return compact(Double(n) / 1_000) + "K" }
    return "\(n)"
}

private func percent(_ fraction: Double) -> String {
    let value = min(1, max(0, fraction)) * 100
    return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
}

func statusLabel(_ status: ProductRuntimeStatus) -> String {
    switch status {
    case .ready: return "空闲"
    case .thinking: return "思考中"
    case .waitingForProvider: return "等待模型"
    case .rateLimited: return "限流中"
    case .runningTool: return "执行中"
    case .runningSubagents: return "子 Agent 运行中"
    case .paging: return "上下文换页"
    case .actionRequired: return "需要你处理"
    case .reconnecting: return "重连中"
    case .disconnected: return "未连接"
    case .error: return "错误"
    }
}

/// Status = dot + label; the dot tone follows the brand status layers.
private struct RunStatusValue: View {
    let status: ProductRuntimeStatus

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            if let tone { LXActivityDot(tone: tone, accessibilityLabel: statusLabel(status)) }
            Text(statusLabel(status))
        }
    }

    private var tone: LXActivityDot.Tone? {
        switch status {
        case .ready: return nil
        case .thinking, .waitingForProvider: return .thinking
        case .runningTool, .runningSubagents, .paging: return .running
        case .actionRequired: return .accent
        case .rateLimited, .reconnecting: return .warning
        case .error, .disconnected: return .danger
        }
    }
}

/// Elapsed time; ticks each second only while running.
private struct ElapsedValue: View {
    let startedAt: Date
    let ticking: Bool

    var body: some View {
        if ticking {
            TimelineView(.periodic(from: .now, by: 1)) { _ in Text(text) }
        } else {
            Text(text)
        }
    }

    private var text: String { DurationText.format(milliseconds: Date().timeIntervalSince(startedAt) * 1000) }
}

private struct TodoRow: View {
    let todo: TodoItemData

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
            Group {
                switch todo.status {
                case "completed":
                    Image(systemName: "checkmark.circle").foregroundStyle(LXStatus.success)
                case "in_progress":
                    LXActivityDot(tone: .running).frame(width: 14)
                case "failed":
                    Image(systemName: "xmark.circle").foregroundStyle(LXStatus.error)
                case "paused":
                    Image(systemName: "pause.circle").foregroundStyle(LXStatus.warning)
                case "waiting", "blocked":
                    Image(systemName: "clock").foregroundStyle(LXStatus.warning)
                default:
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: LXIcon.status))
            .frame(width: 16)
            Text(todo.title)
                .font(LXType.meta)
                .foregroundStyle(todo.status == "pending" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FileNameRow: View {
    let file: FileChangePresentation

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                .font(LXType.monoSmall)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: LingXiMetrics.Space.sm)
            LXDiffCount(additions: file.additions, deletions: file.deletions).font(LXType.meta)
        }
        .frame(minHeight: 22)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

// MARK: - 概览

struct OverviewTab: View {
    let live: InspectorSnapshot
    let mode: AgentRunMode
    let contextWindow: Int?
    let onTerminate: (String) -> Void

    var body: some View {
        LXSection("运行状态", separated: false) {
            VStack(spacing: 0) {
                LXKVRow("状态", value: RunStatusValue(status: live.status))
                LXKVRow("模式", value: mode.rawValue)
                LXKVRow("模型", value: modelText)
                if let started = live.runStartedAt {
                    LXKVRow("已用时", value: ElapsedValue(startedAt: started, ticking: live.status.isActiveRun))
                }
                if !live.permission.isEmpty { LXKVRow("权限", value: live.permission) }
                if !live.activeTools.isEmpty {
                    LXKVRow("当前工具", value: Text(live.activeTools.joined(separator: " · ")).font(LXType.monoSmall))
                }
                if let pending = live.pendingInteraction {
                    LXKVRow("需要你处理", value: LXStatusText(pending == "permission" ? "权限审批" : "回答提问",
                                                           systemImage: "clock", tone: .warning))
                }
            }
        }

        LXSection("上下文窗口", accessory: {
            if let fraction { Text(percent(fraction)).monospacedDigit() }
        }) {
            if let fraction, let used = live.context?.estimatedTokens {
                LXMeter(fraction: fraction, label: "上下文窗口占用")
                Text("共 \(tokens(total)) · 本会话已用 \(tokens(used))")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            } else {
                PlaceholderLine("Core 还没有上报本会话的上下文用量。")
            }
        }

        LXSection("待办事项", accessory: {
            if !live.todos.isEmpty { Text("\(done) / \(live.todos.count)").monospacedDigit() }
        }) {
            if live.todos.isEmpty {
                PlaceholderLine("Agent 这一轮还没有创建待办清单。")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(live.todos, id: \.id) { TodoRow(todo: $0) }
                }
            }
        }

        LXSection("变更文件", accessory: {
            if !live.changes.isEmpty {
                LXDiffCount(additions: live.changes.reduce(0) { $0 + $1.additions },
                            deletions: live.changes.reduce(0) { $0 + $1.deletions })
            }
        }) {
            if !live.diffLoaded {
                PlaceholderLine("还没读取工作区变更，点底部刷新获取。")
            } else if live.changes.isEmpty {
                PlaceholderLine("工作区当前没有未提交的变更。")
            } else {
                VStack(spacing: 0) {
                    ForEach(live.changes.prefix(6)) { FileNameRow(file: $0) }
                }
                if live.changes.count > 6 {
                    Text("另有 \(live.changes.count - 6) 个文件，见「变更」。")
                        .font(LXType.meta).foregroundStyle(.secondary)
                }
            }
        }

        LXSection("子 Agent", accessory: {
            if !live.subagents.isEmpty { Text("\(live.subagents.count)").monospacedDigit() }
        }) {
            if live.subagents.isEmpty {
                PlaceholderLine("这一轮没有派生子 Agent。")
            } else {
                VStack(spacing: LingXiMetrics.Space.xs) {
                    ForEach(live.subagents) { agent in
                        LXKVRow(subagentTitle(agent), value: LXTaskStatusBadge(state: agent.status))
                    }
                }
            }
        }

        if !live.workflows.isEmpty {
            LXSection("Workflow") {
                ForEach(live.workflows, id: \.id) { flow in
                    LXKVRow(String(flow.id.rawValue.suffix(8)),
                            value: HStack(spacing: LingXiMetrics.Space.sm) {
                                Text("\(flow.tasks.filter { $0.status.rawValue == "completed" }.count) / \(flow.tasks.count)")
                                    .monospacedDigit()
                                LXTaskStatusBadge(state: flow.status.rawValue)
                            })
                }
            }
        }

        if !live.backgroundTasks.isEmpty {
            LXSection("后台任务") {
                ForEach(live.backgroundTasks, id: \.id) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: LingXiMetrics.Space.sm) {
                            Text(task.description ?? task.command)
                                .font(LXType.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: LingXiMetrics.Space.sm)
                            if task.status == .running {
                                Button("终止") { onTerminate(task.id) }
                                    .buttonStyle(LXButtonStyle(.destructive, size: .small))
                            }
                        }
                        Text(backgroundDetail(task)).font(LXType.meta).foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let run = live.rootRun {
            LXSection("主 Agent") {
                VStack(spacing: 0) {
                    LXKVRow("Run", value: Text(String(run.runID.rawValue.suffix(12))).font(LXType.monoSmall))
                    LXKVRow("状态", value: LXTaskStatusBadge(state: run.status.rawValue))
                    LXKVRow("开始", value: run.createdAt.formatted(date: .omitted, time: .standard))
                    if let reason = run.terminalReason { LXKVRow("结果", value: terminalReasonLabel(reason)) }
                }
            }
        }
    }

    private var modelText: some View {
        Text(live.modelID ?? notReported).font(LXType.monoSmall)
    }

    /// Model metadata first (the catalog's context window), then Core's budget.
    private var total: Int? { contextWindow ?? live.contextPolicy?.addressableBudget }

    private var fraction: Double? {
        guard let used = live.context?.estimatedTokens, let total, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    private var done: Int { live.todos.filter { $0.status == "completed" }.count }

    private func subagentTitle(_ agent: SubagentRowPresentation) -> String {
        var title = String(agent.runID.suffix(8))
        if let model = agent.model { title += " · \(model)" }
        return title
    }

    private func backgroundDetail(_ task: BackgroundTaskSnapshot) -> String {
        let status: String
        switch task.status {
        case .running: status = "执行中"
        case .exited: status = "已退出"
        case .timedOut: status = "已超时"
        case .terminated: status = "已终止"
        }
        return [status, task.pid.map { "PID \($0)" },
                DurationText.format(milliseconds: task.elapsedSeconds * 1000),
                task.exitCode.map { "退出码 \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

private func terminalReasonLabel(_ reason: TerminalReason) -> String {
    switch reason {
    case .completed: return "正常完成"
    case .blocked: return "等待你的回答"
    case .userCancelled: return "你已取消"
    case .providerFailure: return "Provider 调用失败"
    case .deadlineExceeded: return "超出时间预算"
    case .maxStepsReached: return "达到步数上限"
    case .emptyCompletion: return "模型返回空内容"
    case .runtimeFailure: return "运行时故障"
    }
}

// MARK: - 变更

struct ChangesTab: View {
    let live: InspectorSnapshot
    @State private var expanded: String?

    var body: some View {
        LXSection("工作区", separated: false) {
            VStack(spacing: 0) {
                LXKVRow("分支", value: Text(live.branch ?? notReported).font(LXType.monoSmall))
                LXKVRow("根目录", value: Text(live.workspaceRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
                                              ?? notReported).font(LXType.monoSmall))
            }
        }
        LXSection("变更文件", accessory: {
            if !live.changes.isEmpty { Text("\(live.changes.count)").monospacedDigit() }
        }) {
            if !live.diffLoaded {
                PlaceholderLine("还没读取工作区变更，点底部刷新获取。")
            } else if live.changes.isEmpty {
                PlaceholderLine("工作区当前没有未提交的变更。")
            } else {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    ForEach(live.changes) { file in
                        Button {
                            withAnimation(LXMotion.disclosure) { expanded = expanded == file.id ? nil : file.id }
                        } label: {
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(expanded == file.id ? 90 : 0))
                                    .frame(width: 12)
                                FileNameRow(file: file)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == file.id { OutputBlock(text: file.patch, isDiff: true) }
                    }
                }
            }
        }
    }
}

// MARK: - 上下文

struct ContextTab: View {
    let live: InspectorSnapshot
    let contextWindow: Int?
    let onCompact: () -> Void

    var body: some View {
        LXSection("P-Core · 主上下文", separated: false, accessory: {
            Button("立即压缩", action: onCompact).buttonStyle(LXButtonStyle(.secondary, size: .small))
        }) {
            if let fraction = pCoreFraction {
                LXMeter(fraction: fraction, label: "工作集占用")
                Text("工作集 \(tokens(pCoreUsed)) / \(tokens(pCoreTarget)) · \(percent(fraction))")
                    .font(LXType.meta).foregroundStyle(.secondary).monospacedDigit()
                VStack(spacing: 0) {
                    if let p = live.context?.pCore {
                        LXKVRow("软限 / 硬限", value: "\(tokens(p.softLimitTokens)) / \(tokens(p.hardLimitTokens))")
                    }
                    if let window = contextWindow { LXKVRow("模型窗口", value: tokens(window)) }
                    LXKVRow("可寻址预算", value: tokens(live.contextPolicy?.addressableBudget))
                    LXKVRow("前缀稳定度", value: live.context?.structuralPrefixStability.map(percent) ?? notReported)
                    LXKVRow("压缩代数", value: "\(live.context?.compactionGeneration ?? 0)")
                }
            } else {
                PlaceholderLine("Core 还没有上报 P-Core 工作集。")
            }
        }

        LXSection("E-Core · 分级记忆") {
            if let e = live.context?.eCore {
                VStack(spacing: 0) {
                    LXKVRow("对象数量", value: "\(e.objectCount)")
                    LXKVRow("存储体积", value: ByteCountFormatter.string(fromByteCount: Int64(e.totalBytes), countStyle: .memory))
                    if let hot = e.hotObjectCount, let cold = e.coldObjectCount {
                        LXKVRow("热 / 冷对象", value: "\(hot) / \(cold)")
                    }
                    if let budget = live.contextPolicy?.eCoreStorageBudget { LXKVRow("存储预算", value: tokens(budget)) }
                }
            } else {
                PlaceholderLine("E-Core 还没建立，分级记忆当前为空。")
            }
        }

        LXSection("Provider 缓存", accessory: {
            if let hit = cacheHit { Text(percent(hit)).monospacedDigit() }
        }) {
            if let hit = cacheHit {
                LXMeter(fraction: hit, label: "缓存命中占比")
            } else {
                PlaceholderLine(cacheUnavailable ? "当前 Provider 不上报缓存用量。" : "还没有完成的请求，暂无缓存读数。")
            }
            VStack(spacing: 0) {
                if let status = live.context?.providerCache?.cacheStatus { LXKVRow("缓存状态", value: status) }
                LXKVRow("上次请求 Prompt", value: tokens(cachePrompt))
                LXKVRow("缓存读取", value: tokens(cacheRead))
                if let debt = live.context?.providerCache?.cacheDebt { LXKVRow("Cache Debt", value: "\(debt)") }
            }
        }

        LXSection("Token 与速率") {
            VStack(spacing: 0) {
                LXKVRow("回复 Token（估算）", value: tokens(live.lastMetrics?.totalTokens))
                if let rate = live.lastMetrics?.tokenRate { LXKVRow("生成速率", value: String(format: "%.1f tok/s", rate)) }
                if let ttft = live.lastMetrics?.firstTokenMs {
                    LXKVRow("首 Token", value: DurationText.format(milliseconds: ttft))
                }
                if !live.reasoning.isEmpty { LXKVRow("思考档位", value: live.reasoning) }
                if let state = live.providerState { LXKVRow("Provider 状态", value: providerLabel(state)) }
                if let detail = live.providerDetail, !detail.isEmpty { LXKVRow("Provider 说明", value: detail) }
            }
        }

        AdvancedSection(live: live)
    }

    private var pCoreUsed: Int? { live.context?.pCore?.usedTokens ?? live.context?.estimatedTokens }
    private var pCoreTarget: Int? { live.context?.pCore?.targetTokens ?? live.contextPolicy?.addressableBudget }
    private var pCoreFraction: Double? {
        guard let used = pCoreUsed, let target = pCoreTarget, target > 0 else { return nil }
        return min(1, Double(used) / Double(target))
    }

    private var cacheRead: Int? { live.context?.providerCache?.cacheReadTokens }
    private var cachePrompt: Int? { live.context?.providerCache?.promptTokens }
    private var cacheUnavailable: Bool { live.context?.providerCache?.cacheStatus == "unavailable" }
    private var cacheHit: Double? {
        guard !cacheUnavailable, let read = cacheRead, let prompt = cachePrompt, prompt > 0 else { return nil }
        return min(1, Double(read) / Double(prompt))
    }
}

/// Deep telemetry stays folded: it serves debugging, not the two-second read.
struct AdvancedSection: View {
    let live: InspectorSnapshot
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            Button { withAnimation(LXMotion.disclosure) { isOpen.toggle() } } label: {
                HStack {
                    LXSectionHead("高级缓存与策略")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 0) {
                    let cache = live.context?.providerCache
                    if let epoch = cache?.cacheEpoch {
                        LXKVRow("Cache Epoch", value: [String(epoch), cache?.epochReason].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let hash = cache?.stablePrefixHash { LXKVRow("稳定前缀 Hash", value: Text(hash).font(LXType.monoSmall)) }
                    if let health = cache?.clientHealthStatus { LXKVRow("客户端健康", value: health) }
                    if let bust = live.context?.clientCausedBustRate { LXKVRow("前缀破坏率", value: percent(bust)) }
                    if let tail = live.context?.volatileTailBytes { LXKVRow("挥发尾部", value: "\(tail) B") }
                    if let c = live.compaction {
                        LXKVRow("上次压缩", value: "\(tokens(c.beforeTokens)) → \(tokens(c.afterTokens)) · \(c.triggerSource)")
                    }
                }
                if let miss = live.context?.providerCache?.missDiagnostics, !miss.isEmpty {
                    Text(miss).font(LXType.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, LingXiMetrics.Space.md)
        .overlay(alignment: .top) { LXHairline() }
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
