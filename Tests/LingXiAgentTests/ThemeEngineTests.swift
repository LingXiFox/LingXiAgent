import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiTUIComponents
@testable import LingXiTUI

@Suite("Theme Engine Tests")
struct ThemeEngineTests {

    @Test("Hex to 24-bit TrueColor OpenTUIColorValue conversion")
    func testHexColorConversion() throws {
        // 纯白 #FFFFFF -> 65535, 65535, 65535
        let white = ThemeDefinition.hexToColor("#FFFFFF")
        #expect(white.red == 65535)
        #expect(white.green == 65535)
        #expect(white.blue == 65535)

        // 纯黑 #000000 -> 0, 0, 0
        let black = ThemeDefinition.hexToColor("#000000")
        #expect(black.red == 0)
        #expect(black.green == 0)
        #expect(black.blue == 0)

        // 3位简写 #F00 (红)
        let red3 = ThemeDefinition.hexToColor("#F00")
        #expect(red3.red == 65535)
        #expect(red3.green == 0)
        #expect(red3.blue == 0)
    }

    @Test("6 Builtin themes are fully defined and resolve all TUIStyle semantic roles safely")
    func testBuiltinThemesIntegrity() throws {
        let allThemes = BuiltinThemes.all
        #expect(allThemes.count >= 6)

        let allStyles: [TUIStyle] = [
            .normal, .dim, .accent, .inverse, .composer, .composerText, .composerPlaceholder,
            .overlay, .overlayTitle, .overlayItem, .overlayItemDim, .overlayHighlight,
            .warning, .error, .modalTitle, .modalGroup, .modalHighlight, .modalActiveDot,
            .modalItem, .modalItemDim, .modalBackground, .modalBorder, .modalSearchPlaceholder,
            .selected, .heroLogo, .heroBoxBorder, .heroBoxBg, .heroBoxPlaceholder,
            .heroBoxText, .heroBoxMeta, .heroMode, .heroTip, .sidebarHeader, .sidebarLabel,
            .sidebarProgressFill, .sidebarProgressTrack, .sidebarTaskPending, .sidebarTaskInProgress,
            .sidebarTaskCompleted, .sidebarTaskFailed, .sidebarMcpReady, .sidebarMcpAuth,
            .sidebarMcpError, .toolDotSuccess, .toolDotActive, .toolDotError, .toolAction,
            .toolCommand, .toolArg, .toolTree, .toolSubtext, .toolDiffAdd, .toolDiffRemove,
            .toolDiffLine, .thinkingHeader, .thinkingBody, .assistantText, .badgeYolo,
            .badgeAsk, .mascotBody, .mascotEar, .mascotSpark, .mascotTag, .systemNotice
        ]

        for theme in allThemes {
            #expect(!theme.id.isEmpty)
            #expect(!theme.name.isEmpty)
            for style in allStyles {
                let colorPair = theme.styleColor(for: style)
                // 确保前后景色正常生成，无越界与空指针
                #expect(colorPair.foreground.red <= 65535)
                #expect(colorPair.background.red <= 65535)
            }
        }
    }

    @Test("ThemeManager switches themes dynamically and triggers observers")
    func testThemeManagerSwitching() throws {
        let manager = ThemeManager.shared

        var observedTheme: ThemeDefinition? = nil
        manager.addObserver { theme in
            observedTheme = theme
        }

        // 切换到浅色主题
        let switchLight = manager.setTheme(by: "pearl-fox-light")
        #expect(switchLight == true)
        #expect(manager.currentTheme.id == "pearl-fox-light")
        #expect(manager.currentTheme.appearance == .light)
        #expect(observedTheme?.id == "pearl-fox-light")

        // 模糊匹配切换到 catppuccin
        let switchCatppuccin = manager.setTheme(by: "catppuccin")
        #expect(switchCatppuccin == true)
        #expect(manager.currentTheme.id == "catppuccin-mocha")

        // 切回默认暗色
        let switchDark = manager.setTheme(by: "dark")
        #expect(switchDark == true)
        #expect(manager.currentTheme.id == "cyber-fox-dark")
    }

    @Test("ThemeDefinition JSON serialization and custom overrides")
    func testThemeDefinitionJSON() throws {
        let customJSON = """
        {
            "id": "custom-neon",
            "name": "Custom Neon",
            "appearance": "dark",
            "palette": {
                "pageBg": "#0A0A0F",
                "cardBg": "#14141E",
                "textPrimary": "#FFFFFF",
                "textMuted": "#707080",
                "border": "#2A2A3C",
                "accentPrimary": "#00FFCC",
                "accentSecondary": "#FF007F",
                "success": "#00FF66",
                "warning": "#FFCC00",
                "error": "#FF3366",
                "info": "#00CCFF",
                "selectedBg": "#202030"
            },
            "customOverrides": {
                "badgeYolo": {
                    "fg": "#000000",
                    "bg": "#00FFCC"
                }
            }
        }
        """

        let data = Data(customJSON.utf8)
        let theme = try JSONDecoder().decode(ThemeDefinition.self, from: data)

        #expect(theme.id == "custom-neon")
        #expect(theme.appearance == .dark)

        // 检查普通样式
        let normalColor = theme.styleColor(for: .normal)
        let expectedBg = ThemeDefinition.hexToColor("#0A0A0F")
        #expect(normalColor.background.red == expectedBg.red)

        // 检查覆盖样式 badgeYolo
        let badgeColor = theme.styleColor(for: .badgeYolo)
        #expect(badgeColor.foreground.red == 0) // 黑
    }
}
