#if canImport(SwiftUI)
import SwiftUI

/// Main window presentation mode: workspace conversation vs native in-window settings.
public enum MainPresentationMode: Equatable {
    case workspace
    case settings
}

/// Main window: Apple Maps / Xcode style unified NavigationSplitView.
///
/// Architecture Principles:
/// - macOS controls the NavigationSplitView, Sidebar, Inspector, and window toolbar.
/// - LingXiAgent controls the unified Atmosphere ambient backdrop and detail stage.
/// - In-window Settings swaps the Sidebar and Detail in-place without overlay nesting.
public struct MainStageSplitView: View {
    @ObservedObject public var runtime: RuntimeFrontend
    @ObservedObject private var sidebar: SidebarPresentationModel
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    public var settings: SettingsStore?
    public var onOpenTraceWindow: () -> Void

    @State private var selectedSettingsPage: SettingsPage = .general
    @AppStorage(LXPreferenceKey.colorScheme) private var colorScheme = ColorSchemePreference.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        runtime: RuntimeFrontend,
        settings: SettingsStore? = nil,
        onOpenTraceWindow: @escaping () -> Void = {}
    ) {
        self.runtime = runtime
        self.settings = settings
        self.sidebar = runtime.sidebarModel
        self.inspector = runtime.inspectorModel
        self.conversation = runtime.conversationModel
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    private var presentationMode: MainPresentationMode {
        runtime.isShowingSettings ? .settings : .workspace
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebar.isNavigatorVisible ? .all : .detailOnly },
            set: { visibility in
                sidebar.isNavigatorVisible = (visibility != .detailOnly)
            }
        )
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { presentationMode == .workspace && inspector.isPresented },
            set: { isPresented in
                if presentationMode == .workspace {
                    inspector.isPresented = isPresented
                }
            }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            switch presentationMode {
            case .workspace:
                SidebarView(runtime: runtime)
                    .navigationSplitViewColumnWidth(min: 220, ideal: LingXiMetrics.Split.navigatorWidth, max: 340)
            case .settings:
                if let settings {
                    SettingsSidebar(store: settings, selectedPage: $selectedSettingsPage)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                }
            }
        } detail: {
            ZStack {
                switch presentationMode {
                case .workspace:
                    MainStageView(runtime: runtime)
                case .settings:
                    if let settings {
                        SettingsDetailView(store: settings, page: selectedSettingsPage)
                    }
                }

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
            .inspector(isPresented: inspectorBinding) {
                if presentationMode == .workspace {
                    InspectorView(
                        model: inspector,
                        onOpenTraceWindow: onOpenTraceWindow,
                        onRefresh: runtime.refreshRuntimeDetails,
                        onCompact: runtime.compactContext,
                        onTerminateTask: runtime.terminateBackgroundTask
                    )
                    .inspectorColumnWidth(min: 260, ideal: LingXiMetrics.Split.inspectorWidth, max: 380)
                }
            }
        }
        .background {
            // The ONLY ambient atmosphere backdrop instance in the entire window, covering NavigationSplitView
            AtmosphereBackdrop(mode: presentationMode == .settings ? .settings : .workspace)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $runtime.isShowingAboutSheet) {
            CyberAboutSheet(runtime: runtime)
        }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: presentationMode)
        .animation(LXMotion.animation(LXMotion.disclosure, reduceMotion: reduceMotion), value: runtime.isCommandPalettePresented)
        .toolbar { windowToolbar }
        .navigationTitle(navigationTitle)
        .frame(minWidth: LingXiMetrics.Split.windowMinWidth, minHeight: LingXiMetrics.Split.windowMinHeight)
        .preferredColorScheme(colorScheme.colorScheme)
    }

    private var navigationTitle: String {
        switch presentationMode {
        case .workspace:
            return sidebar.workspace.name.isEmpty ? "LingXiAgent" : sidebar.workspace.name
        case .settings:
            return "设置 · \(selectedSettingsPage.title)"
        }
    }

    /// App-level actions offered in the command palette next to Core commands.
    private var paletteActions: [PaletteAction] {
        var actions = [
            PaletteAction(id: "app.new", title: "新建会话", symbol: "square.and.pencil", shortcut: "⌘N") {
                if runtime.isShowingSettings { runtime.isShowingSettings = false }
                runtime.newSession()
            },
            PaletteAction(id: "app.navigator", title: "显示或隐藏导航面板", symbol: "sidebar.left", shortcut: "⌃⌘S") {
                sidebar.isNavigatorVisible.toggle()
            },
            PaletteAction(id: "app.inspector", title: "显示或隐藏检查器", symbol: "sidebar.right", shortcut: "⌥⌘I") {
                if presentationMode == .workspace {
                    inspector.isPresented.toggle()
                }
            },
            PaletteAction(id: "app.trace", title: "运行轨迹", symbol: "waveform.path.ecg", shortcut: "⌥⌘L", perform: onOpenTraceWindow),
        ]
        if runtime.link == .connected && presentationMode == .workspace {
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
        actions.append(PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") {
            runtime.isShowingSettings = true
        })
        #endif
        return actions
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        switch presentationMode {
        case .workspace:
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
            if conversation.isGenerating {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        runtime.stopGenerating()
                    } label: {
                        Label("停止生成", systemImage: "stop.circle.fill")
                    }
                    .help("停止当前生成 (Esc 或 ⌘.)")
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .status) {
                    Button {
                        runtime.stopGenerating()
                    } label: {
                        EmptyView()
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityHidden(true)
                }
            }
        case .settings:
            ToolbarItem(placement: .navigation) {
                Button {
                    runtime.isShowingSettings = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回工作区")
                    }
                }
                .help("返回工作区 (Esc)")
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}
#endif
