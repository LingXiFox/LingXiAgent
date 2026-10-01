import SwiftUI

/// GUI-only preferences (UserDefaults). Each one is read by the view that
/// honours it; nothing here is stored without a consumer.
public enum LXPreferenceKey {
    public static let colorScheme = "lx.appearance.colorScheme"
    public static let sendKey = "lx.conversation.sendKey"
    public static let preventSleepWhileRunning = "lx.general.preventSleepWhileRunning"
    public static let reopenLastWorkspace = "lx.general.reopenLastWorkspace"
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
