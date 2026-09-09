import Foundation
import Testing
import LingXiApplication
import LingXiClient
import LingXiProtocol

@Suite("ApplicationProjectionTests")
struct ApplicationProjectionTests {
    private let sessionID = SessionID("session-1")
    private let connection = ConnectionState(status: .connected)
    private let generationID = EventLogGenerationID(rawValue: "generation-1")
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ sequence: UInt64, _ payload: SessionEventPayload) -> SessionEventEnvelope {
        SessionEventEnvelope(
            cursor: EventCursor(generationID: generationID, sequence: sequence),
            timestamp: timestamp.addingTimeInterval(TimeInterval(sequence)),
            causal: CausalContext(sessionID: sessionID),
            payload: payload
        )
    }

    private func turn(_ id: String, rootRunID: RunID? = nil, status: TurnStatus = .queued) -> TurnSnapshot {
        TurnSnapshot(
            turnID: TurnID(id),
            sessionID: sessionID,
            userMessage: MessageSnapshot(
                messageID: MessageID("message-\(id)"),
                role: .user,
                text: "prompt \(id)",
                createdAt: timestamp
            ),
            executionIntent: TurnExecutionIntent(),
            status: status,
            rootRunID: rootRunID,
            createdAt: timestamp
        )
    }

    private func run(_ id: String, turnID: TurnID, status: RunStatus = .running) -> RunSnapshot {
        RunSnapshot(
            runID: RunID(id),
            sessionID: sessionID,
            turnID: turnID,
            status: status,
            model: "test-model",
            createdAt: timestamp
        )
    }

    @Test("Thinking, assistant, tool, and HITL aggregate by canonical identity")
    func aggregatesCanonicalProductNodes() {
        var state = SessionViewState(sessionID: sessionID)
        let step1 = ModelStepID("step-1")
        let step2 = ModelStepID("step-2")
        let reasoningStream = StreamID("reasoning-1")
        let messageID = MessageID("assistant-1")
        let assistantStream = StreamID("assistant-stream-1")
        let callID = ToolCallID("tool-1")
        let interactionID = InteractionID("interaction-1")

        SessionReducer.reduce(state: &state, event: event(1, .modelStepStarted(stepID: step1, visibleReasoningStreamID: reasoningStream, assistantStreamID: nil)), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: reasoningStream, owner: CausalContext(sessionID: sessionID, modelStepID: step1), index: 0, kind: .visibleReasoning, text: "reasoning"), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(2, .toolRequested(ToolInvocationSnapshot(callID: callID, toolID: ToolID("shell"), displayName: "Shell", argumentsSummary: "{}", state: .requested))), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(3, .toolRunning(callID: callID, stdoutStreamID: nil, stderrStreamID: nil)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(4, .toolCompleted(callID: callID, result: ToolResultSnapshot(callID: callID, success: true, summary: "ok"), stdoutFinalIndex: nil, stderrFinalIndex: nil)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(5, .modelStepStarted(stepID: step2, visibleReasoningStreamID: nil, assistantStreamID: nil)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(6, .assistantMessageStarted(messageID: messageID, assistantStreamID: assistantStream)), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: assistantStream, owner: CausalContext(sessionID: sessionID), index: 0, kind: .assistantText, text: "hello "), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(7, .assistantMessageCommitted(messageID: messageID, content: "hello world", assistantFinalIndex: 0)), connectionState: connection)
        let interaction = InteractionSnapshot(interactionID: interactionID, kind: .decision, causal: CausalContext(sessionID: sessionID), createdAt: timestamp)
        SessionReducer.reduce(state: &state, event: event(8, .interactionRequested(interaction)), connectionState: connection)

        #expect(state.timelineNodes.map { $0.id.rawValue } == ["thinking:step-1", "tool:tool-1", "thinking:step-2", "message:assistant-1", "interaction:interaction-1"])
        #expect(state.thinkingNodes.count == 2)
        #expect(state.thinkingNodes[step1]?.content == "reasoning")
        guard case let .message(message)? = state.node(for: .message(messageID))?.kind else {
            Issue.record("expected assistant message node")
            return
        }
        #expect(message.content == "hello world")
        #expect(message.isFinal)
        #expect(state.toolNodes.count == 1)
        #expect(state.toolNodes[callID]?.phase == .completed)
        #expect(state.activeInteraction?.interactionID == interactionID)
        #expect(state.status == .actionRequired)
    }

    @Test("Status permission projection prefers the active frozen turn intent")
    func activeTurnPermissionProjection() {
        let yoloTurn = turn("yolo", status: .running)
        let fullAccessIntent = TurnExecutionIntent(permissionConfiguration: .yoloFullAccess)
        let activeTurn = TurnSnapshot(
            turnID: yoloTurn.turnID,
            sessionID: sessionID,
            userMessage: yoloTurn.userMessage,
            executionIntent: fullAccessIntent,
            status: .running,
            createdAt: timestamp
        )
        var session = SessionViewState(sessionID: sessionID)
        session.turns[activeTurn.turnID] = activeTurn
        session.activeTurnID = activeTurn.turnID
        session.permissionConfiguration = .askWorkspace

        let state = ApplicationState(
            activeSessionID: sessionID,
            activeSessionState: session,
            nextTurnPermission: .askFullAccess
        )

        #expect(state.activeTurnPermissionConfiguration == .yoloFullAccess)
        #expect(state.nextTurnPermission?.displayName == "FullAccess")
        #expect(PermissionConfiguration.yoloFullAccess.displayName == "YOLO")
    }

    @Test("Queued turns never create a second active root run")
    func queuesTurnBehindActiveRootRun() {
        var state = SessionViewState(sessionID: sessionID)
        let first = turn("turn-1")
        let second = turn("turn-2")
        let firstRun = run("run-1", turnID: first.turnID)
        let secondRun = run("run-2", turnID: second.turnID, status: .queued)

        SessionReducer.reduce(state: &state, event: event(1, .turnCreated(first)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(2, .runCreated(firstRun)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(3, .turnCreated(second)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(4, .runCreated(secondRun)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(5, .runQueued(runID: secondRun.runID)), connectionState: connection)

        #expect(state.activeRootRunID == firstRun.runID)
        #expect(state.queuedTurns == [second.turnID])
        #expect(state.runs[secondRun.runID]?.status == .queued)
        #expect(state.turns[second.turnID]?.status == .queued)

        SessionReducer.reduce(state: &state, event: event(6, .runCompleted(runID: firstRun.runID, terminalReason: .completed)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(7, .runStarted(runID: secondRun.runID)), connectionState: connection)
        #expect(state.activeRootRunID == secondRun.runID)
        #expect(state.queuedTurns.isEmpty)
        #expect(state.runs[firstRun.runID]?.status == .completed)
        #expect(state.runs[secondRun.runID]?.status == .running)
    }

    @Test("Snapshot resync replaces stale projection and replays its semantic window")
    func snapshotResyncIsEquivalentToSemanticReplay() {
        let activeTurn = turn("turn-1")
        let assistantID = MessageID("assistant-1")
        let streamID = StreamID("assistant-stream-1")
        let events = [
            event(1, .turnCreated(activeTurn)),
            event(2, .assistantMessageStarted(messageID: assistantID, assistantStreamID: streamID)),
            event(3, .assistantMessageCommitted(messageID: assistantID, content: "final", assistantFinalIndex: 0))
        ]
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: SessionSummary(sessionID: sessionID, title: "Restored", createdAt: timestamp, updatedAt: timestamp),
            recentTurns: [activeTurn],
            contextState: ContextStateSnapshot(sessionID: sessionID),
            recentEvents: events,
            eventCursor: EventCursor(generationID: generationID, sequence: 3)
        )
        var resynced = SessionViewState(sessionID: sessionID, title: "stale")
        resynced.appendNode(TimelineNode(id: TimelineNodeID("message:stale"), timestamp: timestamp, kind: .message(MessageNode(messageID: MessageID("stale"), role: .assistant))))
        SessionReducer.reduceSnapshot(state: &resynced, snapshot: snapshot, connectionState: connection)

        var replayed = SessionViewState(sessionID: sessionID, title: "Restored", createdAt: timestamp, updatedAt: timestamp)
        for event in events {
            SessionReducer.reduce(state: &replayed, event: event, connectionState: connection)
        }

        #expect(resynced.timelineNodes == replayed.timelineNodes)
        #expect(resynced.turns == replayed.turns)
        guard case let .message(message)? = resynced.node(for: .message(assistantID))?.kind else {
            Issue.record("expected restored assistant message node")
            return
        }
        #expect(message.content == "final")
        #expect(message.isFinal)
        #expect(resynced.node(for: TimelineNodeID("message:stale")) == nil)
    }

    @Test("Reconnect followed by snapshot resync restores product state")
    func reconnectAndSnapshotResyncRestoreState() {
        let activeTurn = turn("turn-1")
        let runID = RunID("run-1")
        let activeRun = run("run-1", turnID: activeTurn.turnID)
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: SessionSummary(sessionID: sessionID, title: "Restored", createdAt: timestamp, updatedAt: timestamp),
            recentTurns: [activeTurn],
            activeRootRun: activeRun,
            contextState: ContextStateSnapshot(sessionID: sessionID),
            recentEvents: [event(1, .turnCreated(activeTurn)), event(2, .runCreated(activeRun))],
            eventCursor: EventCursor(generationID: generationID, sequence: 2)
        )
        var state = ApplicationState(
            connectionState: ConnectionState.reconnecting(),
            activeSessionID: sessionID,
            activeSessionState: SessionViewState(sessionID: sessionID, title: "stale")
        )
        RootReducer.reduce(state: &state, action: ._connectionStateChanged(connection))
        RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))

        #expect(state.status == .ready)
        #expect(state.activeSessionState?.title == "Restored")
        #expect(state.activeSessionState?.activeRootRunID == runID)
        #expect(state.activeSessionState?.turns[activeTurn.turnID] == activeTurn)
    }

    @Test("Builtin registry contains only application commands and accepts extensions")
    func commandRegistryContainsRequiredCommands() {
        let registry = ApplicationCommandRegistry()
        for command in BuiltinCommands.createAll() {
            registry.register(command)
        }
        let required = ["model", "providers", "connect", "new", "resume", "rename", "status", "context", "compact", "perf", "mode", "permissions", "subagents", "mcp", "skills", "plugins", "hooks", "diff", "ps", "stop"]
        #expect(required.allSatisfy { registry.command(named: $0) != nil })
        #expect(registry.command(named: "clear") == nil)
        registry.register(ApplicationCommand(name: "extension", description: "test") { _ in ApplicationCommandResult(output: "ok") })
        #expect(registry.command(named: "extension") != nil)
    }

    @Test("Canonical identities survive replay and rebuild without receipt-driven state changes")
    func canonicalIdentitiesAndReceiptBoundary() {
        let step1 = ModelStepID("step-1")
        let step2 = ModelStepID("step-2")
        let callID = ToolCallID("tool-1")
        let messageID = MessageID("assistant-1")
        let events = [
            event(1, .modelStepStarted(stepID: step1, visibleReasoningStreamID: nil, assistantStreamID: nil)),
            event(2, .toolRequested(ToolInvocationSnapshot(callID: callID, toolID: ToolID("shell"), displayName: "Shell", argumentsSummary: "{}", state: .requested))),
            event(3, .toolWaitingForPermission(callID: callID, permissionID: PermissionID("permission-1"))),
            event(4, .toolScheduled(callID: callID)),
            event(5, .toolRunning(callID: callID, stdoutStreamID: nil, stderrStreamID: nil)),
            event(6, .toolCompleted(callID: callID, result: ToolResultSnapshot(callID: callID, success: true, summary: "ok"), stdoutFinalIndex: nil, stderrFinalIndex: nil)),
            event(7, .modelStepStarted(stepID: step2, visibleReasoningStreamID: nil, assistantStreamID: nil)),
            event(8, .assistantMessageStarted(messageID: messageID, assistantStreamID: StreamID("assistant-1"))),
            event(9, .assistantMessageCommitted(messageID: messageID, content: "done", assistantFinalIndex: 0))
        ]

        var first = SessionViewState(sessionID: sessionID)
        var rebuilt = SessionViewState(sessionID: sessionID)
        for event in events {
            SessionReducer.reduce(state: &first, event: event, connectionState: connection)
            SessionReducer.reduce(state: &rebuilt, event: event, connectionState: connection)
        }

        #expect(first.thinkingNodes.count == 2)
        #expect(first.timelineNodes.filter { if case .thinking = $0.kind { true } else { false } }.count == 2)
        #expect(first.toolNodes.count == 1)
        #expect(first.timelineNodes.filter { if case .tool = $0.kind { true } else { false } }.count == 1)
        #expect(first.timelineNodes.filter { if case .message = $0.kind { true } else { false } }.count == 1)
        #expect(first.node(for: .message(messageID))?.kind == rebuilt.node(for: .message(messageID))?.kind)
        #expect(first.timelineNodes.map(\.id) == rebuilt.timelineNodes.map(\.id))

        for (index, kind) in [InteractionKind.permission, .question, .decision].enumerated() {
            let interactionID = InteractionID("interaction-\(index)")
            let interaction = InteractionSnapshot(interactionID: interactionID, kind: kind, causal: CausalContext(sessionID: sessionID), createdAt: timestamp)
            SessionReducer.reduce(state: &first, event: event(UInt64(10 + index), .interactionRequested(interaction)), connectionState: connection)
            #expect(first.activeInteraction?.interactionID == interactionID)
        }

        // CommandReceipt is an ACK value only; changing it cannot mutate either projection.
        let beforeReceipt = first
        let receipt = CommandReceipt<VoidResult>(commandID: CommandID(), applied: true, revision: 1, observedThrough: [])
        _ = receipt
        #expect(first == beforeReceipt)
    }

    @Test("ApplicationState active counts and UserPreferences persistence work")
    func activeCountsAndUserPreferences() throws {
        var appState = ApplicationState()
        appState.extensions = [
            ExtensionInfo(id: "skill-1", version: "1.0.0", kind: .skill, scope: "global", enabled: true, lifecycleState: "discovered"),
            ExtensionInfo(id: "skill-2", version: "1.0.0", kind: .skill, scope: "global", enabled: false, lifecycleState: "disabled"),
            ExtensionInfo(id: "mcp-1", version: "1.0.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "enabled"),
            ExtensionInfo(id: "mcp-2", version: "1.0.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "enabled")
        ]
        #expect(appState.activeSkillCount == 1)
        #expect(appState.activeMCPCount == 2)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_prefs_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let store = UserPreferencesStore(fileURL: tempFile)
        store.update(modelID: "custom-model", reasoningEffort: "high")
        let loaded = store.load()
        #expect(loaded.lastModelID == "custom-model")
        #expect(loaded.lastReasoningEffort == "high")
    }

    @Test("Hydrated historical messages properly project into SessionViewState timeline nodes")
    func historicalHydrationProjectsTimelineNodes() {
        let userMsgID = MessageID("user-msg-1")
        let assistantMsgID = MessageID("assistant-msg-1")
        let toolCallID = ToolCallID("tool-call-1")
        let tID = TurnID("turn-1")

        let userMsgSnap = MessageSnapshot(messageID: userMsgID, role: .user, text: "请帮我重构网络服务", createdAt: timestamp)
        let turnSnap = TurnSnapshot(turnID: tID, sessionID: sessionID, userMessage: userMsgSnap, executionIntent: TurnExecutionIntent(), status: .completed, createdAt: timestamp)
        let toolInvSnap = ToolInvocationSnapshot(callID: toolCallID, toolID: ToolID("fetch"), displayName: "fetch", argumentsSummary: "{}", state: .completed)
        let toolResSnap = ToolResultSnapshot(callID: toolCallID, success: true, summary: "200 OK")

        let events = [
            event(1, .turnCreated(turnSnap)),
            event(2, .userMessageCommitted(userMsgSnap)),
            event(3, .toolRequested(toolInvSnap)),
            event(4, .toolRunning(callID: toolCallID, stdoutStreamID: nil, stderrStreamID: nil)),
            event(5, .toolCompleted(callID: toolCallID, result: toolResSnap, stdoutFinalIndex: nil, stderrFinalIndex: nil)),
            event(6, .assistantMessageCommitted(messageID: assistantMsgID, content: "网络服务重构已完成", assistantFinalIndex: 0)),
            event(7, .turnCompleted(turnID: tID, terminalReason: .completed))
        ]

        let summary = SessionSummary(
            sessionID: sessionID,
            title: "网络服务重构",
            createdAt: timestamp,
            updatedAt: timestamp,
            workingDirectory: "/Volumes/External/ProjectX",
            messageCount: 3
        )

        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: summary,
            recentTurns: [turnSnap],
            recentToolInvocations: [toolInvSnap],
            contextState: ContextStateSnapshot(sessionID: sessionID),
            recentEvents: events,
            eventCursor: EventCursor(generationID: generationID, sequence: 7)
        )

        var viewState = SessionViewState(sessionID: sessionID)
        SessionReducer.reduceSnapshot(state: &viewState, snapshot: snapshot, connectionState: connection)

        #expect(viewState.turns[tID] != nil)
        #expect(viewState.timelineNodes.count >= 3)
        #expect(viewState.node(for: .message(userMsgID)) != nil)
        #expect(viewState.node(for: .message(assistantMsgID)) != nil)
        #expect(viewState.node(for: .tool(toolCallID, modelStepID: nil)) != nil)

        if case let .message(userMsg)? = viewState.node(for: .message(userMsgID))?.kind {
            #expect(userMsg.content == "请帮我重构网络服务")
            #expect(userMsg.role == .user)
        } else {
            Issue.record("User message node missing")
        }

        if case let .message(assistantMsg)? = viewState.node(for: .message(assistantMsgID))?.kind {
            #expect(assistantMsg.content == "网络服务重构已完成")
            #expect(assistantMsg.role == .assistant)
        } else {
            Issue.record("Assistant message node missing")
        }

        if case let .tool(toolNode)? = viewState.node(for: .tool(toolCallID, modelStepID: nil))?.kind {
            #expect(toolNode.toolName == "fetch")
            #expect(toolNode.phase == .completed)
        } else {
            Issue.record("Tool node missing")
        }
    }
}
