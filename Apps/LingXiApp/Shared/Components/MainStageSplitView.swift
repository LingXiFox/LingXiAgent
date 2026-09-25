#if canImport(SwiftUI)
import SwiftUI

/// Main window, Apple Maps style: the conversation stage fills the window over
/// a static ambient backdrop; the navigator (left) and inspector (right) are
/// independent floating glass panels with their own margin and corner radius.
///
/// Wide windows reserve room for both panels so the reading column never runs
/// beneath them; narrow windows let the inspector float over the stage instead.
public struct MainStageSplitView: View {
    @ObservedObject public var runtime: RuntimeFrontend
    @ObservedObject private var sidebar: SidebarPresentationModel
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    public var onOpenTraceWindow: () -> Void

    @AppStorage(LXPreferenceKey.panelMaterial) private var panelMaterial = PanelMaterialPreference.clear
    @AppStorage(LXPreferenceKey.colorScheme) private var colorScheme = ColorSchemePreference.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    public init(
        runtime: RuntimeFrontend,
        onOpenTraceWindow: @escaping () -> Void = {}
    ) {
        self.runtime = runtime
        self.sidebar = runtime.sidebarModel
        self.inspector = runtime.inspectorModel
        self.conversation = runtime.conversationModel
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    public var body: some View {
        GeometryReader { geo in
            let reservesInspector = inspector.isPresented
                && geo.size.width >= LingXiMetrics.Split.inspectorDockMinWidth

            ZStack {
                stage
                    .padding(.leading, sidebar.isNavigatorVisible ? navigatorInset : 0)
                    .padding(.trailing, reservesInspector ? inspectorInset : 0)

                HStack(alignment: .top, spacing: 0) {
                    if sidebar.isNavigatorVisible {
                        navigator
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if inspector.isPresented {
                        inspectorPanel
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(LingXiMetrics.Split.panelMargin)

                if runtime.isCommandPalettePresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { runtime.isCommandPalettePresented = false }
                    CommandPalette(runtime: runtime, appActions: paletteActions) {
                        runtime.isCommandPalettePresented = false
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, LingXiMetrics.Space.xxl * 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
        .background { AtmosphereBackdrop() }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: sidebar.isNavigatorVisible)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: inspector.isPresented)
        .animation(LXMotion.animation(LXMotion.disclosure, reduceMotion: reduceMotion), value: runtime.isCommandPalettePresented)
        .toolbar { windowToolbar }
        .navigationTitle(sidebar.workspace.name)
        .frame(minWidth: LingXiMetrics.Split.windowMinWidth, minHeight: LingXiMetrics.Split.windowMinHeight)
        .preferredColorScheme(colorScheme.colorScheme)
    }

    private var navigatorInset: CGFloat {
        LingXiMetrics.Split.navigatorWidth + LingXiMetrics.Split.panelMargin
    }

    private var inspectorInset: CGFloat {
        LingXiMetrics.Split.inspectorWidth + LingXiMetrics.Split.panelMargin
    }

    private var stage: some View {
        MainStageView(runtime: runtime)
    }

    private var navigator: some View {
        SidebarView(runtime: runtime)
            .frame(width: LingXiMetrics.Split.navigatorWidth)
            .lxFloatingPanel(panelMaterial)
    }

    private var inspectorPanel: some View {
        InspectorView(model: inspector,
                      onOpenTraceWindow: onOpenTraceWindow,
                      onRefresh: runtime.refreshRuntimeDetails,
                      onCompact: runtime.compactContext,
                      onTerminateTask: runtime.terminateBackgroundTask)
            .frame(width: LingXiMetrics.Split.inspectorWidth)
            .lxFloatingPanel(panelMaterial)
    }

    /// App-level actions offered in the command palette next to Core commands.
    private var paletteActions: [PaletteAction] {
        var actions = [
            PaletteAction(id: "app.new", title: "新建会话", symbol: "square.and.pencil", shortcut: "⌘N") { runtime.newSession() },
            PaletteAction(id: "app.navigator", title: "显示或隐藏导航面板", symbol: "sidebar.left", shortcut: "⌃⌘S") {
                sidebar.isNavigatorVisible.toggle()
            },
            PaletteAction(id: "app.inspector", title: "显示或隐藏检查器", symbol: "sidebar.right", shortcut: "⌥⌘I") {
                inspector.isPresented.toggle()
            },
            PaletteAction(id: "app.trace", title: "运行轨迹", symbol: "waveform.path.ecg", shortcut: "⌥⌘L", perform: onOpenTraceWindow),
        ]
        if runtime.link == .connected {
            actions += [
                PaletteAction(id: "app.compact", title: "压缩上下文", symbol: "rectangle.compress.vertical") { runtime.compactContext() },
                PaletteAction(id: "app.changes", title: "查看工作区变更", symbol: "plus.forwardslash.minus") {
                    inspector.selectedTab = .changes
                    inspector.isPresented = true
                    runtime.refreshRuntimeDetails()
                },
                PaletteAction(id: "app.stop", title: "停止当前运行", symbol: "stop.circle", shortcut: "⌘.") { runtime.stopGenerating() },
            ]
        }
        #if os(macOS)
        actions.append(PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") { openSettings() })
        #endif
        return actions
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebar.isNavigatorVisible.toggle()
            } label: {
                Label("导航面板", systemImage: "sidebar.left")
            }
            .help("显示或隐藏导航面板 (⌃⌘S)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                inspector.isPresented.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.right")
            }
            .help("显示或隐藏检查器 (⌥⌘I)")
        }
    }
}

#endif
