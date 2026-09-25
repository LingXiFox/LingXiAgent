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
    public var settings: SettingsStore?
    public var onOpenTraceWindow: () -> Void

    @AppStorage(LXPreferenceKey.panelMaterial) private var panelMaterial = PanelMaterialPreference.clear
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

    public var body: some View {
        GeometryReader { geo in
            let reservesInspector = inspector.isPresented
                && geo.size.width >= LingXiMetrics.Split.inspectorDockMinWidth

            ZStack {
                stage
                    .padding(.leading, sidebar.isNavigatorVisible ? navigatorInset : 0)
                    .padding(.trailing, reservesInspector ? inspectorInset : 0)

                // 底部两侧的悬浮晶体药丸栏（复刻参考图美学）
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if !sidebar.isNavigatorVisible {
                            FloatingStatusPill(isGenerating: conversation.isGenerating,
                                               link: runtime.link)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                        Spacer()
                        if !inspector.isPresented {
                            FloatingUtilityPill(onOpenTrace: onOpenTraceWindow,
                                                onOpenPalette: { runtime.isCommandPalettePresented.toggle() })
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .padding(.horizontal, LingXiMetrics.Space.lg)
                    .padding(.bottom, LingXiMetrics.Space.lg)
                }
                .allowsHitTesting(true)

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

                if runtime.isShowingSettings, let settings {
                    FullstageSettingsView(store: settings, onBack: {
                        runtime.isShowingSettings = false
                    })
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }
            }
        }
        .background { AtmosphereBackdrop() }
        .sheet(isPresented: $runtime.isShowingAboutSheet) {
            CyberAboutSheet(runtime: runtime)
        }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: sidebar.isNavigatorVisible)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: inspector.isPresented)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: runtime.isShowingSettings)
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
        actions.append(PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") {
            runtime.isShowingSettings = true
        })
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

private struct FloatingStatusPill: View {
    let isGenerating: Bool
    let link: RuntimeFrontend.Link

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Circle()
                .fill(isGenerating ? LingXiTheme.neonTeal : (link == .connected ? LingXiTheme.electricCyan : Color.secondary))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(isGenerating ? LingXiTheme.neonTeal.opacity(0.4) : Color.clear, lineWidth: 2)
                        .scaleEffect(isGenerating ? 1.5 : 1.0)
                )
                .lxNeonGlow(color: isGenerating ? LingXiTheme.neonTeal : LingXiTheme.electricCyan, radius: 4)

            Text(isGenerating ? "Running" : (link == .connected ? "Online" : "Offline"))
                .font(.lxCallout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.xs + 2)
        .background {
            Capsule()
                .fill(LingXiTheme.obsidianSurface)
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .lxNeonGlow(color: isGenerating ? LingXiTheme.neonTeal : Color.clear, radius: 6, opacity: 0.3)
    }
}

private struct FloatingUtilityPill: View {
    var onOpenTrace: () -> Void
    var onOpenPalette: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Button(action: onOpenTrace) {
                Image(systemName: "waveform.path.ecg")
                    .font(.lxCallout)
                    .foregroundStyle(LingXiTheme.electricCyan)
            }
            .buttonStyle(.plain)
            .help("运行轨迹 (⌥⌘L)")

            Divider()
                .frame(height: 12)

            Button(action: onOpenPalette) {
                Image(systemName: "command")
                    .font(.lxCallout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("命令面板 (⌘K)")
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.xs + 2)
        .background {
            Capsule()
                .fill(LingXiTheme.obsidianSurface)
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }
}

#endif
