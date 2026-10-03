#if os(macOS)
import SwiftUI
import LingXiProtocol

/// The Runtime Observatory: an independent engineering window for the P/E-Core runtime.
///
/// This is deliberately not part of the main workbench. The product surface stays a chat window;
/// everything here exists to be read while a several-hundred-turn run is going on, which needs a
/// density a product UI should not have and a debug instrument cannot do without.
///
/// Read-only with respect to the runtime. The window sends nothing that can change context, prompt
/// or agent behaviour; its only writes are the debug-mode and recorder commands, and the claim that
/// those do not perturb requests is proved in `RuntimeObservatoryBypassTests` rather than assumed
/// here.
public struct RuntimeObservatoryView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject var inspector: RuntimeInspectorPresentationModel
    @StateObject private var model: RuntimeObservatoryPresentationModel
    @State private var section: ObservatorySection = .overview
    @State private var autoRefresh = false
    @State private var refreshInterval: Double = 3
    @State private var selectedEventID: UInt64?

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.inspector = runtime.inspectorModel
        self._model = StateObject(wrappedValue: runtime.observatoryModel)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("调试遥测") {
                    ForEach(ObservatorySection.debugBacked) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Core 已有数据") {
                    ForEach(ObservatorySection.coreBacked) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
        }
        .tint(LXColor.accent)
        .frame(minWidth: 1080, minHeight: 640)
        .task {
            await runtime.probeObservatory()
            await runtime.refreshObservatory()
        }
        // Re-probe when the connection changes. Without this the window can stick on "未连接
        // Core" forever: macOS restores windows at launch, so this one's `.task` often runs before
        // the workspace has reconnected, and nothing afterwards would ask again.
        .onChange(of: runtime.link) { _, link in
            guard link == .connected else { return }
            Task {
                await runtime.probeObservatory()
                await runtime.refreshObservatory()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LingXiAgent Runtime Observatory")
                    .font(LXType.body.bold())
                Text(subtitle)
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("自动刷新", isOn: $autoRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.isLive)
            if autoRefresh {
                Text("\(Int(refreshInterval))s")
                    .font(LXType.monoSmall)
                    .foregroundStyle(.secondary)
            }
            // Never disabled. `refreshObservatory` re-probes first, so this is how a window that
            // came up before Core connected recovers; greying it out while unavailable removes the
            // one control that could fix the state it is complaining about.
            Button {
                Task { await runtime.refreshObservatory() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .background(LXColor.window)
        // Restartable by value: changing the interval while running has to take effect, or the
        // control would lie about what it does.
        .task(id: "\(autoRefresh)-\(refreshInterval)") {
            guard autoRefresh, model.isLive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled, autoRefresh, model.isLive else { return }
                await runtime.refreshObservatory()
            }
        }
    }

    private var subtitle: String {
        switch model.availability {
        case .notConnected: return "未连接 Core"
        case .unsupported: return "此 Core 不含 Observatory"
        case .unknown(let reason): return "无法确定：\(reason)"
        case .disabled: return "Developer Debug Mode 未开启"
        case .enabled(let status):
            var parts = ["缓冲 \(status.eventsBuffered)/\(status.ringCapacity)"]
            if status.eventsDropped > 0 { parts.append("已丢弃 \(status.eventsDropped)") }
            if status.recording { parts.append("录制中 \(status.runName ?? "run")") }
            if status.archiveWriteFailures > 0 { parts.append("归档失败 \(status.archiveWriteFailures)") }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder private var content: some View {
        if section.isDebugBacked, !model.isLive {
            unavailablePane
        } else {
            switch section {
            case .overview: ObservatoryOverviewPane(model: model, inspector: inspector)
            case .corePE: PEECorePane(model: model)
            case .prefixCache: PrefixCachePane(model: model)
            case .events: EventsPane(model: model, onSelect: { selectedEventID = $0 })
            case .raw: RawTelemetryPane(model: model, selected: $selectedEventID, runtime: runtime)
            case .agentLoop: AgentLoopPane(inspector: inspector)
            case .tools: ToolsPane(inspector: inspector)
            case .provider: ProviderPane(inspector: inspector)
            case .tasks: TasksPane(inspector: inspector)
            }
        }
    }

    /// Explains why there is nothing to show, rather than showing an empty instrument.
    private var unavailablePane: some View {
        ContentUnavailableView {
            Label(paneTitle, systemImage: "ladybug")
        } description: {
            Text(paneDescription)
        } actions: {
            if case .disabled = model.availability {
                // Opens Settings without deep-linking to the Diagnostics page: reaching a specific
                // page from here would need a new navigation channel into WarmNavigation, and a
                // debug shortcut is not worth adding one.
                Button("打开设置") { runtime.isShowingSettings = true }
            }
            Button("重新探测") { Task { await runtime.probeObservatory() } }
        }
    }

    private var paneTitle: String {
        switch model.availability {
        case .unsupported: return "不可用"
        case .disabled: return "Developer Debug Mode 未开启"
        case .unknown: return "状态未知"
        default: return "未连接"
        }
    }

    private var paneDescription: String {
        switch model.availability {
        case .unsupported:
            return "连接的 Core 未提供 debug.* 接口，需要运行包含 Runtime Observatory 的版本。"
        case .disabled:
            return "深度遥测只在开发者调试模式下采集。开启前这里不显示任何数值，因为空数组和 0 "
                + "会被读成「已经观测过，而且一切正常」——那正是这个窗口最不能造成的误会。"
        case .unknown(let reason):
            return reason
        default:
            return "打开一个工作区之后本窗口才会连上 Core。"
        }
    }
}

// MARK: - Sections

enum ObservatorySection: String, CaseIterable, Identifiable, Hashable {
    case overview, corePE, prefixCache, events, raw
    case agentLoop, tools, provider, tasks

    var id: Self { self }

    /// Backed by the debug RPCs, so these require Developer Debug Mode.
    static let debugBacked: [ObservatorySection] = [.overview, .corePE, .prefixCache, .events, .raw]
    /// Backed only by data Core already publishes to the main product surface. These render without
    /// debug mode because inventing a second copy of an existing reading would create the second
    /// authority this whole feature is written to avoid.
    static let coreBacked: [ObservatorySection] = [.agentLoop, .tools, .provider, .tasks]

    var isDebugBacked: Bool { Self.debugBacked.contains(self) }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .corePE: return "P/E-Core"
        case .prefixCache: return "Prefix Cache"
        case .events: return "Events"
        case .raw: return "Raw Telemetry"
        case .agentLoop: return "Agent Loop"
        case .tools: return "Tools"
        case .provider: return "Provider"
        case .tasks: return "Tasks / Subagents"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .corePE: return "square.3.layers.3d"
        case .prefixCache: return "lock.rectangle.stack"
        case .events: return "list.bullet.rectangle"
        case .raw: return "curlybraces"
        case .agentLoop: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .provider: return "network"
        case .tasks: return "square.stack.3d.up"
        }
    }
}

#endif
