import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiClient
@testable import LingXiTUIComponents

@Suite struct ReasoningEffortTests {
    @Test func canonicalReasoningEffortEnumCoversAllRequiredLevels() {
        let expected: [ReasoningEffort] = [.off, .minimal, .low, .medium, .high, .xhigh, .max, .ultra, .auto]
        #expect(ReasoningEffort.allCases == expected)
    }

    @Test func resolveEffortKeepsSupportedEffort() {
        let capability = ReasoningCapability(
            mode: .effort,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .medium
        )
        let (effective, message) = capability.resolveEffort(.high)
        #expect(effective == .high)
        #expect(message == nil)
    }

    @Test func resolveEffortAppliesCoarseMappingWithNotice() {
        let capability = ReasoningCapability(
            mode: .effort,
            supportedEfforts: [.low, .high],
            defaultEffort: .low,
            coarseMappings: [.medium: "high", .minimal: "low"]
        )
        let (effective, message) = capability.resolveEffort(.medium)
        #expect(effective == .medium)
        #expect(message?.contains("已映射为: high") == true)
    }

    @Test func resolveEffortFallsBackWhenUnsupported() {
        let capability = ReasoningCapability(
            mode: .adaptive,
            supportedEfforts: [.auto],
            defaultEffort: .auto
        )
        let (effective, message) = capability.resolveEffort(.max)
        #expect(effective == .auto)
        #expect(message?.contains("已回退到模型默认: auto") == true)
    }

    @Test func resolveEffortHandlesNoneModeGracefully() {
        let capability = ReasoningCapability(mode: .none, defaultEffort: .off)
        // off or auto silently resolves
        let (eff1, msg1) = capability.resolveEffort(.off)
        #expect(eff1 == .off && msg1 == nil)

        let (eff2, msg2) = capability.resolveEffort(.auto)
        #expect(eff2 == .off && msg2 == nil)

        // specific effort triggers notice
        let (eff3, msg3) = capability.resolveEffort(.high)
        #expect(eff3 == .off)
        #expect(msg3?.contains("当前模型不支持推理等级调节") == true)
    }

    @Test func sessionStorePersistsReasoningEffort() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        // Default reasoning effort is auto
        #expect(session.reasoningEffort == .auto)

        // Update to high
        _ = try await store.updateReasoningEffort(session.id, effort: .high)

        // Verify updated
        let loaded = try await store.session(session.id)
        #expect(loaded.reasoningEffort == .high)
    }

    @Test func builtinCommandsProvideReasoningAndThinkInspection() async throws {
        // Verify command definitions exist in registry
        let commands = BuiltinCommands.all
        let reasoningCmd = commands.first { $0.name == "reasoning" }
        let thinkCmd = commands.first { $0.name == "think" }

        #expect(reasoningCmd != nil)
        #expect(thinkCmd != nil)
        #expect(reasoningCmd?.argumentSchema == "[effort]")
        #expect(thinkCmd?.aliases.contains("thought") == true)
    }

    @Test func effectiveReasoningEffortFallbackAndPrecedence() {
        var state = ApplicationState()
        #expect(state.effectiveReasoningEffort == .auto)

        state.nextTurnReasoningEffort = .high
        #expect(state.effectiveReasoningEffort == .high)

        state.activeSessionState = SessionViewState(sessionID: SessionID("s1"), reasoningEffort: .low)
        #expect(state.effectiveReasoningEffort == .low)
    }

    @Test func reasoningCommandWorksWithoutActiveSession() async throws {
        let registry = ApplicationCommandRegistry()
        for cmd in BuiltinCommands.createAll() {
            registry.register(cmd)
        }
        let coreHost = try CoreHost()
        let client = try await LingXiClientVNext(transport: InProcessTransport(service: coreHost))
        let state = ApplicationState()

        // 1. Inspect reasoning effort when no active session exists
        let queryResult = try await registry.execute(input: "/reasoning", sessionID: nil, client: client, state: state)
        #expect(queryResult.output.contains("当前生效等级"))
        #expect(queryResult.output.contains("auto"))
        #expect(!queryResult.output.contains("当前无活动会话"))

        // 2. Set reasoning effort when no active session exists
        let setResult = try await registry.execute(input: "/reasoning high", sessionID: nil, client: client, state: state)
        #expect(setResult.nextTurnReasoningEffort == ReasoningEffort.high)
        #expect(setResult.output.contains("思考等级已切换为: high"))

        // 3. /think alias works identically
        let thinkResult = try await registry.execute(input: "/think off", sessionID: nil, client: client, state: state)
        #expect(thinkResult.nextTurnReasoningEffort == ReasoningEffort.off)
        #expect(thinkResult.output.contains("思考等级已切换为: off"))
    }

    @Test func modelCommandShowsCleanCurrentModelAndReasoningEffort() async throws {
        let registry = ApplicationCommandRegistry()
        for cmd in BuiltinCommands.createAll() {
            registry.register(cmd)
        }
        let coreHost = try CoreHost()
        let client = try await LingXiClientVNext(transport: InProcessTransport(service: coreHost))
        let state = ApplicationState(currentModelID: "deepseek-v4-flash", nextTurnReasoningEffort: .medium)

        let result = try await registry.execute(input: "/model", sessionID: nil, client: client, state: state)
        #expect(result.output.contains("当前模型 (/model)"))
        #expect(result.output.contains("deepseek-v4-flash"))
        #expect(result.output.contains("medium"))
        // Does not dump large full list
        #expect(!result.output.contains("可用模型列表 ("))
    }

    @Test func modalOverlayModelSupportsCenteredModalCard() {
        let lines = [
            TUIStyledLine("Select model                                         esc", style: .modalTitle),
            TUIStyledLine("│Search", style: .modalSearchPlaceholder),
            TUIStyledLine("Recent", style: .modalGroup),
            TUIStyledLine("● GPT-5.6 Terra                                  OpenAI", style: .modalActiveDot),
            TUIStyledLine("  GPT-6 Astra LingXiFox API bblabu               OpenAI", style: .modalHighlight)
        ]
        let model = TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: 64)
        #expect(model.isModal == true)
        #expect(model.modalWidth == 64)
        #expect(model.lines.count == 5)
        #expect(model.lines[4].style == .modalHighlight)

        // Verify frame rendering
        let app = TUIApp()
        let frame = app.render(size: TUISize(width: 80, height: 24), overlay: model)
        #expect(frame.cells.count == 80 * 24)
    }
}
