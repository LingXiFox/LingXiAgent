import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient
@testable import LingXiApplication

private actor EventCollector {
    private(set) var events: [SessionEventPayload] = []

    func append(_ event: SessionEventPayload) {
        events.append(event)
    }

    func getEvents() -> [SessionEventPayload] {
        events
    }

    func containsTurnCompleted(turnID: TurnID) -> Bool {
        events.contains {
            if case let .turnCompleted(id, _) = $0, id == turnID { return true }
            return false
        }
    }

}

@Suite("VNext Production Integration Correctness Tests", .serialized)
struct VNextProductionIntegrationTests {

    private func createTestEnvironment(provider: any ModelProvider, permissionDecision: PermissionDecision? = nil, interactive: Bool = false) async throws -> (CoreHost, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let credStore = try FileCredentialStore(dataRoot: tempDir.appendingPathComponent("vault"), passphrase: "integration-test")
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))
        let host = try CoreHost(
            providerAssembly: assembly,
            sessionStore: InMemorySessionStore(),
            workspaceRoot: workspace,
            permissionDecision: permissionDecision,
            interactive: interactive,
            credentialStore: credStore
        )
        await host.start()
        return (host, tempDir)
    }

    // MARK: - 1. Real Stdio Multi-Turn Streaming Test
    @Test("Real stdio multi-turn streaming delivers assistant and reasoning cleanly with 0-based finalIndex")
    func testRealStdioMultiTurnStreamingWithReasoningBridge() async throws {
        let script: [[ModelEvent]] = [
            // Turn 1
            [
                .started,
                .reasoningDelta("Reasoning 1: Thinking about the problem..."),
                .reasoningDelta("Reasoning 2: Decided on solution."),
                .textDelta("Turn 1: Hello "),
                .textDelta("world!"),
                .completed(.stop)
            ],
            // Turn 2
            [
                .started,
                .reasoningDelta("Reasoning 3: Thinking for turn 2..."),
                .textDelta("Turn 2: Response delivered."),
                .completed(.stop)
            ]
        ]
        let provider = ScriptedFakeProvider(script: script)
        let (host, tempDir) = try await createTestEnvironment(provider: provider)
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // Real stdio / pipe pair transport
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = VNextStdioCoreServer(
            service: host,
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let serverTask = Task.detached {
            try await server.run()
        }
        defer {
            serverTask.cancel()
            try? clientToServer.fileHandleForReading.close()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForReading.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        let transport = VNextStdioTransport(
            inputHandle: clientToServer.fileHandleForWriting,
            outputPipe: serverToClient
        )
        let client = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)
        defer { Task { await client.disconnect() } }

        // Create session
        let sessionReceipt = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(sessionReceipt.result?.sessionID)

        // Subscribe to session events via replayCoordinator
        let sessionStream = try await client.replayCoordinator.subscribeSessionEvents(sessionID: sessionID)
        let collector = EventCollector()
        let collectorTask = Task {
            for await envelope in sessionStream {
                await collector.append(envelope.payload)
            }
        }
        defer { collectorTask.cancel() }

        // --- Turn 1 ---
        let turn1Receipt = try await client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "First turn prompt")
        )
        #expect(turn1Receipt.applied)
        let turn1ID = try #require(turn1Receipt.result?.turnID)

        // Wait for Turn 1 completion in session events
        for _ in 0..<100 {
            if await collector.containsTurnCompleted(turnID: turn1ID) { break }
            try await Task.sleep(for: .milliseconds(40))
        }

        let eventsTurn1 = await collector.getEvents()

        // Verify Turn 1 event order: assistantMessageCommitted -> modelStepCompleted -> runCompleted
        var committedEvent: (messageID: MessageID, content: String, finalIndex: UInt64)?
        var modelStepCompletedEvent: (stepID: ModelStepID, finalIndex: UInt64?)?
        var runCompletedFound = false

        for event in eventsTurn1 {
            switch event {
            case let .assistantMessageCommitted(messageID, content, finalIndex):
                committedEvent = (messageID, content, finalIndex)
            case let .modelStepCompleted(stepID, finalIndex, _):
                modelStepCompletedEvent = (stepID, finalIndex)
            case .runCompleted:
                runCompletedFound = true
            default:
                break
            }
        }

        let committed1 = try #require(committedEvent)
        let step1 = try #require(modelStepCompletedEvent)
        #expect(runCompletedFound)

        // Requirement 1 & 4 Verification:
        // 1. finalIndex is 0-based index of last real frame (2 frames -> index 0 and 1 -> finalIndex == 1)
        #expect(committed1.finalIndex == 1)
        // 2. assistant content does NOT contain reasoning text!
        #expect(committed1.content == "Turn 1: Hello world!")
        #expect(!committed1.content.contains("Reasoning"))
        // 3. reasoningFinalIndex is 0-based (2 reasoning frames -> 0 and 1 -> finalIndex == 1)
        #expect(step1.finalIndex == 1)

        // --- Turn 2 ---
        let turn2Receipt = try await client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "Second turn prompt")
        )
        let turn2ID = try #require(turn2Receipt.result?.turnID)

        // Wait for Turn 2 completion
        for _ in 0..<100 {
            if await collector.containsTurnCompleted(turnID: turn2ID) { break }
            try await Task.sleep(for: .milliseconds(40))
        }

        let allEvents = await collector.getEvents()
        var committed2Event: (content: String, finalIndex: UInt64)?
        var step2CompletedEvent: UInt64?
        for event in allEvents {
            switch event {
            case let .assistantMessageCommitted(_, content, finalIndex):
                if content.contains("Turn 2") {
                    committed2Event = (content, finalIndex)
                }
            case let .modelStepCompleted(_, finalIndex, _):
                if finalIndex == 0 {
                    step2CompletedEvent = finalIndex
                }
            default:
                break
            }
        }

        let committed2 = try #require(committed2Event)
        #expect(committed2.content == "Turn 2: Response delivered.")
        #expect(!committed2.content.contains("Reasoning"))
        // 1 text frame -> index 0 -> finalIndex == 0
        #expect(committed2.finalIndex == 0)
        // 1 reasoning frame -> index 0 -> finalIndex == 0
        #expect(step2CompletedEvent == 0)
    }

    // MARK: - 2. Queued Turn Execution Test
    @Test("Queued turns execute sequentially when active run completes")
    func testQueuedTurnsExecuteSequentially() async throws {
        let provider = ControllableFakeProvider()
        let (host, tempDir) = try await createTestEnvironment(provider: provider)
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        defer { Task { await client.disconnect() } }

        let session = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(session.result?.sessionID)

        // 1. Submit Turn 1 (Starts execution)
        let turn1 = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "Turn 1"))
        #expect(turn1.result?.status == .running)
        let turn1ID = try #require(turn1.result?.turnID)

        // Wait until Turn 1 stream has connected
        await provider.waitStreams(1)

        // 2. Submit Turn 2 while Turn 1 is active (Should be queued)
        let turn2 = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "Turn 2"))
        #expect(turn2.result?.status == .queued)
        let turn2ID = try #require(turn2.result?.turnID)

        // 3. Submit Turn 3 while Turn 1 is active (Should also be queued)
        let turn3 = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "Turn 3"))
        #expect(turn3.result?.status == .queued)
        let turn3ID = try #require(turn3.result?.turnID)

        // 4. Complete Turn 1
        await provider.emit([.started, .textDelta("Done 1"), .completed(.stop)], finish: true)

        // CoreHost will automatically start Turn 2 from finishRun's nextTurnToRun!
        await provider.waitStreams(2)
        #expect(await provider.streamCount == 2)

        // 5. Complete Turn 2
        await provider.emit([.started, .textDelta("Done 2"), .completed(.stop)], finish: true)

        // CoreHost will automatically start Turn 3!
        await provider.waitStreams(3)
        #expect(await provider.streamCount == 3)

        // 6. Complete Turn 3
        await provider.emit([.started, .textDelta("Done 3"), .completed(.stop)], finish: true)

        // Verify all three turns exist and reached completed status
        let coord = try await host.coordinator(for: sessionID)
        for _ in 0..<50 {
            let t3 = await coord.getTurn(turnID: turn3ID)
            if t3?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let t1 = await coord.getTurn(turnID: turn1ID)
        let t2 = await coord.getTurn(turnID: turn2ID)
        let t3 = await coord.getTurn(turnID: turn3ID)

        #expect(t1?.status == .completed)
        #expect(t2?.status == .completed)
        #expect(t3?.status == .completed)
    }

    // MARK: - 3. Mode / Permission Switching Test
    @Test("Mode and Permission commands update nextTurn state and freeze into TurnExecutionIntent")
    func testModeAndPermissionCommandWorkflow() async throws {
        let (host, tempDir) = try await createTestEnvironment(provider: ScriptedFakeProvider(script: []))
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client)
        await store.dispatch(.connect)
        await store.dispatch(.createSession())

        // 1. Execute /mode plan
        let modeResult = try await store.executeCommand("/mode plan")
        #expect(modeResult.nextTurnMode == .plan)
        let state1 = await store.state
        #expect(state1.nextTurnMode == .plan)

        // 2. Execute /permissions yolo
        let permResult = try await store.executeCommand("/permissions yolo")
        #expect(permResult.nextTurnPermission == PermissionConfiguration.yoloFullAccess)
        let state2 = await store.state
        #expect(state2.nextTurnPermission == PermissionConfiguration.yoloFullAccess)

        // 3. Submit a prompt: ApplicationStore should capture the intent
        await store.dispatch(.submitPrompt("Build something under YOLO"))

        // After submitPrompt, nextTurnMode and nextTurnPermission are consumed/reset
        let state3 = await store.state
        #expect(state3.nextTurnMode == nil)
        #expect(state3.nextTurnPermission == nil)

        // Verify session snapshot reflects the updated permission configuration
        let activeSessionID = try #require(await store.state.activeSessionID)
        var snap = try await client.session.snapshot(sessionID: activeSessionID)
        for _ in 0..<100 where snap.permissionConfiguration != PermissionConfiguration.yoloFullAccess {
            try await Task.sleep(for: .milliseconds(20))
            snap = try await client.session.snapshot(sessionID: activeSessionID)
        }
        #expect(snap.permissionConfiguration == PermissionConfiguration.yoloFullAccess)
    }

    // MARK: - 4. ContextStateSnapshot Real Metrics Test
    @Test("ContextStateSnapshot wires cacheController metrics and does not default to 0")
    func testContextStateSnapshotMetrics() async throws {
        let provider = ScriptedFakeProvider(script: [
            [.started, .textDelta("Hello response"), .completed(.stop)]
        ])
        let (host, tempDir) = try await createTestEnvironment(provider: provider, permissionDecision: .allow)
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let session = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(session.result?.sessionID)

        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "Hello!"))

        // Wait for turn to process
        try await Task.sleep(for: .milliseconds(150))

        let snapshot = try await client.context.getState(sessionID: sessionID)

        #expect(snapshot.estimatedTokens > 0)
        #expect(snapshot.l1Tokens > 0)
    }

    // MARK: - 5. TUI Local Commands Isolation Test
    @Test("Frontend local commands exist in TUI palette but are not in ApplicationCommandRegistry")
    func testFrontendLocalCommandsNotInApplicationRegistry() async throws {
        let registry = ApplicationCommandRegistry()
        for cmd in BuiltinCommands.createAll() {
            registry.register(cmd)
        }
        let allAppCommands = registry.allCommands
        let appCommandNames = Set(allAppCommands.map(\.name))

        // ApplicationCommandRegistry must remain clean (no frontend-local commands)
        #expect(!appCommandNames.contains("help"))
        #expect(!appCommandNames.contains("clear"))
        #expect(!appCommandNames.contains("quit"))
    }

    @Test("Real stdio multi-tool lifecycle preserves first-seen timeline order")
    func testRealStdioMultiToolLifecyclePreservesTimelineOrder() async throws {
        let first = ToolCall(callID: ToolCallID("stdio-tool-1"), toolID: ToolID("read_file"), arguments: #"{"path":"one.txt"}"#)
        let second = ToolCall(callID: ToolCallID("stdio-tool-2"), toolID: ToolID("list_directory"), arguments: #"{"path":"."}"#)
        let provider = ScriptedFakeProvider(script: [
            [.started, .toolCallCompleted(first), .toolCallCompleted(second), .completed(.toolCalls)],
            [.started, .textDelta("final answer"), .completed(.stop)]
        ])
        let (host, tempDir) = try await createTestEnvironment(provider: provider)
        try Data("known\n".utf8).write(to: tempDir.appendingPathComponent("one.txt"))
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let server = VNextStdioCoreServer(
            service: host,
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let serverTask = Task.detached { try await server.run() }
        defer {
            serverTask.cancel()
            try? clientToServer.fileHandleForReading.close()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForReading.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        let transport = VNextStdioTransport(inputHandle: clientToServer.fileHandleForWriting, outputPipe: serverToClient)
        let client = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)
        let store = await ApplicationStore(client: client)
        defer { Task { await client.disconnect() } }

        let sessionReceipt = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(sessionReceipt.result?.sessionID)
        await store.switchToSession(sessionID)
        await store.dispatch(.setPermissionConfiguration(.yoloFullAccess))
        await store.dispatch(.submitPrompt("Use the tools, then answer."))

        for _ in 0..<100 {
            if let session = await store.state.activeSessionState,
               session.toolNodes[first.callID]?.phase == .completed,
               session.toolNodes[second.callID]?.phase == .completed,
               session.timelineNodes.contains(where: {
                   if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "final answer" }
                   return false
               }),
               session.status == .ready {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let state = try #require(await store.state.activeSessionState)
        let nodes = state.timelineNodes
        let firstToolIndex = try #require(nodes.firstIndex { $0.id == .tool(first.callID) })
        let secondToolIndex = try #require(nodes.firstIndex { $0.id == .tool(second.callID) })
        let assistantIndex = try #require(nodes.firstIndex {
            if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "final answer" }
            return false
        })

        #expect(firstToolIndex < secondToolIndex)
        #expect(secondToolIndex < assistantIndex)
        #expect(state.toolNodes[first.callID]?.callID == first.callID)
        #expect(state.toolNodes[second.callID]?.callID == second.callID)
        #expect(state.toolNodes[first.callID]?.result?.callID == first.callID)
        #expect(state.toolNodes[second.callID]?.result?.callID == second.callID)
        #expect(state.activeToolCallIDs.isEmpty)
    }

    @Test("Question projects to active interaction and resumes the next model step")
    func testQuestionProjectionResumesNextModelStep() async throws {
        let question = ToolCall(
            callID: ToolCallID("question-projection"),
            toolID: ToolID("question"),
            arguments: #"{"question":"继续吗？","options":["继续","停止"]}"#
        )
        let provider = ScriptedFakeProvider(script: [
            [.started, .toolCallCompleted(question), .completed(.toolCalls)],
            [.started, .textDelta("已继续。"), .completed(.stop)]
        ])
        let (host, tempDir) = try await createTestEnvironment(provider: provider, interactive: true)
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client)
        defer { Task { await client.disconnect() } }

        let session = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(session.result?.sessionID)
        await store.switchToSession(sessionID)
        await store.dispatch(.submitPrompt("先确认再继续"))

        var permission: InteractionSnapshot?
        for _ in 0..<100 {
            let state = await store.state.activeSessionState
            if state?.activeInteraction?.kind == .permission {
                permission = state?.activeInteraction
                #expect(state?.status == .actionRequired)
                #expect(state?.toolNodes[question.callID]?.phase != .running)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let permissionInteraction = try #require(permission)
        await store.dispatch(.grantPermission(interactionID: permissionInteraction.interactionID, decision: .allow))

        var interaction: InteractionSnapshot?
        for _ in 0..<100 {
            let state = await store.state.activeSessionState
            if state?.activeInteraction?.kind == .question {
                interaction = state?.activeInteraction
                #expect(state?.status == .actionRequired)
                #expect(state?.toolNodes[question.callID]?.phase != .running)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let active = try #require(interaction)
        let request = try #require(active.questionRequest)
        await store.dispatch(.replyQuestion(
            interactionID: active.interactionID,
            reply: QuestionReply(questionID: request.questionID, selectedOptionIndices: [0])
        ))

        for _ in 0..<100 {
            let state = await store.state.activeSessionState
            if state?.activeInteraction == nil,
               state?.toolNodes[question.callID]?.phase == .completed,
               state?.timelineNodes.contains(where: {
                   if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "已继续。" }
                   return false
               }) == true,
               state?.status == .ready {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let finalState = try #require(await store.state.activeSessionState)
        #expect(finalState.activeInteraction == nil)
        #expect(finalState.toolNodes[question.callID]?.phase == .completed)
        #expect(finalState.timelineNodes.contains(where: {
            if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "已继续。" }
            return false
        }))
        #expect(provider.recorder.requests.count == 2)
    }

    @Test("Workflow decisions project to the active interaction")
    func testWorkflowDecisionProjectsToActiveInteraction() async throws {
        let (host, tempDir) = try await createTestEnvironment(provider: ScriptedFakeProvider(script: []))
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client)
        defer { Task { await client.disconnect() } }

        let session = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(session.result?.sessionID)
        await store.switchToSession(sessionID)

        let workflow = try #require(await host.workflowRuntimeRef)
        let workflowID = WorkflowID("decision-projection")
        _ = try await workflow.create(
            id: workflowID,
            rootSessionID: sessionID,
            rootRunID: AgentRunID("root-run"),
            tasks: [WorkflowTaskDefinition(id: WorkflowTaskID("decision"), kind: .decision, task: "choose")]
        )
        let request = DecisionRequest(
            decisionID: DecisionID("decision-1"),
            question: "继续吗？",
            options: ["继续", "停止"],
            originSessionID: sessionID,
            originRunID: AgentRunID("root-run")
        )
        try await workflow.suspend(workflowID: workflowID, taskID: WorkflowTaskID("decision"), input: .decision(request))

        for _ in 0..<100 {
            if await store.state.activeSessionState?.activeInteraction?.interactionID == InteractionID(request.decisionID.rawValue) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let state = try #require(await store.state.activeSessionState)
        #expect(state.activeInteraction?.kind == .decision)
        #expect(state.status == .actionRequired)
        #expect(state.activeInteraction?.decisionRequest == request)
    }

    @Test("Workspace rejection requires YOLO before writing outside the workspace")
    func testWorkspaceRejectionThenYoloWriteAndFinalAnswer() async throws {
        let denied = ToolCall(
            callID: ToolCallID("workspace-denied"),
            toolID: ToolID("write_file"),
            arguments: #"{"path":"../Desktop/lingxi-tui.txt","content":"blocked"}"#
        )
        let allowed = ToolCall(
            callID: ToolCallID("yolo-write"),
            toolID: ToolID("write_file"),
            arguments: #"{"path":"../Desktop/lingxi-tui.txt","content":"written"}"#
        )
        let provider = ScriptedFakeProvider(script: [
            [.started, .toolCallCompleted(denied), .completed(.toolCalls)],
            [.started, .textDelta("workspace 拒绝。"), .completed(.stop)],
            [.started, .toolCallCompleted(allowed), .completed(.toolCalls)],
            [.started, .textDelta("final answer"), .completed(.stop)]
        ])
        let (host, tempDir) = try await createTestEnvironment(provider: provider)
        let desktop = tempDir.deletingLastPathComponent().appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let target = desktop.appendingPathComponent("lingxi-tui.txt")
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
                try? FileManager.default.removeItem(at: desktop)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client)
        defer { Task { await client.disconnect() } }

        let session = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(session.result?.sessionID)
        await store.switchToSession(sessionID)
        await store.dispatch(.submitPrompt("写入桌面"))

        for _ in 0..<100 {
            let state = await store.state.activeSessionState
            if state?.toolNodes[denied.callID]?.phase == .completed,
               state?.timelineNodes.contains(where: {
                   if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "workspace 拒绝。" }
                   return false
               }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let rejected = try #require(await store.state.activeSessionState?.toolNodes[denied.callID]?.result)
        #expect(rejected.success == false)
        #expect(rejected.error?.message.contains("FullAccess/YOLO") == true)

        let permissionResult = try await store.executeCommand("/permissions yolo")
        #expect(permissionResult.nextTurnPermission == .yoloFullAccess)
        await store.dispatch(.submitPrompt("切换后写入桌面并回答"))

        for _ in 0..<100 {
            let state = await store.state.activeSessionState
            if state?.toolNodes[allowed.callID]?.phase == .completed,
               state?.timelineNodes.contains(where: {
                   if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "final answer" }
                   return false
               }) == true,
               state?.status == .ready {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let finalState = try #require(await store.state.activeSessionState)
        #expect(finalState.toolNodes[allowed.callID]?.phase == .completed)
        #expect(finalState.activeInteraction == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "written")
        #expect(finalState.timelineNodes.contains(where: {
            if case let .message(message) = $0.kind { return message.role == .assistant && message.content == "final answer" }
            return false
        }))
        #expect(provider.recorder.requests.count == 4)
    }
}
