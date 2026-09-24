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
}

public extension Color {
    static var lingXiOrange: Color {
        LingXiTheme.accentColor
    }
}
