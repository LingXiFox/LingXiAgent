#if os(macOS)
import SwiftUI
import AppKit
import LingXiFrontendKit

@main
public struct LingXiMacApp: App {
    @StateObject private var runtime = RuntimeFrontend()
    @StateObject private var settings = SettingsStore()
    @Environment(\.openWindow) private var openWindow

    public init() {}

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
        // Main workspace window: full-bleed stage, floating panels, titleless toolbar.
        WindowGroup {
            MainStageSplitView(
                runtime: runtime,
                settings: settings,
                onOpenTraceWindow: {
                    openWindow(id: "trace-window")
                }
            )
            .environment(\.timelineDisclosureDefaults, settings.timelineDisclosureDefaults)
            .transparentWindowToolbar()
            .task {
                settings.runtime = runtime
                let defaults = settings.composerDefaults
                runtime.composerModel.applyDefaults(mode: defaults.mode,
                                                    reasoning: defaults.reasoning,
                                                    permission: defaults.permission)
                await reopenLastWorkspaceIfWanted()
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .commands {
            LingXiMenuCommands(runtime: runtime, onOpenTraceWindow: {
                openWindow(id: "trace-window")
            })
        }

        // 独立非模态运行轨迹窗口
        WindowGroup("运行轨迹", id: "trace-window") {
            TraceWindowView(model: runtime.inspectorModel)
        }
    }
}

private extension View {
    /// Lets the backdrop show through the toolbar so items float as glass over it.
    @ViewBuilder
    func transparentWindowToolbar() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

/// macOS 标准主菜单命令集 (遵循规范第四章)
public struct LingXiMenuCommands: Commands {
    @ObservedObject public var runtime: RuntimeFrontend
    public var onOpenTraceWindow: () -> Void

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 LingXi…") {
                runtime.isShowingAboutSheet = true
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                runtime.isShowingSettings = true
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

        CommandMenu("视图") {
            Toggle("显示导航面板", isOn: Binding(
                get: { runtime.sidebarModel.isNavigatorVisible },
                set: { runtime.sidebarModel.isNavigatorVisible = $0 }
            ))
            .keyboardShortcut("s", modifiers: [.control, .command])

            Toggle("显示检查器", isOn: Binding(
                get: { runtime.inspectorModel.isPresented },
                set: { runtime.inspectorModel.isPresented = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.option, .command])

            Divider()

            ForEach(Array(InspectorTab.allCases.enumerated()), id: \.element) { index, tab in
                Button("检查器 · \(tab.displayName)") {
                    runtime.inspectorModel.selectedTab = tab
                    runtime.inspectorModel.isPresented = true
                }
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

            Button("快速侧问浮窗") {
                QuickAskPanelController.shared.show(onSubmit: { question in
                    await runtime.submitSideQuestion(question: question)
                })
            }
            .keyboardShortcut(.space, modifiers: .option)
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
