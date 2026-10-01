#if os(macOS)
import SwiftUI
import LingXiApplication
import LingXiProtocol

struct AgentStatusHUD: View {
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @ObservedObject private var composer: ComposerModel
    /// The tree, its refresh and its cancel/resume actions are runtime operations; the view
    /// models above carry only what is projected for display.
    @ObservedObject private var runtime: RuntimeFrontend
    let compact: Bool
    let onToggle: () -> Void

    init(runtime: RuntimeFrontend, compact: Bool, onToggle: @escaping () -> Void) {
        self.inspector = runtime.inspectorModel
        self.conversation = runtime.conversationModel
        self.composer = runtime.composerModel
        self.runtime = runtime
        self.compact = compact
        self.onToggle = onToggle
    }

    var body: some View {
        Group {
            if compact { compactStatus } else { contextPane }
        }
    }

    private var compactStatus: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                statusGlyph
                Text(status.label).font(LXType.headline)
                Spacer(minLength: 0)
                toggleButton
            }
            LXHairline()
            summaryMetric("缓存命中", value: percent(cacheHit), progress: cacheHit)
            summaryMetric(isEmptySession ? "预置上下文" : "上下文", value: percent(contextUsage), progress: contextUsage)
            summaryMetric("P-Core", value: percent(pCoreUsage), progress: pCoreUsage)
            summaryMetric("E-Core", value: eCoreCount, progress: nil)
            // The collapsed HUD keeps the context lines exactly as they were and adds two
            // counters under them (§7 of the layout addendum). Full tree and task detail stay
            // out of the small window by design.
            if !subagents.isEmpty {
                countLine("子代理", "\(subagents.filter { isActive($0.status) }.count) 运行中")
            }
            if !(live?.todos ?? []).isEmpty {
                let todos = live?.todos ?? []
                countLine("Task", "\(todos.filter { $0.status == "completed" }.count) / \(todos.count)")
            }
        }
        .padding(LingXiMetrics.Space.md)
        .frame(width: LingXiMetrics.Size.statusHUD)
        .lxFloating(cornerRadius: LingXiMetrics.Radius.surface)
    }

    /// The persistent right-hand column.
    ///
    /// §30 of the closure contract freezes the 运行上下文 card — its layout, order, rings and
    /// bars stay exactly as they were — and allows only appending below it. So this is a scroll
    /// column holding the unchanged card plus two compact sections, not a redesigned sidebar:
    /// running out of height scrolls, it never squeezes the context card.
    private var contextPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                contextCard
                LXHairline()
                subagentSection
                LXHairline()
                taskSection
            }
        }
        .frame(width: LingXiMetrics.Size.statusHUD)
        .frame(maxHeight: .infinity, alignment: .top)
        .lxPanel()
        .sheet(isPresented: $runtime.isAgentTreePresented, onDismiss: nil) {
            AgentTreeSheet(runtime: runtime)
        }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Text("运行上下文")
                    .font(LXType.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                toggleButton
            }
            .padding(.bottom, LingXiMetrics.Space.lg)

            HStack(spacing: LingXiMetrics.Space.md) {
                statusGlyph
                Text(status.label)
                    .font(LXType.title)
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
            .padding(.bottom, LingXiMetrics.Space.lg)

            LXHairline()
            contextChart
                .padding(.vertical, LingXiMetrics.Space.xl)
            LXHairline()
            VStack(spacing: LingXiMetrics.Space.xl) {
                metric("缓存命中", value: cacheHit,
                       detail: tokenPair(live?.context?.providerCache?.cacheReadTokens,
                                         live?.context?.providerCache?.promptTokens))
                metric("P-Core", value: pCoreUsage,
                       detail: tokenPair(live?.context?.pCore?.usedTokens,
                                         live?.context?.pCore?.targetTokens))
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    HStack {
                        Text("E-Core").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(eCoreCount).monospacedDigit()
                    }
                    Text(eCoreBytes)
                        .foregroundStyle(.secondary)
                }
                .font(LXType.meta)
            }
            .padding(.top, LingXiMetrics.Space.xl)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.xxl)
    }

    /// Compact live subagents. Names, state, and nothing else — runIDs, full trees, terminal
    /// reasons and timestamps belong to the detail surface this row opens, per §3 of the layout
    /// addendum. An empty state is shown rather than hiding the section, so "no subagents"
    /// reads as a fact about the run rather than as a broken panel.
    @ViewBuilder private var subagentSection: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text("子代理").font(LXType.headline)
                if !subagents.isEmpty {
                    Text("\(subagents.count)").font(LXType.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityAddTraits(.isHeader)

            if subagents.isEmpty {
                Text("暂无活跃子代理").font(LXType.meta).foregroundStyle(.secondary)
            } else {
                ForEach(subagents.prefix(6)) { row in
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Image(systemName: glyph(for: row.status)).foregroundStyle(tint(for: row.status))
                        Text(row.model.flatMap { $0.isEmpty ? nil : $0 } ?? "子代理")
                            .font(LXType.meta).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(row.status).font(LXType.meta).foregroundStyle(.secondary)
                    }
                }
                Button("查看完整 Agent 树") {
                    Task { await runtime.refreshAgentTree() }
                    runtime.isAgentTreePresented = true
                }
                    .buttonStyle(.plain)
                    .font(LXType.meta)
                    .padding(.top, LingXiMetrics.Space.xs)
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.xl)
    }

    /// The turn's to-do list, compact. Criteria, artifacts, reports and the lifecycle actions
    /// stay in Task Detail (§4 of the addendum).
    @ViewBuilder private var taskSection: some View {
        let todos = live?.todos ?? []
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text("Task").font(LXType.headline)
                Spacer(minLength: 0)
                if !todos.isEmpty {
                    Text("\(todos.filter { $0.status == "completed" }.count) / \(todos.count)")
                        .font(LXType.meta).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityAddTraits(.isHeader)

            if todos.isEmpty {
                Text("本轮没有待办").font(LXType.meta).foregroundStyle(.secondary)
            } else {
                ForEach(todos.prefix(8), id: \.id) { todo in
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Image(systemName: glyph(for: todo.status)).foregroundStyle(tint(for: todo.status))
                        Text(todo.title).font(LXType.meta).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.xl)
    }

    private func countLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }
        .font(LXType.meta)
    }

    private func isActive(_ status: String) -> Bool {
        ["running", "in_progress", "starting", "queued", "waitingForTool", "waitingForUser"].contains(status)
    }

    private var subagents: [SubagentRowPresentation] { live?.subagents ?? [] }

    private func glyph(for status: String) -> String {
        switch status {
        case "completed", "done", "succeeded": return "checkmark.circle.fill"
        case "in_progress", "running", "starting": return "circle.fill"
        case "failed", "cancelled", "timedOut", "timed_out": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private func tint(for status: String) -> Color {
        switch status {
        case "completed", "done", "succeeded": return .green
        case "in_progress", "running", "starting": return .accentColor
        case "failed", "cancelled", "timedOut", "timed_out": return .red
        default: return .secondary
        }
    }

    private var contextChart: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            ZStack {
                Circle().stroke(LXColor.fillControl, lineWidth: 10)
                if let usage = contextUsage {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, usage)))
                        .stroke(usage >= 0.85 ? LXColor.warning : LXColor.running,
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(percent(contextUsage))
                    .font(LXType.headline.monospacedDigit())
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                Text("上下文占用")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                Text(tokenPair(live?.context?.estimatedTokens, contextBudget))
                    .font(LXType.meta.monospacedDigit())
                Text(isEmptySession ? "预置上下文" : "已用 / 可用")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上下文占用 \(percent(contextUsage))，\(tokenPair(live?.context?.estimatedTokens, contextBudget))\(isEmptySession ? "，预置上下文，尚无对话" : "")")
    }

    private func summaryMetric(_ title: String, value: String, progress: Double?) -> some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LXColor.fillControl)
                    if let progress {
                        Capsule().fill(title == "上下文" && progress >= 0.85 ? AnyShapeStyle(LXColor.warning) : AnyShapeStyle(.secondary))
                            .frame(width: geometry.size.width * min(1, max(0, progress)))
                    }
                }
            }
            .frame(height: 4)
            Text(value)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .font(LXType.meta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            Image(systemName: compact ? "chevron.left" : "chevron.right")
                .font(.system(size: LXIcon.caret, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: LXControl.small, height: LXControl.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? "展开运行上下文" : "收起运行上下文")
        .accessibilityLabel(compact ? "展开运行上下文" : "收起运行上下文")
    }

    /// Running: teal dot · thinking: indigo dot · needs you: warning clock ·
    /// idle: hollow secondary circle.
    @ViewBuilder
    private var statusGlyph: some View {
        if status.symbol == "circle.fill" {
            Circle().fill(status.color).frame(width: compact ? LXControl.dot : 10,
                                              height: compact ? LXControl.dot : 10)
        } else {
            Image(systemName: status.symbol)
                .font(.system(size: compact ? LXIcon.small : LXIcon.row))
                .foregroundStyle(status.color)
        }
    }

    /// Label, neutral progress bar, and the runtime values behind the percentage.
    private func metric(_ title: String, value: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(percent(value))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LXColor.fillControl)
                    if let value {
                        Capsule().fill(.secondary)
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                    }
                }
            }
            .frame(height: 6)
            if detail != "—" {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(LXType.meta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(percent(value))")
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func tokenPair(_ used: Int?, _ budget: Int?) -> String {
        guard let used, let budget, budget > 0 else { return "—" }
        return "\(TokenFormatter.format(used)) / \(TokenFormatter.format(budget)) token"
    }

    private var eCoreCount: String {
        guard let count = live?.context?.eCore?.objectCount else { return "—" }
        return "\(count) 项"
    }

    private var eCoreBytes: String {
        guard let bytes = live?.context?.eCore?.totalBytes else { return "存储量 —" }
        return "存储量 \(TokenFormatter.formatBytes(bytes))"
    }

    private var live: InspectorSnapshot? { inspector.live }

    private var isEmptySession: Bool {
        !conversation.sessionID.isEmpty && conversation.items.isEmpty && live?.context?.sessionID.rawValue == conversation.sessionID
    }

    private var cacheHit: Double? {
        guard let cache = live?.context?.providerCache,
              cache.cacheStatus != "unavailable",
              let read = cache.cacheReadTokens,
              let prompt = cache.promptTokens,
              prompt > 0 else { return nil }
        return Double(read) / Double(prompt)
    }

    private var contextUsage: Double? {
        guard let used = live?.context?.estimatedTokens,
              let budget = contextBudget,
              budget > 0 else { return nil }
        return Double(used) / Double(budget)
    }

    private var contextBudget: Int? {
        live?.contextPolicy?.addressableBudget ?? contextWindow
    }

    private var contextWindow: Int? {
        guard let selected = composer.selectedModelID else { return nil }
        return composer.models.first { $0.matches(selection: selected) }.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil }
    }

    private var pCoreUsage: Double? {
        guard let core = live?.context?.pCore, core.targetTokens > 0 else { return nil }
        return Double(core.usedTokens) / Double(core.targetTokens)
    }

    private var status: (label: String, symbol: String, color: Color) {
        switch live?.status ?? .disconnected {
        case .ready: ("空闲", "circle", .secondary)
        case .thinking: ("思考中", "circle.fill", LXColor.thinking)
        case .waitingForProvider: ("等待模型", "clock", LXColor.warning)
        case .rateLimited: ("等待重试", "clock.arrow.circlepath", LXColor.warning)
        case .runningTool: ("执行中", "circle.fill", LXColor.running)
        case .runningSubagents: ("子 Agent 执行中", "circle.fill", LXColor.running)
        case .paging: ("整理上下文", "circle.fill", LXColor.thinking)
        case .actionRequired: ("待你处理", "clock", LXColor.warning)
        case .reconnecting: ("重新连接", "arrow.triangle.2.circlepath", LXColor.warning)
        case .disconnected: ("未连接", "circle", .secondary)
        case .error: ("运行异常", "exclamationmark.circle", LXColor.danger)
        }
    }
}
#endif
