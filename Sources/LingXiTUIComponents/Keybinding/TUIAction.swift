import Foundation

/// TUI 标准交互动作标识 (TUIAction)
public enum TUIAction: String, Sendable, Codable, CaseIterable {
    // 全局动作
    case interrupt            = "tui.interrupt"
    case quit                 = "tui.quit"
    case commandPalette       = "tui.commandPalette"
    case toggleTheme          = "tui.theme.toggle"
    case cycleReasoningEffort = "agent.cycleReasoning"
    case clearScreen          = "tui.clearScreen"
    case showHelp             = "tui.showHelp"

    // 输入区动作 (Composer)
    case submit               = "composer.submit"
    case newLine              = "composer.newLine"
    case deleteWordBackward   = "composer.deleteWordBackward"
    case historyPrevious      = "composer.historyPrev"
    case historyNext          = "composer.historyNext"
    case escapeOrCancel       = "composer.escape"

    // 模态/浮层动作 (Modal / Floating / Picker)
    case modalClose           = "modal.close"
    case modalConfirm         = "modal.confirm"
    case modalNext            = "modal.next"
    case modalPrevious        = "modal.prev"
    case modalPageUp          = "modal.pageUp"
    case modalPageDown        = "modal.pageDown"

    public var displayName: String {
        switch self {
        case .interrupt: return "Interrupt / Cancel Current Run"
        case .quit: return "Quit Application"
        case .commandPalette: return "Open Command Palette"
        case .toggleTheme: return "Switch / Toggle Theme"
        case .cycleReasoningEffort: return "Cycle Reasoning Effort"
        case .clearScreen: return "Clear Screen"
        case .showHelp: return "Show Keybindings Help"
        case .submit: return "Send Message / Submit"
        case .newLine: return "Insert Newline"
        case .deleteWordBackward: return "Delete Word Backward"
        case .historyPrevious: return "Previous History Item"
        case .historyNext: return "Next History Item"
        case .escapeOrCancel: return "Escape / Clear"
        case .modalClose: return "Close Modal"
        case .modalConfirm: return "Confirm Selection"
        case .modalNext: return "Next Item"
        case .modalPrevious: return "Previous Item"
        case .modalPageUp: return "Page Up"
        case .modalPageDown: return "Page Down"
        }
    }
}

/// 快捷键生效上下文命名空间 (KeybindingContext)
public enum KeybindingContext: String, Sendable, Codable, Hashable {
    case global   = "global"
    case composer = "composer"
    case modal    = "modal"
    case picker   = "picker"
}
