#if os(macOS)
import SwiftUI
import AppKit

public struct LingXiWorkbenchScene: Scene {
    @StateObject private var runtime = RuntimeFrontend()
    @StateObject private var settings = SettingsStore()
    @StateObject private var navigation = WarmNavigation()
    @Environment(\.openWindow) private var openWindow

    public init() {
        // One window, no document tabs: keeps 「显示」 free of tab-bar commands.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Reopens the most recent workspace at launch unless the user turned it off.
    @MainActor
    private func reopenLastWorkspaceIfWanted() async {
        let defaults = UserDefaults.standard
        let wanted = defaults.object(forKey: LXPreferenceKey.reopenLastWorkspace) as? Bool ?? true
        guard wanted, runtime.link == .disconnected,
              let last = RecentWorkspaces.all.first,
              FileManager.default.fileExists(atPath: last.path) else { return }
        await runtime.openWorkspace(last)
    }

    public var body: some Scene {
        WindowGroup {
            WarmWorkbench(runtime: runtime, settings: settings, navigation: navigation)
            .modifier(WallpaperWindow())
            .background(WorkbenchWindowPlacement())
            .environment(\.timelineDisclosureDefaults, settings.timelineDisclosureDefaults)
            .task {
                settings.runtime = runtime
                let defaults = settings.composerDefaults
                runtime.composerModel.applyDefaults(mode: defaults.mode,
                                                    reasoning: defaults.reasoning,
                                                    permission: defaults.permission)
                await reopenLastWorkspaceIfWanted()
            }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1460, height: 900)
        .commands {
            LingXiMenuCommands(runtime: runtime, navigation: navigation, onOpenTraceWindow: {
                openWindow(id: "trace-window")
            }, onOpenContextInspector: {
                openWindow(id: "context-inspector")
            })
        }

        // 独立非模态运行轨迹窗口
        WindowGroup("运行轨迹", id: "trace-window") {
            TraceWindowView(model: runtime.inspectorModel) { await runtime.refreshTrace() }
                .tint(LXColor.accent)
        }

        // §8: the session's P/E runtime inspector. A window rather than a sidebar block, because
        // §30 freezes the 运行上下文 card and lists Context Search as a detail surface.
        WindowGroup("上下文检查器", id: "context-inspector") {
            ContextInspectorView(runtime: runtime)
                .tint(LXColor.accent)
        }
    }
}

/// Fill the display's usable area once, preserving the menu bar and Dock.
struct WorkbenchWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) {}

    final class PlacementView: NSView {
        private var hasPlacedWindow = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !hasPlacedWindow else { return }
            hasPlacedWindow = true
            // Apply after SwiftUI restores the initial window geometry.
            DispatchQueue.main.async {
                guard let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true)
            }
        }
    }
}

/// macOS 标准主菜单命令集 (遵循规范第四章)
public struct LingXiMenuCommands: Commands {
    @ObservedObject public var runtime: RuntimeFrontend
    @ObservedObject public var navigation: WarmNavigation
    public var onOpenTraceWindow: () -> Void
    public var onOpenContextInspector: () -> Void

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 LingXiAgent…") {
                navigation.showAbout()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                navigation.showsSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("新建会话") {
                runtime.newSession()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("打开工作区…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "打开"
                if panel.runModal() == .OK, let url = panel.url {
                    Task { await runtime.openWorkspace(url) }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // The system View menu (「显示」): navigator, the three tool panels, palettes.
        CommandGroup(before: .toolbar) {
            Toggle("显示导航面板", isOn: Binding(
                get: { runtime.sidebarModel.isNavigatorVisible },
                set: { runtime.sidebarModel.isNavigatorVisible = $0 }
            ))
            .keyboardShortcut("s", modifiers: [.control, .command])

            Divider()

            ForEach(Array(WarmTool.allCases.enumerated()), id: \.element) { index, tool in
                Toggle("\(tool.title)面板", isOn: Binding(
                    get: { navigation.selectedTool == tool },
                    set: { _ in navigation.toggle(tool) }
                ))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.option, .command])
            }

            Divider()

            Button("命令面板…") {
                runtime.isCommandPalettePresented.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("运行轨迹…") {
                onOpenTraceWindow()
            }
            .keyboardShortcut("l", modifiers: [.option, .command])

            Button("上下文检查器…") {
                onOpenContextInspector()
            }
            .keyboardShortcut("j", modifiers: [.option, .command])

            Button("快速侧问浮窗") {
                QuickAskPanelController.shared.show(onSubmit: { question in
                    await runtime.submitSideQuestion(question: question)
                })
            }
            .keyboardShortcut(.space, modifiers: .option)

            Divider()
            Button("选择背景图片…") { WallpaperBackdrop.chooseImage() }
            Button("恢复内置背景") {
                UserDefaults.standard.removeObject(forKey: WallpaperBackdrop.pathKey)
            }

            Divider()
        }

        CommandMenu("Agent") {
            Button("停止当前运行") {
                runtime.stopGenerating()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!runtime.conversationModel.isGenerating)

            Button("压缩上下文") {
                runtime.compactContext()
            }
            .disabled(runtime.link != .connected)

            Button("刷新工作区变更") {
                runtime.refreshRuntimeDetails()
            }
            .disabled(runtime.link != .connected)
        }
    }
}
#endif
