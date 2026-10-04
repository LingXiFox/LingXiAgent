import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiClient

@Suite("RewindPhase6Tests")
struct RewindPhase6Tests {

    @Test(arguments: [false, true]) @MainActor
    func historicalToolHydrationPreservesRealTimingAcrossEventReplay(legacyEvents: Bool) async throws {
        let sid = SessionID("timing-hydration"), callID = ToolCallID("timed-call")
        let call = ToolCall(callID: callID, toolID: ToolID("shell"), arguments: "{}")
        let timing = ToolTiming(milliseconds: 123.5, queueMilliseconds: 12, executionMilliseconds: 123.5, permissionMilliseconds: 7)
        let result = ToolResult(callID: callID, success: true, content: "verified output", toolName: "shell", timing: timing)
        let messages = [Message(id: MessageID("u"), role: .user, content: "Run tests", createdAt: .now),
            Message(id: MessageID("a"), role: .assistant, parts: [.toolCall(call)], createdAt: .now),
            Message(id: MessageID("r"), role: .tool, parts: [.toolResult(result)], createdAt: .now)]
        let log = SessionEventLog(sessionID: sid)
        let coord = SessionTurnCoordinator(sessionID: sid, eventLog: log)
        if legacyEvents {
            let causal = CausalContext(sessionID: sid)
            _ = try await log.append(causal: causal, payload: .turnCreated(.init(turnID: TurnID("stored-turn"), sessionID: sid,
                userMessage: .init(messageID: messages[0].id, role: .user, text: "Run tests", createdAt: .now),
                executionIntent: .init(), status: .completed, createdAt: .now)))
            _ = try await log.append(causal: causal, payload: .toolRequested(.init(callID: callID, toolID: call.toolID,
                displayName: "shell", argumentsSummary: "{}", state: .completed)))
            _ = try await log.append(causal: causal, payload: .toolCompleted(callID: callID,
                result: .init(callID: callID, success: true, summary: "verified output"), stdoutFinalIndex: nil, stderrFinalIndex: nil))
            await coord.restoreHistoricalQueue()
            await coord.hydrateHistoricalMessages(messages)
        } else { try await coord.resetForRevert(remainingMessages: messages) }
        let events = await log.allEvents()
        let completed = try #require(events.compactMap { event -> ToolResultSnapshot? in
            if case let .toolCompleted(_, result, _, _) = event.payload { return result }; return nil
        }.first)
        if !legacyEvents { #expect(completed.timing == timing) }
        let info = SessionSummary(sessionID: sid, title: "Timing", createdAt: .now, updatedAt: .now, turnCount: 1, mode: .build)
        let snapshot = await coord.buildSnapshot(info: info, contextState: .init(sessionID: sid),
            permissionConfiguration: .init(policy: .ask, profile: .workspace), agentMode: .build, revision: 1)
        #expect(snapshot.recentToolInvocations.first?.durationMs == 123.5)
        var state = SessionViewState(sessionID: sid)
        SessionReducer.reduceSnapshot(state: &state, snapshot: snapshot, connectionState: .init(status: .connected))
        #expect(state.toolNodes[callID]?.executionDuration == .milliseconds(123.5))
        let projectedDuration = state.timelineNodes.compactMap { node -> Duration? in
            if case let .tool(tool) = node.kind { return tool.executionDuration }; return nil
        }.first
        #expect(projectedDuration == .milliseconds(123.5))
    }

    @Test
    func revertLastTurnReturnsAuthoritativeSnapshotAndRevision() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)
        let session = try await store.create()

        _ = try await store.appendMessage(session.id, role: .user, content: "First question")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "First answer")
        _ = try await store.appendMessage(session.id, role: .user, content: "Second question")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "Second answer")

        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let host = try CoreHost(
            sessionStore: store,
            workspaceRoot: workspace
        )
        let req = RevertLastTurnRequest(sessionID: session.id)
        let envelope = CommandEnvelope(payload: req)

        let receipt = try await host.revertLastTurn(envelope: envelope)

        #expect(receipt.applied == true)
        let res = try #require(receipt.result)
        #expect(res.revertedPrompt == "Second question")
        #expect(res.revertedComposerText == "Second question")
        #expect(res.removedCount == 2)
        #expect(res.revision != nil)
        #expect(res.snapshot != nil)

        let snapshot = try #require(res.snapshot)
        #expect(snapshot.sessionID == session.id)
        #expect(snapshot.revision == res.revision)
        #expect(snapshot.recentTurns.count == 1)
        #expect(snapshot.recentTurns.first?.userMessage.text == "First question")
        #expect(snapshot.activeRootRun == nil)
        #expect(snapshot.pendingInteractions.isEmpty)

        let currentRev = try await store.currentRevision(session.id)
        #expect(currentRev == res.revision)
    }

    @Test
    func reduceSnapshotPurgesZombieRunningToolsAndOrphanNodes() async throws {
        let sessionID = SessionID("sess-phase6-tool-test")
        var state = SessionViewState(sessionID: sessionID)

        // 模拟已存在一个 running 状态的 tool
        let orphanCallID = ToolCallID("call_orphan_tool_123")
        var orphanTool = ToolNode(callID: orphanCallID, toolName: "find_by_name")
        orphanTool.phase = .running
        orphanTool.argumentsJSON = "{\"path\": \"/foo\"}"
        state.toolNodes[orphanCallID] = orphanTool
        state.activeToolCallIDs.insert(orphanCallID)
        let nodeID = TimelineNodeID.tool(orphanCallID)
        state.appendNode(TimelineNode(id: nodeID, timestamp: Date(), kind: .tool(orphanTool)))
        let conn = ConnectionState(status: .connected)
        state.recalculateStatus(connectionState: conn)
        #expect(state.status == .runningTool)

        // 构造一个撤回后的权威 Snapshot（无 activeRootRun，recentToolInvocations 为空）
        let summary = SessionSummary(
            sessionID: sessionID,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            turnCount: 0,
            mode: .build
        )
        let contextState = ContextStateSnapshot(sessionID: sessionID)
        let cursor = EventCursor(generationID: EventLogGenerationID("gen1"), sequence: 1)
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: summary,
            recentTurns: [],
            activeRootRun: nil,
            activeChildRuns: [],
            pendingInteractions: [],
            activeModelSteps: [],
            recentToolInvocations: [],
            contextState: contextState,
            permissionConfiguration: PermissionConfiguration(policy: .ask, profile: .workspace),
            agentMode: .build,
            recentEvents: [],
            historyBeforeCursor: nil,
            eventCursor: cursor,
            revision: 2
        )

        // 执行快照对齐
        SessionReducer.reduceSnapshot(state: &state, snapshot: snapshot, connectionState: conn)

        // 验证：孤儿 tool 节点被彻底清除，activeToolCallIDs 为空，无任何 running tool 节点
        #expect(state.toolNodes[orphanCallID] == nil)
        #expect(state.activeToolCallIDs.isEmpty)
        #expect(!state.timelineNodes.contains(where: { $0.id == nodeID }))
        #expect(state.status == .ready)
        #expect(state.activeTurnID == nil)
        #expect(state.activeRootRunID == nil)
    }

    @Test
    func reduceSnapshotWithEventsDoesNotLeaveZombieRunningState() async throws {
        let sessionID = SessionID("sess-phase6-events-test")
        var state = SessionViewState(sessionID: sessionID)

        let summary = SessionSummary(
            sessionID: sessionID,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            turnCount: 0,
            mode: .build
        )
        let callID = ToolCallID("call_stale_123")
        let invocation = ToolInvocationSnapshot(
            callID: callID,
            toolID: ToolID("test_tool"),
            displayName: "Test Tool",
            argumentsSummary: "{}",
            state: .running
        )

        let cursor = EventCursor(generationID: EventLogGenerationID("gen1"), sequence: 1)
        let causal = CausalContext(sessionID: sessionID)
        let staleEvent = SessionEventEnvelope(
            cursor: cursor,
            causal: causal,
            payload: .toolRequested(invocation)
        )

        let conn = ConnectionState(status: .connected)
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: summary,
            recentTurns: [],
            activeRootRun: nil, // 关键：权威快照表明此时已空闲
            activeChildRuns: [],
            pendingInteractions: [],
            activeModelSteps: [],
            recentToolInvocations: [],
            contextState: ContextStateSnapshot(sessionID: sessionID),
            permissionConfiguration: PermissionConfiguration(policy: .ask, profile: .workspace),
            agentMode: .build,
            recentEvents: [staleEvent],
            historyBeforeCursor: nil,
            eventCursor: cursor,
            revision: 3
        )

        SessionReducer.reduceSnapshot(state: &state, snapshot: snapshot, connectionState: conn)

        // 验证：虽然重放了 toolRequested，但在 snapshot 最终校正下，该孤儿 tool 被彻底抹除，无空转
        #expect(state.toolNodes[callID] == nil)
        #expect(state.activeToolCallIDs.isEmpty)
        #expect(state.status == .ready)
    }

    @Test
    func sessionSnapshotAuthoritativeSyncClearsActiveTurnAndResidualStreamingState() async throws {
        let sessionID = SessionID("sess-phase6-sync-test")
        var state = SessionViewState(sessionID: sessionID)

        // 模拟正在流式生成和运行中的旧状态
        state.activeTurnID = TurnID("turn-old")
        state.activeRootRunID = RunID("run-old")
        state.activeProviderRequestState = .streaming
        state.activeProviderRequestDetail = "Receiving model output"

        let stepID = ModelStepID("step-old")
        state.thinkingNodes[stepID] = ThinkingNode(
            stepID: stepID,
            content: "Old thinking",
            isStreaming: true,
            isComplete: false,
            startedAt: Date()
        )
        state.activeThinkingStepID = stepID

        let summary = SessionSummary(
            sessionID: sessionID,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            turnCount: 0,
            mode: .build
        )
        let cursor = EventCursor(generationID: EventLogGenerationID("gen1"), sequence: 2)
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: summary,
            recentTurns: [],
            activeRootRun: nil,
            activeChildRuns: [],
            pendingInteractions: [],
            activeModelSteps: [],
            recentToolInvocations: [],
            contextState: ContextStateSnapshot(sessionID: sessionID),
            permissionConfiguration: PermissionConfiguration(policy: .ask, profile: .workspace),
            agentMode: .build,
            recentEvents: [],
            historyBeforeCursor: nil,
            eventCursor: cursor,
            revision: 5
        )

        let conn = ConnectionState(status: .connected)
        SessionReducer.reduceSnapshot(state: &state, snapshot: snapshot, connectionState: conn)

        #expect(state.activeTurnID == nil)
        #expect(state.activeRootRunID == nil)
        #expect(state.activeProviderRequestState == nil)
        #expect(state.activeProviderRequestDetail == nil)
        #expect(state.activeThinkingStepID == nil)
        #expect(state.thinkingNodes.isEmpty)
        #expect(state.status == .ready)
    }
}
