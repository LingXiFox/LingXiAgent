#if canImport(SwiftUI)
import SwiftUI

/// Frontend V2 workbench shell.
///
/// Three columns plus a rail:
///   sidebar (sessions) · stage (timeline + composer) · dock (secondary tools) · rail
///
/// The dock replaces the old three-tab inspector. Secondary tools pay 40pt of
/// rail width instead of competing with the conversation, which is what keeps
/// the centre column readable.
public struct WorkbenchShell: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var sidebar: SidebarPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @ObservedObject private var dock: DockModel
    var settings: SettingsStore?
    var onOpenTraceWindow: () -> Void

    @State private var settingsPage: SettingsPage = .general
    @AppStorage(LXPreferenceKey.colorScheme) private var colorScheme = ColorSchemePreference.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(runtime: RuntimeFrontend, dock: DockModel, settings: SettingsStore? = nil,
                onOpenTraceWindow: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.settings = settings
        self.sidebar = runtime.sidebarModel
        self.conversation = runtime.conversationModel
        self.onOpenTraceWindow = onOpenTraceWindow
        self.dock = dock
    }

    private var isSettings: Bool { runtime.isShowingSettings }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(runtime: runtime)
                .navigationSplitViewColumnWidth(min: LingXiMetrics.Size.navigatorMin,
                                                ideal: LingXiMetrics.Size.navigator,
                                                max: LingXiMetrics.Size.navigator + LingXiMetrics.Space.xxxl)
        } detail: {
            ZStack {
                MainStageView(runtime: runtime)
                if runtime.isCommandPalettePresented { palette }
            }
            .background(LXColor.window)
            .inspector(isPresented: $dock.isPresented) {
                WorkbenchDock(runtime: runtime, dock: dock, onOpenTraceWindow: onOpenTraceWindow)
                    .inspectorColumnWidth(min: LingXiMetrics.Size.inspectorMin,
                                          ideal: LingXiMetrics.Size.inspector,
                                          max: LingXiMetrics.Size.inspector + LingXiMetrics.Space.xxxl)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $runtime.isShowingAboutSheet) { AboutSheet(runtime: runtime) }
        .sheet(isPresented: settingsSheetBinding, onDismiss: { runtime.isShowingSettings = false }) {
            if let settings {
                SettingsWorkbench(store: settings, page: $settingsPage)
            }
        }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: runtime.isShowingSettings)
        .animation(LXMotion.animation(LXMotion.disclosure, reduceMotion: reduceMotion),
                   value: runtime.isCommandPalettePresented)
        .frame(minWidth: LingXiMetrics.Size.windowMinWidth, minHeight: LingXiMetrics.Size.windowMinHeight)
        .preferredColorScheme(colorScheme.colorScheme)
    }

    // MARK: Bindings

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebar.isNavigatorVisible ? .all : .detailOnly },
                set: { sidebar.isNavigatorVisible = $0 != .detailOnly })
    }

    private var settingsSheetBinding: Binding<Bool> {
        Binding(get: { isSettings }, set: { runtime.isShowingSettings = $0 })
    }

    // MARK: Title

    private var title: String {
        guard let id = sidebar.selectedSessionID,
              let session = sidebar.allSessions.first(where: { $0.id == id }), !session.title.isEmpty
        else { return "新会话" }
        return session.title
    }

    /// Run state first, then workspace · branch — all from the runtime.
    private var subtitle: String {
        if runtime.link != .connected { return "未连接 Core" }
        if hasPendingInteraction { return "等待你的决定" }
        if conversation.isGenerating {
            let running = runtime.inspectorModel.live?.subagents
                .filter { EventStatus($0.status) == .running }.count ?? 0
            return running > 0 ? "执行中 · \(running) 个子 Agent" : "执行中"
        }
        var parts = [sidebar.workspace.name]
        if let branch = sidebar.workspace.gitBranch, !branch.isEmpty { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    private var hasPendingInteraction: Bool {
        conversation.items.contains {
            if case .interaction(let card) = $0.kind { return card.status == .pending }
            return false
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: runtime.newSession) {
                Label("新建会话", systemImage: "square.and.pencil")
            }
            .help("新建会话 (⌘N)")
            .disabled(runtime.link != .connected)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { runtime.isShowingSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("设置 (⌘,)")
            Button { dock.isPresented.toggle() } label: {
                Label("工具面板", systemImage: "sidebar.right")
                    .foregroundStyle(dock.isVisible ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
            }
            .help("显示或隐藏工具面板 (⌥⌘I)")
            .accessibilityValue(dock.isVisible ? "已显示" : "已隐藏")
        }
    }

    // MARK: Palette

    @ViewBuilder
    private var palette: some View {
        Color.black.opacity(0.001)
            .onTapGesture { runtime.isCommandPalettePresented = false }
        CommandPalette(runtime: runtime, appActions: paletteActions) {
            runtime.isCommandPalettePresented = false
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, LingXiMetrics.Space.xxxxl)
        .transition(.opacity)
    }

    var paletteActions: [PaletteAction] {
        var actions = [
            PaletteAction(id: "app.new", title: "新建会话", symbol: "square.and.pencil", shortcut: "⌘N") {
                runtime.isShowingSettings = false
                runtime.newSession()
            },
            PaletteAction(id: "app.navigator", title: "显示或隐藏导航面板", symbol: "sidebar.left", shortcut: "⌃S") {
                sidebar.isNavigatorVisible.toggle()
            },
            PaletteAction(id: "app.dock", title: "显示或隐藏工具面板", symbol: "sidebar.right", shortcut: "⌥⌘I") {
                dock.isPresented.toggle()
            },
            PaletteAction(id: "app.trace", title: "运行轨迹", symbol: "list.bullet.rectangle", shortcut: "⌥⌘L",
                          perform: onOpenTraceWindow),
        ]
        for panel in DockPanel.allCases {
            actions.append(PaletteAction(id: "dock.\(panel.rawValue)", title: "打开\(panel.title)面板",
                                        symbol: panel.symbol,
                                        shortcut: panel.shortcutKey.map { "⌥\($0)" }) {
                dock.select(panel)
            })
        }
        if runtime.link == .connected {
            actions += [
                PaletteAction(id: "app.compact", title: "压缩上下文", symbol: "rectangle.compress.vertical") {
                    dock.select(.context)
                    runtime.compactContext()
                },
                PaletteAction(id: "app.changes", title: "查看工作区变更", symbol: "plus.forwardslash.minus") {
                    dock.select(.changes)
                    runtime.refreshRuntimeDetails()
                },
                PaletteAction(id: "app.stop", title: "停止当前运行", symbol: "stop.circle", shortcut: "⌘.") {
                    runtime.stopGenerating()
                },
            ]
        }
        actions.append(PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") {
            runtime.isShowingSettings = true
        })
        return actions
    }
}
#endif
