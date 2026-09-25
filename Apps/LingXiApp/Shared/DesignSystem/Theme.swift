import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 灵犀 Agent macOS 原生设计主题
/// 遵循 macOS HIG 规范：语义色优先、暖墨底、单品牌强调色（狐橙）
public enum LingXiTheme {
    /// 狐橙单强调色：深色 #EE6725 / 浅色 #C24A14
    public static var accentColor: Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                return NSColor(srgbRed: 0xEE / 255.0, green: 0x67 / 255.0, blue: 0x25 / 255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xC2 / 255.0, green: 0x4A / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
            }
        }))
        #else
        return Color(red: 0xEE / 255.0, green: 0x67 / 255.0, blue: 0x25 / 255.0)
        #endif
    }

    /// 暖墨底主背景色
    public static var windowBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    /// 面板/次级卡片背景
    public static var surfaceBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    /// 次级文字说明色
    public static var secondaryText: Color {
        #if os(macOS)
        return Color(nsColor: .secondaryLabelColor)
        #else
        return Color(UIColor.secondaryLabel)
        #endif
    }

    /// 三级说明：工具行副标题、占位文案
    public static var tertiaryText: Color {
        #if os(macOS)
        return Color(nsColor: .tertiaryLabelColor)
        #else
        return Color(UIColor.tertiaryLabel)
        #endif
    }

    // MARK: 氛围色（低饱和冷色，仅用于背景光与面板着色）

    static let atmosphereIndigo = Color(.sRGB, red: 0.30, green: 0.36, blue: 0.86)
    static let atmosphereTeal = Color(.sRGB, red: 0.16, green: 0.62, blue: 0.66)
    static let atmosphereViolet = Color(.sRGB, red: 0.52, green: 0.36, blue: 0.82)

    /// 「沉稳」面板材质的玻璃着色
    static var panelTint: Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.24, alpha: 0.45)
                : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.98, alpha: 0.55)
        }))
        #else
        return Color(.sRGB, red: 0.10, green: 0.12, blue: 0.24, opacity: 0.45)
        #endif
    }

    /// 四级弱显：计数、单位、被抑制项
    public static var quaternaryText: Color {
        #if os(macOS)
        return Color(nsColor: .quaternaryLabelColor)
        #else
        return Color(UIColor.quaternaryLabel)
        #endif
    }
}

public extension Color {
    static var lingXiOrange: Color {
        LingXiTheme.accentColor
    }
}
