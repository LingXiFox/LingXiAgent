#if canImport(SwiftUI)
import SwiftUI

/// macOS 原生双栏 + 检查器顶层容器视图
/// NavigationSplitView (Sidebar + MainStage) + .inspector(InspectorView)
public struct MainStageSplitView: View {
    @ObservedObject public var runtime: RuntimeFrontend
    public var onOpenTraceWindow: () -> Void

    public init(
        runtime: RuntimeFrontend,
        onOpenTraceWindow: @escaping () -> Void = {}
    ) {
        self.runtime = runtime
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(
                model: runtime.sidebarModel,
                onNewSession: {
                    runtime.newSession()
                },
                onSelectSession: { sessID in
                    runtime.switchSession(id: sessID)
                }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            MainStageView(
                conversationModel: runtime.conversationModel,
                composerModel: runtime.composerModel,
                onSendMessage: { text, mode, atts in
                    runtime.sendMessage(text: text, mode: mode, attachments: atts)
                },
                onStopGenerating: {
                    runtime.stopGenerating()
                },
                onResolveInteraction: { intID, approved in
                    runtime.resolveInteraction(interactionID: intID, approved: approved)
                },
                onFinalizeTask: { action in
                    runtime.finalizeTask(action: action)
                }
            )
            .inspector(isPresented: Binding(
                get: { runtime.inspectorModel.isPresented },
                set: { runtime.inspectorModel.isPresented = $0 }
            )) {
                InspectorView(
                    model: runtime.inspectorModel,
                    onOpenTraceWindow: onOpenTraceWindow
                )
            }
        }
        .accentColor(LingXiTheme.accentColor)
    }
}
#endif
