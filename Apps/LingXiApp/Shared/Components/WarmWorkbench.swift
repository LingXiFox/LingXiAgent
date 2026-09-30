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
        case .browser: "globe"
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
    @AppStorage("lingxi.toolPanelWidth") private var savedToolWidth = Double(LingXiMetrics.Size.toolPanel)
    @State private var dragStartWidth: CGFloat?
    @State private var showsCompactContext = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(runtime: RuntimeFrontend, settings: SettingsStore, navigation: WarmNavigation) {
        self.runtime = runtime
        self.settings = settings
        self.navigation = navigation
        self.sidebar = runtime.sidebarModel
        self.conversation = runtime.conversationModel
        self.inspector = runtime.inspectorModel
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { window in
                HStack(spacing: 0) {
                    if sidebar.isNavigatorVisible {
                        SidebarView(runtime: runtime)
                            .frame(width: LingXiMetrics.Size.navigator)
                    }
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            MainStageView(runtime: runtime)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .topTrailing) {
                                    if runtime.link == .connected && compactHUD(for: geometry.size.width) {
                                        AgentStatusHUD(runtime: runtime, compact: true) {
                                            if canFitContext(for: geometry.size.width) {
                                                navigation.showsContext = true
                                            } else {
                                                showsCompactContext = true
                                            }
                                        }
                                        .padding(.top, LingXiMetrics.Space.md)
                                        .padding(.trailing, LingXiMetrics.Space.md)
                                        .popover(isPresented: $showsCompactContext, arrowEdge: .leading) {
                                            AgentStatusHUD(runtime: runtime, compact: false) {
                                                showsCompactContext = false
                                            }
                                            .frame(height: 400)
                                        }
                                    }
                                }

                            if runtime.link == .connected && !compactHUD(for: geometry.size.width) {
                                AgentStatusHUD(runtime: runtime, compact: false) {
                                    navigation.showsContext = false
                                }
                                .padding(.leading, LingXiMetrics.Space.sm)
                                .padding(.vertical, LingXiMetrics.Space.sm)
                            }

                            if let tool = navigation.selectedTool {
                                // The 8pt gap between stage and panel is the resize handle.
                                Color.clear
                                    .frame(width: LingXiMetrics.Space.sm)
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            if dragStartWidth == nil { dragStartWidth = CGFloat(savedToolWidth) }
                                            savedToolWidth = Double(min(LingXiMetrics.Size.toolPanelMax,
                                                                        max(LingXiMetrics.Size.toolPanelMin,
                                                                            (dragStartWidth ?? LingXiMetrics.Size.toolPanel) - value.translation.width)))
                                        }
                                        .onEnded { _ in dragStartWidth = nil })
                                    .onHover { inside in
                                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                    }
                                    .help("拖动调整工具面板宽度")
                                WarmToolPane(tool: tool, runtime: runtime) { navigation.selectedTool = nil }
                                    .frame(width: min(CGFloat(savedToolWidth),
                                                      max(LingXiMetrics.Size.toolPanelMin,
                                                          geometry.size.width - LingXiMetrics.Size.toolRail -
                                                          LingXiMetrics.Size.stageWithToolMin)))
                                    .padding(.vertical, LingXiMetrics.Space.sm)
                            }
                            toolRail
                                .padding(.horizontal, LingXiMetrics.Space.sm)
                                .padding(.vertical, LingXiMetrics.Space.sm)
                        }
                        .background(windowBackground)
                        .overlay { if runtime.isCommandPalettePresented { palette } }
                        .onChange(of: navigation.selectedTool) { _, selected in
                            if selected != nil && geometry.size.width < 1024 {
                                sidebar.isNavigatorVisible = false
                            }
                        }
                    }
                    .frame(width: window.size.width - (sidebar.isNavigatorVisible ? LingXiMetrics.Size.navigator : 0))
                }
                .frame(width: window.size.width, height: window.size.height)
                .background(windowBackground)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(sessionTitle)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebar.isNavigatorVisible.toggle()
                } label: {
                    Label("显示或隐藏侧栏", systemImage: "sidebar.left")
                }
                .help(sidebar.isNavigatorVisible ? "隐藏侧栏" : "显示侧栏")
            }
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
        .preferredColorScheme(.dark)
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

    private var windowBackground: Color {
        reduceTransparency ? LXColor.window : .clear
    }

    /// Preserve a readable column before showing the docked context pane.
    private func compactHUD(for width: CGFloat) -> Bool {
        !navigation.showsContext || !canFitContext(for: width)
    }

    private func canFitContext(for width: CGFloat) -> Bool {
        let toolWidth = navigation.selectedTool == nil ? 0 : CGFloat(savedToolWidth) + LingXiMetrics.Space.sm
        let stage = width - LingXiMetrics.Size.toolRail - 2 * LingXiMetrics.Space.sm - toolWidth
        return stage >= LingXiMetrics.Column.dockedMinimum + 2 * LingXiMetrics.Column.gutter +
            LingXiMetrics.Size.statusHUD + LingXiMetrics.Space.sm
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

    /// size-rail 44: the same floating panel as the sidebar (bg-window, 1px
    /// separator, radius-panel), always present. Open tool = neutral fill-control
    /// + accent-text glyph, the navigator's selection rule.
    private var toolRail: some View {
        VStack(spacing: LingXiMetrics.Space.xs) {
            ForEach(WarmTool.allCases) { tool in
                let isOpen = navigation.selectedTool == tool
                Button { navigation.toggle(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: LXIcon.row))
                        .foregroundStyle(isOpen ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
                        .frame(width: LXControl.toolbarWidth, height: LXControl.toolbarWidth)
                        .background(isOpen ? LXColor.fillControl : .clear,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) { railBadge(for: tool) }
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (⌥⌘\(WarmTool.allCases.firstIndex(of: tool)! + 1))")
                .accessibilityLabel("\(tool.title)面板")
                .accessibilityValue(isOpen ? "已展开" : "已收起")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, LingXiMetrics.Space.sm)
        .frame(width: LingXiMetrics.Size.toolRail - 2)
        .frame(maxHeight: .infinity)
        .lxPanel(LXColor.window)
    }

    /// Terminal: 6pt running dot while the agent runs a process. Git: neutral
    /// count of uncommitted changes.
    @ViewBuilder
    private func railBadge(for tool: WarmTool) -> some View {
        if tool == .terminal && agentUsesTerminal {
            Circle().fill(LXColor.running)
                .frame(width: LXControl.dot, height: LXControl.dot)
                .offset(x: -2, y: 2)
                .accessibilityLabel("Agent 正在使用终端")
        } else if tool == .git, let count = inspector.live?.changes.count, count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(LXType.micro)
                .foregroundStyle(.primary)
                .padding(.horizontal, LingXiMetrics.Space.xs)
                .frame(minWidth: 16, minHeight: 16)
                .background(LXColor.elevated, in: Capsule())
                .overlay { Capsule().strokeBorder(LXColor.separator, lineWidth: 1) }
                .offset(x: 6, y: -4)
                .accessibilityLabel("\(count) 个未提交改动")
        }
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
            PaletteAction(id: "app.settings", title: "设置", symbol: "gearshape", shortcut: "⌘,") {
                navigation.showsSettings = true
            },
        ]
        for tool in WarmTool.allCases {
            let index = WarmTool.allCases.firstIndex(of: tool)! + 1
            actions.append(PaletteAction(id: "tool.\(tool.rawValue)", title: "\(tool.title)面板", symbol: tool.symbol,
                                         shortcut: "⌥⌘\(index)") {
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
