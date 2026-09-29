#if os(macOS)
import SwiftUI
import LingXiApplication

struct AgentStatusHUD: View {
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var composer: ComposerModel
    let compact: Bool
    let onToggle: () -> Void

    init(runtime: RuntimeFrontend, compact: Bool, onToggle: @escaping () -> Void) {
        self.inspector = runtime.inspectorModel
        self.composer = runtime.composerModel
        self.compact = compact
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                HStack(spacing: 6) {
                    statusGlyph
                    Text(status.label).font(LXType.meta.weight(.medium)).foregroundStyle(.primary)
                    if compact {
                        Text("上下文 \(percent(contextUsage))")
                            .font(LXType.meta.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if !compact { Spacer(minLength: 0) }
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: LXIcon.caret, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(compact ? -90 : 0))
                        .frame(width: LXControl.small - 4, height: LXControl.small - 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(compact ? "展开运行状态" : "收起运行状态")
                .accessibilityLabel(compact ? "展开运行状态" : "收起运行状态")
            }
            if !compact {
                VStack(spacing: 6) {
                    metric("缓存命中", value: cacheHit)
                    metric("上下文", value: contextUsage, warning: (contextUsage ?? 0) >= 0.85)
                    metric("P-Core", value: pCoreUsage)
                    metric("E-Core", value: eCoreUsage)
                }
            }
        }
        .padding(.horizontal, compact ? LingXiMetrics.Space.md : LingXiMetrics.Space.panelInset)
        .padding(.vertical, compact ? 6 : LingXiMetrics.Space.md)
        .frame(width: compact ? nil : LingXiMetrics.Size.statusHUD, alignment: .leading)
        .lxFloating(cornerRadius: compact ? LingXiMetrics.Radius.surface : LingXiMetrics.Radius.control)
    }

    /// Running: teal dot · thinking: indigo dot · needs you: warning clock ·
    /// idle: hollow secondary circle.
    @ViewBuilder
    private var statusGlyph: some View {
        if status.symbol == "circle.fill" {
            Circle().fill(status.color).frame(width: LXControl.dot, height: LXControl.dot)
        } else {
            Image(systemName: status.symbol)
                .font(.system(size: LXIcon.small))
                .foregroundStyle(status.color)
        }
    }

    /// label (text-secondary) · 4pt neutral bar · percent (tabular). Only a
    /// context ≥ 85% bar turns status-warning: compaction is near.
    private func metric(_ title: String, value: Double?, warning: Bool = false) -> some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LXColor.fillControl)
                    if let value {
                        Capsule().fill(warning ? AnyShapeStyle(LXColor.warning) : AnyShapeStyle(.secondary))
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                    }
                }
            }
            .frame(height: 4)
            Text(percent(value))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .font(LXType.meta)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(percent(value))")
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private var live: InspectorSnapshot? { inspector.live }

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
              let budget = contextWindow ?? live?.contextPolicy?.addressableBudget,
              budget > 0 else { return nil }
        return Double(used) / Double(budget)
    }

    private var contextWindow: Int? {
        guard let selected = composer.selectedModelID else { return nil }
        return composer.models.first { $0.matches(selection: selected) }.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil }
    }

    private var pCoreUsage: Double? {
        guard let core = live?.context?.pCore, core.targetTokens > 0 else { return nil }
        return Double(core.usedTokens) / Double(core.targetTokens)
    }

    private var eCoreUsage: Double? {
        guard let bytes = live?.context?.eCore?.totalBytes,
              let budget = live?.contextPolicy?.eCoreStorageBudget,
              budget > 0 else { return nil }
        return Double(bytes) / Double(budget)
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
