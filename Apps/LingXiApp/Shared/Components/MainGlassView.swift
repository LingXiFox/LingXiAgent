#if canImport(SwiftUI)
import SwiftUI

public struct MainGlassView: View {
    public let runtime: FakeFrontendRuntime

    public init(runtime: FakeFrontendRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: runtime.sidebarModel, runtime: runtime) { sessionID in
                runtime.conversationModel.sessionID = sessionID
            }
        } content: {
            ZStack(alignment: .bottom) {
                // Background Glass
                LingXiGlass.Palette.deepBackground
                    .ignoresSafeArea()

                // Conversation Timeline
                ConversationTimelineView(model: runtime.conversationModel)

                // Floating Composer
                FloatingComposerView(model: runtime.composerModel) { text, mode, attachments in
                    runtime.sendMessage(text: text, mode: mode, attachments: attachments)
                }
            }
            .frame(minWidth: 400)
        } detail: {
            RuntimeInspectorView(model: runtime.inspectorModel)
        }
        .lingXiGlass(tier: .window, cornerRadius: 0)
    }
}
#endif
