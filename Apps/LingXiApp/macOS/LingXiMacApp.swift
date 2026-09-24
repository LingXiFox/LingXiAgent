#if os(macOS)
import SwiftUI
import AppKit
import LingXiFrontendKit

@main
public struct LingXiMacApp: App {
    @StateObject private var runtime = RuntimeFrontend()
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Scene {
        // 主工作台窗口
        WindowGroup {
            MainStageSplitView(
                runtime: runtime,
                onOpenTraceWindow: {
                    openWindow(id: "trace-window")
                }
            )
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            LingXiMenuCommands(runtime: runtime, onOpenTraceWindow: {
                openWindow(id: "trace-window")
            })
        }

        // macOS 标准偏好设置窗口 (⌘,)
        Settings {
            SettingsView(runtime: runtime)
        }

        // 独立非模态运行轨迹窗口
        WindowGroup("运行轨迹", id: "trace-window") {
            TraceWindowView(model: runtime.inspectorModel)
        }
    }
}

/// macOS 标准主菜单命令集 (遵循规范第四章)
public struct LingXiMenuCommands: Commands {
    @ObservedObject public var runtime: RuntimeFrontend
    public var onOpenTraceWindow: () -> Void

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建会话") {
                runtime.newSession()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("视图") {
            Button("概览 (Overview)") {
                runtime.inspectorModel.selectedTab = .overview
                runtime.inspectorModel.isPresented = true
            }
            .keyboardShortcut("1", modifiers: [.option, .command])

            Button("Agent 设定") {
                runtime.inspectorModel.selectedTab = .agent
                runtime.inspectorModel.isPresented = true
            }
            .keyboardShortcut("2", modifiers: [.option, .command])

            Button("子任务与 Worktree") {
                runtime.inspectorModel.selectedTab = .tasks
                runtime.inspectorModel.isPresented = true
            }
            .keyboardShortcut("3", modifiers: [.option, .command])

            Button("网关授权 (Capabilities)") {
                runtime.inspectorModel.selectedTab = .capabilities
                runtime.inspectorModel.isPresented = true
            }
            .keyboardShortcut("4", modifiers: [.option, .command])

            Divider()

            Toggle("显示检查器", isOn: Binding(
                get: { runtime.inspectorModel.isPresented },
                set: { runtime.inspectorModel.isPresented = $0 }
            ))
                .keyboardShortcut("i", modifiers: [.option, .command])

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

        CommandMenu("任务") {
            Button("接受本次变更 (Accept)") {
                runtime.finalizeTask(action: .accept)
            }

            Button("标记完成 (Finish)") {
                runtime.finalizeTask(action: .finish)
            }

            Divider()

            Button("放弃并回滚 (Discard)", role: .destructive) {
                runtime.finalizeTask(action: .discard)
            }
        }
    }
}
#endif
