import SwiftUI

#if os(iOS)
@main
public struct LingXiIOSApp: App {
    @State private var runtime = FakeFrontendRuntime()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    LingXiGlass.Palette.deepBackground
                        .ignoresSafeArea()

                    ConversationTimelineView(model: runtime.conversationModel)

                    FloatingComposerView(model: runtime.composerModel) { text, mode, attachments in
                        runtime.sendMessage(text: text, mode: mode, attachments: attachments)
                    }
                }
                .navigationTitle("LingXi")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
#endif
