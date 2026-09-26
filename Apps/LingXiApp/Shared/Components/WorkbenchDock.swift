#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
import LingXiApplication

/// A secondary tool that lives in the right-hand dock instead of interrupting
/// the timeline. Ten of these would cost the rail 40pt and no vertical space,
/// which is why the conversation is allowed to stay prose-first.
public enum DockPanel: String, CaseIterable, Identifiable {
    case session
    case context
    case changes
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .session: return "会话"
        case .context: return "上下文"
        case .changes: return "变更"
        case .diagnostics: return "诊断"
        }
    }

    var symbol: String {
        switch self {
        case .session: return "activity"
        case .context: return "square.stack.3d.up"
        case .changes: return "plus.forwardslash.minus"
        case .diagnostics: return "stethoscope"
        }
    }

    var help: String {
        switch self {
        case .session: return "运行状态、待办、子 Agent 与后台任务"
        case .context: return "P-Core / E-Core / Provider 缓存 / Token 速率"
        case .changes: return "工作区分支与逐文件差异"
        case .diagnostics: return "缓存策略、前缀稳定度与运行轨迹"
        }
    }

    /// Keyboard slot on the rail, mirroring the old inspector tabs.
    var shortcutKey: String? {
        switch self {
        case .session: return "1"
        case .changes: return "2"
        case .context: return "3"
        case .diagnostics: return nil
        }
    }
}

/// Which dock panels are open, which one is frontmost, and whether the dock
/// is showing at all. Opened order and visibility survive across launches.
@MainActor
public final class DockModel: ObservableObject {
    @Published public var opened: [DockPanel] { didSet { persistOpened() } }
    @Published public var selection: DockPanel
    @Published public var isPresented: Bool { didSet { defaults.set(isPresented, forKey: LXPreferenceKey.dockVisible) } }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.string(forKey: LXPreferenceKey.dockPanels) ?? "")
            .split(separator: ",")
            .compactMap { DockPanel(rawValue: String($0)) }
        let panels = stored.isEmpty ? [DockPanel.session] : stored
        opened = panels
        selection = panels.first ?? .session
        isPresented = defaults.object(forKey: LXPreferenceKey.dockVisible) as? Bool ?? true
    }

    public var isVisible: Bool { isPresented && !opened.isEmpty }

    public func toggle(_ panel: DockPanel) {
        if let index = opened.firstIndex(of: panel) {
            opened.remove(at: index)
            if selection == panel { selection = opened.last ?? panel }
            if opened.isEmpty { isPresented = false }
        } else {
            opened.append(panel)
            selection = panel
            isPresented = true
        }
    }

    public func close(_ panel: DockPanel) {
        toggle(panel)
    }

    public func select(_ panel: DockPanel) {
        if !opened.contains(panel) { opened.append(panel) }
        selection = panel
        isPresented = true
    }

    private func persistOpened() {
        defaults.set(opened.map(\.rawValue).joined(separator: ","), forKey: LXPreferenceKey.dockPanels)
    }
}

/// The dock: open panels as tabs, plus the always-visible launcher rail on the
/// trailing edge. Lives inside `.inspector()` so column resize and the native
/// toolbar toggle come for free.
struct WorkbenchDock: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject var dock: DockModel
    let onOpenTraceWindow: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            content
            DockRail(dock: dock)
        }
        .lxPanel(LXColor.window)
        .padding([.bottom, .trailing], LingXiMetrics.Space.sm)
    }

    @ViewBuilder
    private var content: some View {
        if let panel = dock.opened.last(where: { $0 == dock.selection }) ?? dock.opened.last {
            VStack(spacing: 0) {
                if dock.opened.count > 1 { tabStrip }
                head(panel)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        panelBody(panel)
                    }
                    .padding(.horizontal, LingXiMetrics.Space.lg)
                    .padding(.bottom, LingXiMetrics.Space.md)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("没有打开的面板", systemImage: "sidebar.right",
                                   description: Text("点右侧工具栏选择一个面板。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: DockPanel) -> some View {
        if let live = runtime.inspectorModel.live {
            switch panel {
            case .session:
                OverviewTab(live: live, mode: runtime.composerModel.selectedMode,
                            contextWindow: contextWindow, onTerminate: runtime.terminateBackgroundTask)
            case .context:
                ContextTab(live: live, contextWindow: contextWindow, onCompact: runtime.compactContext)
            case .changes:
                ChangesTab(live: live)
            case .diagnostics:
                DiagnosticsPanel(live: live, runtime: runtime, onOpenTraceWindow: onOpenTraceWindow)
            }
        } else {
            PanelUnavailable(runtime: runtime)
        }
    }

    /// The selected model's context window, from the provider catalog metadata.
    private var contextWindow: Int? {
        let composer = runtime.composerModel
        guard let id = runtime.inspectorModel.live?.modelID ?? composer.selectedModelID else { return nil }
        return composer.models.first { $0.id == id || $0.modelID == id }?.contextWindow
    }

    private func head(_ panel: DockPanel) -> some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Text(panel.title)
                .font(LXType.headline.weight(.semibold))
            Spacer(minLength: 0)
            if panel == .changes || panel == .session {
                Button(action: runtime.refreshRuntimeDetails) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                .help("刷新诊断与工作区变更")
                .accessibilityLabel("刷新")
            }
            Button { dock.close(panel) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LXIconButtonStyle(side: LXControl.small))
            .help("关闭\(panel.title)面板")
            .accessibilityLabel("关闭面板")
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .frame(height: LingXiMetrics.Size.toolbar - 12)
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(dock.opened) { panel in
                let isOn = dock.selection == panel
                Button { dock.selection = panel } label: {
                    Text(panel.title)
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
        .padding(.top, LingXiMetrics.Space.sm)
    }
}

/// Always-visible launcher strip on the trailing edge of the window.
private struct DockRail: View {
    @ObservedObject var dock: DockModel

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.xs) {
            ForEach(DockPanel.allCases) { panel in
                RailButton(panel: panel, isOn: dock.opened.contains(panel),
                           isActive: dock.selection == panel && dock.opened.contains(panel)) {
                    dock.toggle(panel)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LingXiMetrics.Space.md)
        .padding(.horizontal, 4)
        .frame(width: LingXiMetrics.Size.dockRail)
        .overlay(alignment: .leading) { LXHairline() }
        .accessibilityLabel("工具面板")
    }
}

private struct RailButton: View {
    let panel: DockPanel
    let isOn: Bool
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: panel.symbol)
                .font(.system(size: LXIcon.toolbar, weight: .regular))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 26)
                .background(background, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(panel.help)
        .accessibilityLabel(panel.title)
        .accessibilityValue(isOn ? "已打开" : "已关闭")
    }

    private var background: Color {
        if isActive { return LXColor.fillControl }
        if isOn || isHovered { return LXColor.fillQuinary }
        return .clear
    }

    private var foreground: AnyShapeStyle {
        if isActive { return AnyShapeStyle(LXColor.accentText) }
        if isOn { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.secondary)
    }
}

/// Deep telemetry folded behind an explicit open, plus the trace window.
struct DiagnosticsPanel: View {
    let live: InspectorSnapshot
    @ObservedObject var runtime: RuntimeFrontend
    let onOpenTraceWindow: () -> Void

    var body: some View {
        LXSection("连接", separated: false) {
            VStack(spacing: 0) {
                LXKVRow("链路", value: Text(linkLabel))
                if let root = live.workspaceRoot {
                    LXKVRow("工作区", value: Text(root).font(LXType.monoSmall))
                }
                if let branch = live.branch {
                    LXKVRow("分支", value: Text(branch).font(LXType.monoSmall))
                }
            }
        }

        AdvancedSection(live: live)

        LXSection("运行轨迹") {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                Text("逐步记录本会话的模型请求、工具调用与上下文事件。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Button("打开轨迹窗口", action: onOpenTraceWindow)
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    Button("刷新", action: runtime.refreshRuntimeDetails)
                        .buttonStyle(LXButtonStyle(.plain, size: .small))
                }
            }
        }
    }

    private var linkLabel: String {
        switch runtime.link {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed(let message): return "失败 · \(message)"
        }
    }
}

/// No Core, no numbers: say which of the two reasons applies and stop there.
private struct PanelUnavailable: View {
    @ObservedObject var runtime: RuntimeFrontend

    var body: some View {
        VStack(spacing: LingXiMetrics.Space.md) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: LXIcon.emptyState))
                .foregroundStyle(.secondary)
            Text(title)
                .font(LXType.callout)
            Text(detail)
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LingXiMetrics.Space.xxl)
        .frame(maxWidth: .infinity)
        .padding(.top, LingXiMetrics.Space.xxxl)
    }

    private var title: String {
        switch runtime.link {
        case .connecting: return "正在启动 Core…"
        case .failed: return "无法连接 Core"
        default: return "未连接 Core"
        }
    }

    private var detail: String {
        switch runtime.link {
        case .connected:
            return "打开工作区后，这里显示运行状态、上下文窗口与变更。"
        case .failed(let message):
            return message
        case .connecting(let workspace):
            return "工作区 \(URL(fileURLWithPath: workspace).lastPathComponent)"
        case .disconnected:
            return "在侧栏底部或工作区提示中选择一个目录，灵犀会在其中启动真实 Core。"
        }
    }
}
#endif
