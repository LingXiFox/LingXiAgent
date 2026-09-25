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

    // MARK: 氛围色（极光渐变与深空基底）

    public static let atmosphereIndigo = Color(.sRGB, red: 0.22, green: 0.28, blue: 0.72)
    public static let atmosphereTeal = Color(.sRGB, red: 0.08, green: 0.58, blue: 0.62)
    public static let atmosphereViolet = Color(.sRGB, red: 0.48, green: 0.24, blue: 0.78)
    public static let atmosphereAmber = Color(.sRGB, red: 0.78, green: 0.36, blue: 0.10)

    // MARK: 华丽赛博宝石色谱 (Cyber Gemstone Palette)

    /// 核心火种 · 狐焰金橙：主操作、品牌光环
    public static let foxfireAmber = Color(.sRGB, red: 1.00, green: 0.44, blue: 0.08)
    /// 生命脉动 · 电光青蓝：运行波形、实时状态、网络吞吐
    public static let electricCyan = Color(.sRGB, red: 0.00, green: 0.88, blue: 0.98)
    /// 极光翡翠 · 霓虹青绿：成功、在线、测试通过
    public static let neonTeal = Color(.sRGB, red: 0.10, green: 0.82, blue: 0.55)
    /// 宇宙神思 · 幻视星轨紫：思考过程、记忆图谱、复杂推理
    public static let astralViolet = Color(.sRGB, red: 0.62, green: 0.38, blue: 0.96)
    /// 决策焦点 · 金曜暖黄：审批、等待人类指示
    public static let solarGold = Color(.sRGB, red: 0.96, green: 0.64, blue: 0.12)
    /// 警示珊瑚 · 霓虹朱红：错误、破坏性操作
    public static let neonCoral = Color(.sRGB, red: 0.98, green: 0.28, blue: 0.34)
    public static let neonPink = neonCoral
    public static let auroraMint = neonTeal
    public static let electricPurple = astralViolet
    public static let quantumBlue = electricCyan
    public static let neonCyan = electricCyan

    /// 赛博深夜深邃底色（比纯黑更具冷光深度的黑曜石暗夜）
    public static var deepNightBackground: Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.035, green: 0.045, blue: 0.080, alpha: 1.0)
                : NSColor(srgbRed: 0.960, green: 0.965, blue: 0.980, alpha: 1.0)
        }))
        #else
        return Color(.sRGB, red: 0.035, green: 0.045, blue: 0.080)
        #endif
    }

    /// 黑曜石半透明水晶板底色（高纯净度与通透感，阻隔底层滚杂文字）
    public static var obsidianSurface: Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 0.88)
                : NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.92)
        }))
        #else
        return Color(.sRGB, red: 0.05, green: 0.07, blue: 0.12, opacity: 0.88)
        #endif
    }

    /// 「沉稳」面板材质的玻璃着色
    static var panelTint: Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.08, green: 0.10, blue: 0.20, alpha: 0.55)
                : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.98, alpha: 0.65)
        }))
        #else
        return Color(.sRGB, red: 0.08, green: 0.10, blue: 0.20, opacity: 0.55)
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

    static var cyberFoxfire: Color {
        LingXiTheme.foxfireAmber
    }

    static var cyberCyan: Color {
        LingXiTheme.electricCyan
    }

    static var cyberTeal: Color {
        LingXiTheme.neonTeal
    }

    static var cyberViolet: Color {
        LingXiTheme.astralViolet
    }

    static var cyberGold: Color {
        LingXiTheme.solarGold
    }
}
