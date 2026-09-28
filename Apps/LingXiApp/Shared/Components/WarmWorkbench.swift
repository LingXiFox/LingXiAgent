#if os(macOS)
import SwiftUI
import LingXiApplication

public enum WarmTool: String, CaseIterable, Identifiable {
    case browser, terminal, git
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .browser: "浏览器"
        case .terminal: "终端"
        case .git: "Git"
        }
    }
    var symbol: String {
        switch self {
        case .browser: "safari"
        case .terminal: "terminal"
        case .git: "arrow.triangle.branch"
        }
    }
}

@MainActor
public final class WarmNavigation: ObservableObject {
    @Published public var showsSettings = false
    @Published public var selectedTool: WarmTool?
    @Published public var showsContext = true
    @Published var settingsPage: SettingsPage = .general
    public init() {}
    public func toggle(_ tool: WarmTool) { selectedTool = selectedTool == tool ? nil : tool }
    public func showAbout() {
        settingsPage = .about
        showsSettings = true
    }
}

public struct WarmWorkbench: View {
    @ObservedObject private var runtime: RuntimeFrontend
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var navigation: WarmNavigation
    @ObservedObject private var sidebar: SidebarPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @AppStorage(LXPreferenceKey.colorScheme) private var colorScheme = ColorSchemePreference.system
    @AppStorage("lingxi.toolPanelWidth") private var savedToolWidth = Double(LingXiMetrics.Size.toolPanel)
    @State private var dragStartWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(runtime: RuntimeFrontend, settings: SettingsStore, navigation: WarmNavigation) {
        self.runtime = runtime
        self.settings = settings
        self.navigation = navigation
        self.sidebar = runtime.sidebarModel
        self.conversation = runtime.conversationModel
        self.inspector = runtime.inspectorModel
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(runtime: runtime)
                .navigationSplitViewColumnWidth(min: LingXiMetrics.Size.navigatorMin,
                                                ideal: LingXiMetrics.Size.navigator,
                                                max: LingXiMetrics.Size.navigator + LingXiMetrics.Space.xxxl)
        } detail: {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    MainStageView(runtime: runtime)
                        .environment(\.stageTrailingReserve, compactHUD(for: geometry.size.width) ?
                                     0 : LingXiMetrics.Size.statusHUD + 2 * LingXiMetrics.Space.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if runtime.link == .connected {
                                AgentStatusHUD(runtime: runtime, compact: compactHUD(for: geometry.size.width)) {
                                    navigation.showsContext.toggle()
                                }
                                .padding(.top, LingXiMetrics.Space.md)
                                .padding(.trailing, LingXiMetrics.Space.md)
                            }
                        }

                    if let tool = navigation.selectedTool {
                        Rectangle()
                            .fill(LXColor.separator)
                            .frame(width: 4)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if dragStartWidth == nil { dragStartWidth = CGFloat(savedToolWidth) }
                                    savedToolWidth = Double(min(LingXiMetrics.Size.toolPanelMax,
                                                                max(LingXiMetrics.Size.toolPanelMin,
                                                                    (dragStartWidth ?? LingXiMetrics.Size.toolPanel) - value.translation.width)))
                                }
                                .onEnded { _ in dragStartWidth = nil })
                            .help("拖动调整工具面板宽度")
                        WarmToolPane(tool: tool, runtime: runtime) { navigation.selectedTool = nil }
                            .frame(width: min(CGFloat(savedToolWidth),
                                              max(LingXiMetrics.Size.toolPanelMin,
                                                  geometry.size.width - LingXiMetrics.Size.toolRail -
                                                  LingXiMetrics.Size.stageWithToolMin)))
                    }
                    toolRail
                }
                .background(LXColor.window)
                .overlay { if runtime.isCommandPalettePresented { palette } }
                .onChange(of: navigation.selectedTool) { _, selected in
                    if selected != nil && geometry.size.width < 1024 {
                        sidebar.isNavigatorVisible = false
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(sessionTitle)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: runtime.newSession) { Label("新建会话", systemImage: "square.and.pencil") }
                    .disabled(runtime.link != .connected)
            }
        }
        .sheet(isPresented: $navigation.showsSettings, onDismiss: { runtime.isShowingSettings = false }) {
            SettingsWorkbench(store: settings, page: $navigation.settingsPage)
        }
        .frame(minWidth: navigation.selectedTool == nil ? LingXiMetrics.Size.windowMinWidth :
               LingXiMetrics.Size.windowWithToolMin,
               minHeight: LingXiMetrics.Size.windowMinHeight)
        .preferredColorScheme(colorScheme.colorScheme)
        .tint(LXColor.accent)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: navigation.selectedTool)
        .onChange(of: runtime.isShowingSettings) { _, open in
            if open { navigation.showsSettings = true }
        }
        .onChange(of: navigation.showsSettings) { _, open in
            runtime.isShowingSettings = open
            if open, navigation.settingsPage.needsCore { Task { await settings.refresh() } }
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebar.isNavigatorVisible ? .all : .detailOnly },
                set: { sidebar.isNavigatorVisible = $0 != .detailOnly })
    }

    private func compactHUD(for width: CGFloat) -> Bool {
        !navigation.showsContext || navigation.selectedTool != nil || width < 1000
    }

    private var sessionTitle: String {
        guard let id = sidebar.selectedSessionID,
              let session = sidebar.allSessions.first(where: { $0.id == id }), !session.title.isEmpty
        else { return "新会话" }
        return session.title
    }

    private var subtitle: String {
        if runtime.link != .connected { return "未连接 Core" }
        if conversation.items.contains(where: {
            if case .interaction(let card) = $0.kind { return card.status == .pending }
            return false
        }) { return "等待你的决定" }
        if conversation.isGenerating { return "执行中" }
        return [sidebar.workspace.name, sidebar.workspace.gitBranch]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var toolRail: some View {
        VStack(spacing: LingXiMetrics.Space.sm) {
            ForEach(WarmTool.allCases) { tool in
                Button { navigation.toggle(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: LXIcon.toolbar))
                        .foregroundStyle(navigation.selectedTool == tool ? LXColor.accentText : .secondary)
                        .frame(width: LXControl.toolbarWidth, height: LXControl.toolbarWidth)
                        .background(navigation.selectedTool == tool ? LXColor.fillControl : .clear,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control))
                        .overlay(alignment: .topTrailing) {
                            if tool == .terminal && agentUsesTerminal {
                                Circle().fill(LXColor.running)
                                    .frame(width: LXControl.dot, height: LXControl.dot)
                            } else if tool == .git, let count = inspector.live?.changes.count, count > 0 {
                                Text(count > 99 ? "99+" : "\(count)")
                                    .font(LXType.micro)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 3)
                                    .background(LXColor.fillControl, in: Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tool.title)
                .accessibilityLabel("打开\(tool.title)面板")
                .accessibilityValue(navigation.selectedTool == tool ? "已展开" : "已收起")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, LingXiMetrics.Space.md)
        .frame(width: LingXiMetrics.Size.toolRail)
        .background(LXColor.window)
        .overlay(alignment: .leading) { LXHairline() }
    }

    private var agentUsesTerminal: Bool {
        inspector.live?.activeTools.contains(where: { tool in
            ["shell", "terminal", "exec", "command"].contains(where: { name in
                tool.localizedCaseInsensitiveContains(name)
            })
        }) ?? false
    }

    private var palette: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001).onTapGesture { runtime.isCommandPalettePresented = false }
            CommandPalette(runtime: runtime, appActions: paletteActions) {
                runtime.isCommandPalettePresented = false
            }
            .padding(.top, LingXiMetrics.Space.xxxxl)
        }
    }

    private var paletteActions: [PaletteAction] {
        var actions = [
            PaletteAction(id: "app.new", title: "新建会话", symbol: "square.and.pencil", shortcut: "⌘N") { runtime.newSession() },
            PaletteAction(id: "app.context", title: "显示或隐藏运行上下文", symbol: "gauge.with.dots.needle.50percent", shortcut: "⌥⌘I") {
                navigation.showsContext.toggle()
            },
            PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") {
                navigation.showsSettings = true
            },
        ]
        for tool in WarmTool.allCases {
            actions.append(PaletteAction(id: "tool.\(tool.rawValue)", title: "打开\(tool.title)", symbol: tool.symbol) {
                navigation.toggle(tool)
            })
        }
        actions.append(PaletteAction(id: "app.tasks", title: "查看任务", symbol: "checklist") {
            runtime.isShowingTasks = true
        })
        if runtime.link == .connected {
            actions.append(PaletteAction(id: "app.compact", title: "压缩上下文", symbol: "rectangle.compress.vertical") {
                runtime.compactContext()
            })
            actions.append(PaletteAction(id: "app.stop", title: "停止当前运行", symbol: "stop.circle", shortcut: "⌘.") {
                runtime.stopGenerating()
            })
        }
        return actions
    }
}
#endif
