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
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                        .font(.system(size: LXIcon.status))
                    Text(status.label).font(LXType.meta.weight(.medium))
                    if compact {
                        Text(percent(contextUsage))
                            .font(LXType.meta.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if !compact { Spacer(minLength: 0) }
                Button(action: onToggle) {
                    Image(systemName: compact ? "chevron.down" : "chevron.up")
                        .font(.system(size: LXIcon.caret))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(compact ? "展开运行上下文" : "收起运行上下文")
            }
            if !compact {
                metric("缓存命中", value: cacheHit, detail: percent(cacheHit))
                metric("上下文", value: contextUsage, detail: percent(contextUsage), warning: (contextUsage ?? 0) >= 0.85)
                metric("P-Core", value: pCoreUsage, detail: percent(pCoreUsage))
                metric("E-Core", value: eCoreUsage, detail: percent(eCoreUsage))
            }
        }
        .padding(compact ? LingXiMetrics.Space.sm : LingXiMetrics.Space.panelInset)
        .frame(width: compact ? nil : LingXiMetrics.Size.statusHUD, alignment: .leading)
        .lxFloating(cornerRadius: LingXiMetrics.Radius.control)
    }

    private func metric(_ title: String, value: Double?, detail: String, warning: Bool = false) -> some View {
        VStack(spacing: LingXiMetrics.Space.xs) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(detail).foregroundStyle(.primary).monospacedDigit()
            }
            .font(LXType.meta)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LXColor.fillControl)
                    if let value {
                        Capsule().fill(warning ? LXColor.warning : Color.secondary.opacity(0.55))
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                    }
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
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
        return composer.models.first {
            $0.modelID == selected || $0.id == selected
        }.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil }
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
