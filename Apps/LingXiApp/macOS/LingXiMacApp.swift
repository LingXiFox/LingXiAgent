import SwiftUI

#if os(macOS)
@main
public struct LingXiMacApp: App {
    @State private var runtime = FakeFrontendRuntime()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainGlassView(runtime: runtime)
                .frame(minWidth: 900, minHeight: 600)
                .background(LingXiGlass.Palette.deepBackground)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

/// 自动化活动 HUD 悬浮指示器（Phase 0 预留组件，规范第 118 节）
public struct AutomationActivityHUD: View {
    public let isAutomating: Bool
    public let currentAction: String

    public init(isAutomating: Bool = false, currentAction: String = "Idle") {
        self.isAutomating = isAutomating
        self.currentAction = currentAction
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isAutomating ? LingXiGlass.Palette.foxOrange : LingXiGlass.Palette.matrixGreen)
                .frame(width: 8, height: 8)
            Text("AUTOMATION HUD: \(currentAction)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(LingXiGlass.Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .lingXiGlass(tier: .floating, cornerRadius: 8)
    }
}
#endif
