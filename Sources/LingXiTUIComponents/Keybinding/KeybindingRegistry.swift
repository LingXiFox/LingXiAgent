import Foundation

/// 单条快捷键规则 (KeybindingRule)
public struct KeybindingRule: Sendable, Codable, Equatable {
    public let stroke: KeyStroke
    public let action: TUIAction
    public let context: KeybindingContext

    public init(stroke: KeyStroke, action: TUIAction, context: KeybindingContext = .global) {
        self.stroke = stroke
        self.action = action
        self.context = context
    }
}

/// 快捷键注册与管理中枢 (KeybindingRegistry)
public final class KeybindingRegistry: @unchecked Sendable {
    public static let shared = KeybindingRegistry()

    private var rules: [KeybindingRule] = []
    private let lock = NSLock()

    public init() {
        loadDefaultBindings()
    }

    /// 加载系统默认键位映射
    public func loadDefaultBindings() {
        lock.withLock {
            self.rules = Self.makeDefaultRules()
        }
    }

    /// 重新加载或应用用户自定义配置 (JSON 格式字典，形如 {"composer.submit": ["enter", "ctrl+j"]})
    public func applyUserOverrides(from dictionary: [String: [String]]) {
        lock.withLock {
            for (actionRaw, strokeStrings) in dictionary {
                guard let action = TUIAction(rawValue: actionRaw) else { continue }
                for strokeStr in strokeStrings {
                    if let stroke = KeyStroke(from: strokeStr) {
                        // 推导默认上下文
                        let context = Self.defaultContext(for: action)
                        // 替换同 context 下的既有映射
                        self.rules.removeAll { $0.context == context && $0.stroke == stroke }
                        self.rules.append(KeybindingRule(stroke: stroke, action: action, context: context))
                    }
                }
            }
        }
    }

    /// 尝试从磁盘配置文件加载 (~/.lingxiagent/keybindings.json)
    public func loadFromConfigFile(at fileURL: URL? = nil) {
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            url = home.appendingPathComponent(".lingxiagent/keybindings.json")
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bindings = json["bindings"] as? [String: [String]] else {
            return
        }

        applyUserOverrides(from: bindings)
    }

    /// 根据当前上下文与按键查找对应的动作
    public func resolveAction(for stroke: KeyStroke, in context: KeybindingContext) -> TUIAction? {
        lock.withLock {
            // 1. 优先在当前特定上下文中匹配
            if let matched = rules.first(where: { $0.context == context && $0.stroke == stroke }) {
                return matched.action
            }
            // 2. 如果不是全局上下文，回退至全局上下文匹配
            if context != .global {
                return rules.first(where: { $0.context == .global && $0.stroke == stroke })?.action
            }
            return nil
        }
    }

    /// 获取所有生效的键位规则（用于动态帮助面板展示）
    public func allRules() -> [KeybindingRule] {
        lock.withLock {
            self.rules
        }
    }

    private static func defaultContext(for action: TUIAction) -> KeybindingContext {
        switch action {
        case .submit, .newLine, .deleteWordBackward, .historyPrevious, .historyNext, .escapeOrCancel:
            return .composer
        case .modalClose, .modalConfirm, .modalNext, .modalPrevious, .modalPageUp, .modalPageDown:
            return .modal
        default:
            return .global
        }
    }

    private static func makeDefaultRules() -> [KeybindingRule] {
        var list: [KeybindingRule] = []

        // 全局动作 (Global)
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("c"), modifiers: .ctrl), action: .interrupt, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("d"), modifiers: .ctrl), action: .quit, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("p"), modifiers: .ctrl), action: .commandPalette, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("k"), modifiers: .ctrl), action: .commandPalette, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("t"), modifiers: .ctrl), action: .toggleTheme, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("l"), modifiers: .ctrl), action: .clearScreen, context: .global))
        list.append(KeybindingRule(stroke: KeyStroke(code: .f(1)), action: .showHelp, context: .global))

        // 输入框动作 (Composer)
        list.append(KeybindingRule(stroke: KeyStroke(code: .enter), action: .submit, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .enter, modifiers: .shift), action: .newLine, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .enter, modifiers: .alt), action: .newLine, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .character("w"), modifiers: .ctrl), action: .deleteWordBackward, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .up), action: .historyPrevious, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .down), action: .historyNext, context: .composer))
        list.append(KeybindingRule(stroke: KeyStroke(code: .escape), action: .escapeOrCancel, context: .composer))

        // 模态/浮层动作 (Modal / Picker)
        list.append(KeybindingRule(stroke: KeyStroke(code: .escape), action: .modalClose, context: .modal))
        list.append(KeybindingRule(stroke: KeyStroke(code: .enter), action: .modalConfirm, context: .modal))
        list.append(KeybindingRule(stroke: KeyStroke(code: .down), action: .modalNext, context: .modal))
        list.append(KeybindingRule(stroke: KeyStroke(code: .up), action: .modalPrevious, context: .modal))
        list.append(KeybindingRule(stroke: KeyStroke(code: .pageDown), action: .modalPageDown, context: .modal))
        list.append(KeybindingRule(stroke: KeyStroke(code: .pageUp), action: .modalPageUp, context: .modal))

        return list
    }
}
