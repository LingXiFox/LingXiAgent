import SwiftUI

/// GUI-only preferences (UserDefaults). Each one is read by the view that
/// honours it; nothing here is stored without a consumer.
public enum LXPreferenceKey {
    public static let colorScheme = "lx.appearance.colorScheme"
    public static let atmosphere = "lx.appearance.atmosphere"
    public static let panelMaterial = "lx.appearance.panelMaterial"
    public static let sendKey = "lx.conversation.sendKey"
    public static let preventSleepWhileRunning = "lx.general.preventSleepWhileRunning"
    public static let reopenLastWorkspace = "lx.general.reopenLastWorkspace"
    public static let dockPanels = "lx.workbench.dock.panels"
    public static let dockVisible = "lx.workbench.dock.visible"
}

public enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum AtmospherePreference: String, CaseIterable, Identifiable {
    case off, subtle, rich
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "关闭"
        case .subtle: return "柔和"
        case .rich: return "浓郁"
        }
    }

    /// Multiplier on the backdrop glow opacities. `subtle` carries the design
    /// system token alphas verbatim, so `rich` may not exceed 1.5× it.
    var strength: Double {
        switch self {
        case .off: return 0
        case .subtle: return 1
        case .rich: return 1.5
        }
    }
}

public enum PanelMaterialPreference: String, CaseIterable, Identifiable {
    case clear, tinted
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .clear: return "通透"
        case .tinted: return "沉稳"
        }
    }
}

public enum SendKeyPreference: String, CaseIterable, Identifiable {
    case returnKey, commandReturn
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .returnKey: return "⏎ 发送，⇧⏎ 换行"
        case .commandReturn: return "⌘⏎ 发送，⏎ 换行"
        }
    }
}
