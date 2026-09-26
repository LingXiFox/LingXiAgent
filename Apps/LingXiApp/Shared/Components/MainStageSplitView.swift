#if canImport(SwiftUI)
import SwiftUI

/// Main window presentation: the workspace, or Settings swapped in place.
public enum MainPresentationMode: Equatable {
    case workspace
    case settings
}

/// Main window: native `NavigationSplitView` + `.inspector()`, unified toolbar.
///
/// Layout (design system "Screens"): bg-window ground; the sidebar is the
/// system sidebar; the stage is a rounded bg-content panel inset 8pt carrying
/// the only ambient light; the inspector is a bg-window panel. Toolbar: new
/// session · title/subtitle · settings · inspector toggle (accent-text when
/// open). Nothing draws its own title bar or traffic lights.
public struct MainStageSplitView: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var sidebar: SidebarPresentationModel
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    var settings: SettingsStore?
    var onOpenTraceWindow: () -> Void

    @State private var settingsPage: SettingsPage = .general
    @AppStorage(LXPreferenceKey.colorScheme) private var colorScheme = ColorSchemePreference.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(runtime: RuntimeFrontend, settings: SettingsStore? = nil, onOpenTraceWindow: @escaping () -> Void = {}) {
        self.runtime = runtime
        self.settings = settings
        self.sidebar = runtime.sidebarModel
        self.inspector = runtime.inspectorModel
        self.conversation = runtime.conversationModel
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    private var mode: MainPresentationMode { runtime.isShowingSettings ? .settings : .workspace }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            Group {
                switch mode {
                case .workspace:
                    SidebarView(runtime: runtime)
                case .settings:
                    if let settings { SettingsSidebar(store: settings, selectedPage: $settingsPage) }
                }
            }
            .navigationSplitViewColumnWidth(min: LingXiMetrics.Size.navigatorMin,
                                            ideal: mode == .settings ? LingXiMetrics.Column.settingsSidebar
                                                                     : LingXiMetrics.Size.navigator,
                                            max: LingXiMetrics.Size.navigator + LingXiMetrics.Space.xxxl)
        } detail: {
            ZStack {
                switch mode {
                case .workspace:
                    MainStageView(runtime: runtime)
                case .settings:
                    if let settings {
                        SettingsDetailView(store: settings, page: settingsPage)
                            .background { AtmosphereBackdrop(mode: .settings).ignoresSafeArea() }
                    }
                }
                if runtime.isCommandPalettePresented { palette }
            }
            .background(LXColor.window)
            .inspector(isPresented: inspectorBinding) {
                InspectorView(runtime: runtime, onOpenTraceWindow: onOpenTraceWindow)
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
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: mode)
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

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { mode == .workspace && inspector.isPresented },
                set: { if mode == .workspace { inspector.isPresented = $0 } })
    }

    // MARK: Title

    private var title: String {
        switch mode {
        case .settings: return settingsPage.title
        case .workspace:
            guard let id = sidebar.selectedSessionID,
                  let title = sidebar.allSessions.first(where: { $0.id == id })?.title, !title.isEmpty
            else { return "新会话" }
            return title
        }
    }

    /// Run state first, then workspace · branch — all from the runtime.
    private var subtitle: String {
        guard mode == .workspace else { return "" }
        if runtime.link != .connected { return "未连接 Core" }
        if hasPendingInteraction { return "等待你的决定" }
        if conversation.isGenerating {
            let running = inspector.live?.subagents.filter { EventStatus($0.status) == .running }.count ?? 0
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
        switch mode {
        case .workspace:
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
                Button { inspector.isPresented.toggle() } label: {
                    Label("检查器", systemImage: "sidebar.right")
                        .foregroundStyle(inspector.isPresented ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
                }
                .help("显示或隐藏检查器 (⌥⌘I)")
                .accessibilityValue(inspector.isPresented ? "已显示" : "已隐藏")
            }
        case .settings:
            ToolbarItem(placement: .navigation) {
                Button { runtime.isShowingSettings = false } label: {
                    Label("返回工作区", systemImage: "chevron.left")
                }
                .help("返回工作区 (Esc)")
                .keyboardShortcut(.cancelAction)
            }
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

    private var paletteActions: [PaletteAction] {
        var actions = [
            PaletteAction(id: "app.new", title: "新建会话", symbol: "square.and.pencil", shortcut: "⌘N") {
                runtime.isShowingSettings = false
                runtime.newSession()
            },
            PaletteAction(id: "app.navigator", title: "显示或隐藏导航面板", symbol: "sidebar.left", shortcut: "⌃⌘S") {
                sidebar.isNavigatorVisible.toggle()
            },
            PaletteAction(id: "app.inspector", title: "显示或隐藏检查器", symbol: "sidebar.right", shortcut: "⌥⌘I") {
                inspector.isPresented.toggle()
            },
            PaletteAction(id: "app.trace", title: "运行轨迹", symbol: "list.bullet.rectangle", shortcut: "⌥⌘L",
                          perform: onOpenTraceWindow),
        ]
        if runtime.link == .connected {
            actions += [
                PaletteAction(id: "app.compact", title: "压缩上下文", symbol: "rectangle.compress.vertical") {
                    runtime.compactContext()
                },
                PaletteAction(id: "app.changes", title: "查看工作区变更", symbol: "plus.forwardslash.minus") {
                    inspector.selectedTab = .changes
                    inspector.isPresented = true
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
