import Foundation

/// 快捷键分发中枢 (KeybindingDispatcher)
public final class KeybindingDispatcher: @unchecked Sendable {
    public static let shared = KeybindingDispatcher()

    private let registry: KeybindingRegistry
    private var contextStack: [KeybindingContext] = [.global]
    private let lock = NSLock()

    public init(registry: KeybindingRegistry = .shared) {
        self.registry = registry
    }

    /// 进入子上下文（例如进入模态或 Picker）
    public func pushContext(_ context: KeybindingContext) {
        lock.withLock {
            contextStack.append(context)
        }
    }

    /// 退出当前子上下文
    public func popContext() {
        lock.withLock {
            if contextStack.count > 1 {
                contextStack.removeLast()
            }
        }
    }

    /// 获取当前生效的上下文
    public var currentContext: KeybindingContext {
        lock.withLock {
            contextStack.last ?? .global
        }
    }

    /// 将按键解析为对应的动作
    public func dispatch(stroke: KeyStroke) -> TUIAction? {
        let ctx = currentContext
        return registry.resolveAction(for: stroke, in: ctx)
    }

    /// 将旧版 TUIInputEvent 映射到 KeyStroke 便于统一接入快捷键引擎
    public static func toKeyStroke(from event: TUIInputEvent) -> KeyStroke? {
        switch event {
        case .character(let c):
            return KeyStroke(code: .character(c))
        case .enter:
            return KeyStroke(code: .enter)
        case .shiftEnter:
            return KeyStroke(code: .enter, modifiers: .shift)
        case .escape:
            return KeyStroke(code: .escape)
        case .tab:
            return KeyStroke(code: .tab)
        case .shiftTab:
            return KeyStroke(code: .tab, modifiers: .shift)
        case .backspace:
            return KeyStroke(code: .backspace)
        case .delete:
            return KeyStroke(code: .delete)
        case .deleteWordBackward:
            return KeyStroke(code: .character("w"), modifiers: .ctrl)
        case .up:
            return KeyStroke(code: .up)
        case .down:
            return KeyStroke(code: .down)
        case .left:
            return KeyStroke(code: .left)
        case .right:
            return KeyStroke(code: .right)
        case .home:
            return KeyStroke(code: .home)
        case .end:
            return KeyStroke(code: .end)
        case .pageUp:
            return KeyStroke(code: .pageUp)
        case .pageDown:
            return KeyStroke(code: .pageDown)
        case .interrupt:
            return KeyStroke(code: .character("c"), modifiers: .ctrl)
        case .quit:
            return KeyStroke(code: .character("d"), modifiers: .ctrl)
        case .commandPalette:
            return KeyStroke(code: .character("p"), modifiers: .ctrl)
        case .cycleReasoningEffort:
            return KeyStroke(code: .character("t"), modifiers: .ctrl)
        default:
            return nil
        }
    }
}
