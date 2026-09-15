import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiTUIComponents
@testable import LingXiTUI

@Suite("Keybinding Engine Tests")
struct KeybindingEngineTests {

    @Test("KeyStroke parses single and modifier key combinations faithfully")
    func testKeyStrokeParsing() throws {
        // 1. 单键解析
        let enterKey = try #require(KeyStroke(from: "enter"))
        #expect(enterKey.code == .enter)
        #expect(enterKey.modifiers.isEmpty)
        #expect(enterKey.description == "Enter")

        let escKey = try #require(KeyStroke(from: "esc"))
        #expect(escKey.code == .escape)

        let charKey = try #require(KeyStroke(from: "a"))
        #expect(charKey.code == .character("a"))

        let fKey = try #require(KeyStroke(from: "F5"))
        #expect(fKey.code == .f(5))

        // 2. 组合键解析
        let ctrlC = try #require(KeyStroke(from: "ctrl+c"))
        #expect(ctrlC.code == .character("c"))
        #expect(ctrlC.modifiers.contains(.ctrl))
        #expect(ctrlC.description == "Ctrl+C")

        let altEnter = try #require(KeyStroke(from: "alt+enter"))
        #expect(altEnter.code == .enter)
        #expect(altEnter.modifiers.contains(.alt))
        #expect(altEnter.description == "Alt+Enter")

        let ctrlShiftP = try #require(KeyStroke(from: "ctrl+shift+p"))
        #expect(ctrlShiftP.code == .character("p"))
        #expect(ctrlShiftP.modifiers.contains([.ctrl, .shift]))
        #expect(ctrlShiftP.description == "Ctrl+Shift+P")

        // 3. 空白与未知过滤
        #expect(KeyStroke(from: "") == nil)
        #expect(KeyStroke(from: "unknownmodifier+enter") == nil)
    }

    @Test("KeyStroke Codable serialization round-trip")
    func testKeyStrokeCodable() throws {
        let original = try #require(KeyStroke(from: "ctrl+shift+p"))
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(jsonString == "\"ctrl+shift+p\"")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KeyStroke.self, from: data)
        #expect(decoded == original)
    }

    @Test("KeybindingRegistry resolves context-sensitive actions and default mappings")
    func testKeybindingResolution() throws {
        let registry = KeybindingRegistry()
        registry.loadDefaultBindings()

        // 1. Composer 范围
        let enter = try #require(KeyStroke(from: "enter"))
        #expect(registry.resolveAction(for: enter, in: .composer) == .submit)

        let shiftEnter = try #require(KeyStroke(from: "shift+enter"))
        #expect(registry.resolveAction(for: shiftEnter, in: .composer) == .newLine)

        let altEnter = try #require(KeyStroke(from: "alt+enter"))
        #expect(registry.resolveAction(for: altEnter, in: .composer) == .newLine)

        // 2. Modal 范围
        let esc = try #require(KeyStroke(from: "esc"))
        #expect(registry.resolveAction(for: esc, in: .modal) == .modalClose)

        // 3. 全局动作回退测试
        let ctrlC = try #require(KeyStroke(from: "ctrl+c"))
        #expect(registry.resolveAction(for: ctrlC, in: .composer) == .interrupt)
        #expect(registry.resolveAction(for: ctrlC, in: .modal) == .interrupt)
        #expect(registry.resolveAction(for: ctrlC, in: .global) == .interrupt)

        let ctrlT = try #require(KeyStroke(from: "ctrl+t"))
        #expect(registry.resolveAction(for: ctrlT, in: .composer) == .toggleTheme)

        let f1 = try #require(KeyStroke(from: "f1"))
        #expect(registry.resolveAction(for: f1, in: .global) == .showHelp)
    }

    @Test("KeybindingRegistry accepts user overrides dynamically")
    func testUserOverrides() throws {
        let registry = KeybindingRegistry()
        registry.loadDefaultBindings()

        // 覆盖 composer.submit 改为 ctrl+j
        registry.applyUserOverrides(from: [
            "composer.submit": ["ctrl+j"]
        ])

        let ctrlJ = try #require(KeyStroke(from: "ctrl+j"))
        #expect(registry.resolveAction(for: ctrlJ, in: .composer) == .submit)
    }

    @Test("KeybindingDispatcher context stack management and input event bridging")
    func testDispatcherContextAndBridging() throws {
        let dispatcher = KeybindingDispatcher()

        #expect(dispatcher.currentContext == .global)

        dispatcher.pushContext(.composer)
        #expect(dispatcher.currentContext == .composer)

        dispatcher.pushContext(.modal)
        #expect(dispatcher.currentContext == .modal)

        dispatcher.popContext()
        #expect(dispatcher.currentContext == .composer)

        // 桥接测试
        let strokeFromInterrupt = KeybindingDispatcher.toKeyStroke(from: .interrupt)
        #expect(strokeFromInterrupt?.description == "Ctrl+C")

        let strokeFromShiftEnter = KeybindingDispatcher.toKeyStroke(from: .shiftEnter)
        #expect(strokeFromShiftEnter?.description == "Shift+Enter")
    }
}
