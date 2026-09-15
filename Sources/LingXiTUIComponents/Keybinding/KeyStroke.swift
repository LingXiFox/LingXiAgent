import Foundation

/// 键盘修饰键集合 (KeyModifier OptionSet)
public struct KeyModifier: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let ctrl  = KeyModifier(rawValue: 1 << 0)
    public static let alt   = KeyModifier(rawValue: 1 << 1) // Option / Alt
    public static let shift = KeyModifier(rawValue: 1 << 2)
    public static let meta  = KeyModifier(rawValue: 1 << 3) // Cmd / Super / Windows
}

/// 键盘物理或虚拟键码 (KeyCode)
public enum KeyCode: Sendable, Hashable {
    case character(Character)
    case enter
    case escape
    case tab
    case backspace
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case f(Int)
}

/// 规范化键盘按键输入单元 (KeyStroke)
public struct KeyStroke: Sendable, Codable, Hashable, CustomStringConvertible {
    public let code: KeyCode
    public let modifiers: KeyModifier

    public init(code: KeyCode, modifiers: KeyModifier = []) {
        self.code = code
        self.modifiers = modifiers
    }

    /// 从形如 "ctrl+c", "alt+enter", "ctrl+shift+p", "f1", "esc" 的字符串解析
    public init?(from string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods = KeyModifier()
        var keyPart: String? = nil

        for (idx, part) in parts.enumerated() {
            if idx == parts.count - 1 {
                keyPart = part
                break
            }
            switch part {
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "option", "opt": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            case "meta", "cmd", "command", "super": mods.insert(.meta)
            default:
                return nil
            }
        }

        guard let key = keyPart else { return nil }

        let parsedCode: KeyCode
        switch key {
        case "enter", "return": parsedCode = .enter
        case "esc", "escape": parsedCode = .escape
        case "tab": parsedCode = .tab
        case "backspace", "bs": parsedCode = .backspace
        case "delete", "del": parsedCode = .delete
        case "up": parsedCode = .up
        case "down": parsedCode = .down
        case "left": parsedCode = .left
        case "right": parsedCode = .right
        case "home": parsedCode = .home
        case "end": parsedCode = .end
        case "pageup", "pgup": parsedCode = .pageUp
        case "pagedown", "pgdn": parsedCode = .pageDown
        default:
            if key.hasPrefix("f"), let num = Int(key.dropFirst()), num >= 1, num <= 12 {
                parsedCode = .f(num)
            } else if key.count == 1, let char = key.first {
                parsedCode = .character(char)
            } else {
                return nil
            }
        }

        self.code = parsedCode
        self.modifiers = mods
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.ctrl) { parts.append("Ctrl") }
        if modifiers.contains(.alt) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.meta) { parts.append("Cmd") }

        switch code {
        case .character(let c): parts.append(String(c).uppercased())
        case .enter: parts.append("Enter")
        case .escape: parts.append("Esc")
        case .tab: parts.append("Tab")
        case .backspace: parts.append("Backspace")
        case .delete: parts.append("Delete")
        case .up: parts.append("Up")
        case .down: parts.append("Down")
        case .left: parts.append("Left")
        case .right: parts.append("Right")
        case .home: parts.append("Home")
        case .end: parts.append("End")
        case .pageUp: parts.append("PageUp")
        case .pageDown: parts.append("PageDown")
        case .f(let n): parts.append("F\(n)")
        }

        return parts.joined(separator: "+")
    }

    // MARK: - Codable (按标准可读字符串序列化/反序列化)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let parsed = KeyStroke(from: str) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid keystroke format: \(str)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description.lowercased())
    }
}
