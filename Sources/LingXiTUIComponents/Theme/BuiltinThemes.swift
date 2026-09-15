import Foundation

public enum BuiltinThemes {
    /// 1. 默认暗色：赛博极光星夜狐 (Cyber Fox Dark)
    public static let cyberFoxDark = ThemeDefinition(
        id: "cyber-fox-dark",
        name: "赛博极光星夜狐 (Dark)",
        appearance: .dark,
        author: "LingXi Fox Team",
        palette: ThemePalette(
            pageBg: "#13111C",
            cardBg: "#1E1B29",
            textPrimary: "#F8FAFC",
            textMuted: "#9490A6",
            border: "#3B354D",
            accentPrimary: "#4EECD2",   // 极光薄荷青
            accentSecondary: "#C084FC", // 梦幻樱落紫
            success: "#34D399",
            warning: "#FBBF24",
            error: "#F87171",
            info: "#38BDF8",
            selectedBg: "#312B42"
        )
    )

    /// 2. 默认浅色：暖雪琉璃浅狐 (Pearl Fox Light) - 专为白底浅色终端打造
    public static let pearlFoxLight = ThemeDefinition(
        id: "pearl-fox-light",
        name: "暖雪琉璃浅狐 (Light)",
        appearance: .light,
        author: "LingXi Fox Team",
        palette: ThemePalette(
            pageBg: "#F8FAFC",
            cardBg: "#FFFFFF",
            textPrimary: "#0F172A",
            textMuted: "#64748B",
            border: "#CBD5E1",
            accentPrimary: "#0D9488",   // 浓郁翡翠深青
            accentSecondary: "#9333EA", // 琉璃紫
            success: "#16A34A",
            warning: "#D97706",
            error: "#DC2626",
            info: "#0284C7",
            selectedBg: "#E2E8F0"
        )
    )

    /// 3. Catppuccin Mocha
    public static let catppuccinMocha = ThemeDefinition(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        appearance: .dark,
        author: "Catppuccin Org",
        palette: ThemePalette(
            pageBg: "#1E1E2E",
            cardBg: "#313244",
            textPrimary: "#CDD6F4",
            textMuted: "#A6ADC8",
            border: "#45475A",
            accentPrimary: "#89B4FA",
            accentSecondary: "#F5C2E7",
            success: "#A6E3A1",
            warning: "#F9E2AF",
            error: "#F38BA8",
            info: "#74C7EC",
            selectedBg: "#585B70"
        )
    )

    /// 4. Nord Aurora
    public static let nordAurora = ThemeDefinition(
        id: "nord-aurora",
        name: "Nord Aurora",
        appearance: .dark,
        author: "Arctic Ice Studio",
        palette: ThemePalette(
            pageBg: "#2E3440",
            cardBg: "#3B4252",
            textPrimary: "#ECEFF4",
            textMuted: "#D8DEE9",
            border: "#4C566A",
            accentPrimary: "#88C0D0",
            accentSecondary: "#B48EAD",
            success: "#A3BE8C",
            warning: "#EBCB8B",
            error: "#BF616A",
            info: "#81A1C1",
            selectedBg: "#434C5E"
        )
    )

    /// 5. Dracula
    public static let dracula = ThemeDefinition(
        id: "dracula",
        name: "Dracula Official",
        appearance: .dark,
        author: "Zeno Rocha",
        palette: ThemePalette(
            pageBg: "#282A36",
            cardBg: "#44475A",
            textPrimary: "#F8F8F2",
            textMuted: "#6272A4",
            border: "#6272A4",
            accentPrimary: "#BD93F9",
            accentSecondary: "#FF79C6",
            success: "#50FA7B",
            warning: "#F1FA8C",
            error: "#FF5555",
            info: "#8BE9FD",
            selectedBg: "#44475A"
        )
    )

    /// 6. Monochrome
    public static let monochrome = ThemeDefinition(
        id: "monochrome",
        name: "Monochrome Minimal",
        appearance: .dark,
        author: "LingXi Fox Team",
        palette: ThemePalette(
            pageBg: "#000000",
            cardBg: "#1C1C1C",
            textPrimary: "#FFFFFF",
            textMuted: "#808080",
            border: "#404040",
            accentPrimary: "#FFFFFF",
            accentSecondary: "#D4D4D4",
            success: "#E0E0E0",
            warning: "#C0C0C0",
            error: "#FFFFFF",
            info: "#A0A0A0",
            selectedBg: "#333333"
        )
    )

    public static let all: [ThemeDefinition] = [
        cyberFoxDark,
        pearlFoxLight,
        catppuccinMocha,
        nordAurora,
        dracula,
        monochrome
    ]
}
