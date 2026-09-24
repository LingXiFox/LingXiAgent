import SwiftUI

#if os(iOS)
@main
public struct LingXiIOSApp: App {
    @StateObject private var runtime = RuntimeFrontend()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            NavigationStack {
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
                .navigationTitle("LingXi Agent")
                .navigationBarTitleDisplayMode(.inline)
            }
            .accentColor(LingXiTheme.accentColor)
        }
    }
}
#endif
