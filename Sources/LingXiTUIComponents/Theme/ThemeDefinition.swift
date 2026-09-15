import Foundation

/// 外观模式 (AppearanceMode)
public enum AppearanceMode: String, Sendable, Codable, CaseIterable {
    case dark  = "dark"
    case light = "light"
}

/// 语义颜色值 (StyleColor)
public struct StyleColor: Sendable, Codable, Equatable {
    public let fg: String // 十六进制，如 "#FFFFFF"
    public let bg: String // 十六进制，如 "#13111C"

    public init(fg: String, bg: String) {
        self.fg = fg
        self.bg = bg
    }
}

/// 原始基础调色板 (ThemePalette)
public struct ThemePalette: Sendable, Codable, Equatable {
    public var pageBg: String
    public var cardBg: String
    public var textPrimary: String
    public var textMuted: String
    public var border: String
    public var accentPrimary: String   // 主色调 (如极光青/梦幻紫)
    public var accentSecondary: String // 辅助强调 (如樱落粉/琥珀金)
    public var success: String
    public var warning: String
    public var error: String
    public var info: String
    public var selectedBg: String

    public init(
        pageBg: String,
        cardBg: String,
        textPrimary: String,
        textMuted: String,
        border: String,
        accentPrimary: String,
        accentSecondary: String,
        success: String,
        warning: String,
        error: String,
        info: String,
        selectedBg: String
    ) {
        self.pageBg = pageBg
        self.cardBg = cardBg
        self.textPrimary = textPrimary
        self.textMuted = textMuted
        self.border = border
        self.accentPrimary = accentPrimary
        self.accentSecondary = accentSecondary
        self.success = success
        self.warning = warning
        self.error = error
        self.info = info
        self.selectedBg = selectedBg
    }
}

/// 主题定义 (ThemeDefinition)
public struct ThemeDefinition: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let appearance: AppearanceMode
    public let author: String?
    public var palette: ThemePalette
    public var customOverrides: [String: StyleColor]?

    public init(
        id: String,
        name: String,
        appearance: AppearanceMode,
        author: String? = nil,
        palette: ThemePalette,
        customOverrides: [String: StyleColor]? = nil
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.author = author
        self.palette = palette
        self.customOverrides = customOverrides
    }

    /// 十六进制色彩转换为 24-bit TrueColor OpenTUIColorValue
    public static func hexToColor(_ hex: String) -> OpenTUIColorValue {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var intVal: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&intVal)

        let r, g, b: UInt16
        switch clean.count {
        case 3: // RGB (12-bit)
            r = UInt16((intVal >> 8) * 17)
            g = UInt16((intVal >> 4 & 0xF) * 17)
            b = UInt16((intVal & 0xF) * 17)
        case 6: // RGB (24-bit)
            r = UInt16(intVal >> 16)
            g = UInt16(intVal >> 8 & 0xFF)
            b = UInt16(intVal & 0xFF)
        default:
            r = 255; g = 255; b = 255
        }
        return OpenTUIColorValue(red: r * 257, green: g * 257, blue: b * 257)
    }

    /// 解析指定 TUIStyle 对应的渲染前背景色
    public func styleColor(for style: TUIStyle) -> (foreground: OpenTUIColorValue, background: OpenTUIColorValue) {
        let cPageBg = Self.hexToColor(palette.pageBg)
        let cCardBg = Self.hexToColor(palette.cardBg)
        let cText = Self.hexToColor(palette.textPrimary)
        let cTextMuted = Self.hexToColor(palette.textMuted)
        let cBorder = Self.hexToColor(palette.border)
        let cAccent1 = Self.hexToColor(palette.accentPrimary)
        let cAccent2 = Self.hexToColor(palette.accentSecondary)
        let cSuccess = Self.hexToColor(palette.success)
        let cWarning = Self.hexToColor(palette.warning)
        let cError = Self.hexToColor(palette.error)
        let cInfo = Self.hexToColor(palette.info)
        let cSelected = Self.hexToColor(palette.selectedBg)

        // 自定义覆盖检查
        if let overrides = customOverrides,
           let custom = overrides[String(describing: style)] {
            return (Self.hexToColor(custom.fg), Self.hexToColor(custom.bg))
        }

        switch style {
        case .normal: return (cText, cPageBg)
        case .dim: return (cTextMuted, cPageBg)
        case .accent: return (cAccent1, cPageBg)
        case .inverse: return (cPageBg, cText)
        case .composer, .composerText: return (cText, cCardBg)
        case .composerPlaceholder: return (cTextMuted, cCardBg)
        case .overlay, .overlayItem: return (cText, cCardBg)
        case .overlayTitle: return (cAccent1, cCardBg)
        case .overlayItemDim: return (cTextMuted, cCardBg)
        case .overlayHighlight: return (cPageBg, cAccent2)
        case .warning: return (cWarning, cPageBg)
        case .error: return (cError, cPageBg)
        case .modalTitle: return (cText, cCardBg)
        case .modalGroup: return (cWarning, cCardBg)
        case .modalHighlight: return (cPageBg, cAccent2)
        case .modalActiveDot: return (cAccent2, cCardBg)
        case .modalItem: return (cText, cCardBg)
        case .modalItemDim: return (cTextMuted, cCardBg)
        case .modalBackground: return (cText, cCardBg)
        case .modalBorder: return (cBorder, cCardBg)
        case .modalSearchPlaceholder: return (cTextMuted, cCardBg)
        case .selected: return (cText, cSelected)
        case .heroLogo: return (cAccent1, cPageBg)
        case .heroBoxBg: return (cText, cCardBg)
        case .heroBoxBorder: return (cAccent1, cCardBg)
        case .heroBoxPlaceholder: return (cTextMuted, cCardBg)
        case .heroBoxText: return (cText, cCardBg)
        case .heroBoxMeta: return (cTextMuted, cCardBg)
        case .heroMode: return (cAccent1, cCardBg)
        case .heroTip: return (cWarning, cPageBg)
        case .sidebarHeader: return (cAccent1, cPageBg)
        case .sidebarLabel: return (cTextMuted, cPageBg)
        case .sidebarProgressFill: return (cAccent1, cPageBg)
        case .sidebarProgressTrack: return (cTextMuted, cPageBg)
        case .sidebarTaskPending: return (cTextMuted, cPageBg)
        case .sidebarTaskInProgress: return (cInfo, cPageBg)
        case .sidebarTaskCompleted: return (cSuccess, cPageBg)
        case .sidebarTaskFailed: return (cError, cPageBg)
        case .sidebarMcpReady: return (cSuccess, cPageBg)
        case .sidebarMcpAuth: return (cWarning, cPageBg)
        case .sidebarMcpError: return (cError, cPageBg)
        case .toolDotSuccess: return (cSuccess, cPageBg)
        case .toolDotActive: return (cWarning, cPageBg)
        case .toolDotError: return (cError, cPageBg)
        case .toolAction: return (cWarning, cPageBg)
        case .toolCommand, .toolArg: return (cInfo, cPageBg)
        case .toolTree, .toolSubtext, .toolDiffLine: return (cTextMuted, cPageBg)
        case .toolDiffAdd: return (cSuccess, cPageBg)
        case .toolDiffRemove: return (cError, cPageBg)
        case .thinkingHeader: return (cAccent1, cPageBg)
        case .thinkingBody: return (cTextMuted, cPageBg)
        case .assistantText: return (cText, cPageBg)
        case .badgeYolo: return (cAccent1, cCardBg)
        case .badgeAsk: return (cAccent2, cCardBg)
        case .mascotBody: return (cText, cPageBg)
        case .mascotEar: return (cAccent2, cPageBg)
        case .mascotSpark: return (cAccent1, cPageBg)
        case .mascotTag: return (cAccent1, cPageBg)
        case .systemNotice: return (cAccent1, cPageBg)
        }
    }
}
