import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Round 11 System Audit & Strengthening Tests")
struct Round11SystemAuditTests {

    @Test("Queued Message and RunID Invariant: Real RunID is preserved from queue to execution")
    func testQueuedMessageIsolationAndRealRunID() async throws {
        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Submit first turn: starts running immediately
        let input1 = UserInput(text: "First prompt")
        let userMsg1 = MessageSnapshot(messageID: MessageID(), role: .user, text: input1.text, createdAt: Date())
        let decision1 = try await coordinator.submitTurn(input: input1, intent: TurnExecutionIntent(), userMessage: userMsg1)

        #expect(decision1.status == TurnStatus.running)
        #expect(decision1.shouldStartExecution == true)
        let activeRunID = try #require(decision1.runID)
        #expect(await coordinator.activeRootRunID == activeRunID)

        // Submit second turn: must be queued with a deterministic real runID
        let input2 = UserInput(text: "Second prompt")
        let userMsg2 = MessageSnapshot(messageID: MessageID(), role: .user, text: input2.text, createdAt: Date())
        let decision2 = try await coordinator.submitTurn(input: input2, intent: TurnExecutionIntent(), userMessage: userMsg2)

        #expect(decision2.status == TurnStatus.queued)
        #expect(decision2.shouldStartExecution == false)
        let queuedRunID = try #require(decision2.turn.rootRunID ?? decision2.runID)
        #expect(decision2.turn.rootRunID == queuedRunID)
        #expect(await coordinator.isTurnQueued(turnID: decision2.turn.turnID))

        // Finish first run: coordinator must schedule next queued turn with the EXACT queuedRunID (no phantom RunID)
        let nextTurn = try await coordinator.finishRun(runID: activeRunID, reason: .completed)
        let scheduled = try #require(nextTurn)

        #expect(scheduled.turn.turnID == decision2.turn.turnID)
        #expect(scheduled.runID == queuedRunID)
        #expect(await coordinator.activeRootRunID == queuedRunID)
        #expect(await coordinator.isTurnQueued(turnID: decision2.turn.turnID) == false)
    }

    @Test("Cancel Scope Invariant: Cancelling queued turn leaves active running run untouched")
    func testCancelScopeDoesNotKillRunningRun() async throws {
        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let userMsgA = MessageSnapshot(messageID: MessageID(), role: .user, text: "Run A", createdAt: Date())
        let decisionA = try await coordinator.submitTurn(input: UserInput(text: "Run A"), intent: TurnExecutionIntent(), userMessage: userMsgA)
        let runIDA = try #require(decisionA.runID)

        let userMsgB = MessageSnapshot(messageID: MessageID(), role: .user, text: "Run B", createdAt: Date())
        let decisionB = try await coordinator.submitTurn(input: UserInput(text: "Run B"), intent: TurnExecutionIntent(), userMessage: userMsgB)
        let turnIDB = decisionB.turn.turnID

        #expect(await coordinator.activeRootRunID == runIDA)
        #expect(await coordinator.isTurnQueued(turnID: turnIDB))

        // Cancel B: only B is removed from queue and cancelled; A continues running
        try await coordinator.cancelTurn(turnID: turnIDB)

        #expect(await coordinator.isTurnQueued(turnID: turnIDB) == false)
        let turnBSnap = await coordinator.getTurn(turnID: turnIDB)
        #expect(turnBSnap?.status == TurnStatus.cancelled)

        // Invariant: A remains the active root run
        #expect(await coordinator.activeRootRunID == runIDA)
        let turnASnap = await coordinator.getTurn(turnID: decisionA.turn.turnID)
        #expect(turnASnap?.status == TurnStatus.running)
    }

    @Test("Background Task Ownership: Targeted termination by runID/sessionID isolates other tasks")
    func testBackgroundTaskOwnershipAndTargetedTermination() async throws {
        let manager = BackgroundCommandManager()
        let tempDir = FileManager.default.temporaryDirectory
        let workspace = try WorkspaceRoot(path: tempDir.path)
        let profile = ExecutionProfile.workspace

        let session1 = SessionID(UUID().uuidString)
        let run1 = RunID()
        let session2 = SessionID(UUID().uuidString)
        let run2 = RunID()

        // Spawn task 1 under run1
        let task1 = try await manager.spawn(
            command: "sleep 10",
            timeoutSeconds: 30,
            cwd: tempDir,
            workspace: workspace,
            profile: profile,
            customID: "task-1",
            sessionID: session1,
            runID: run1
        )
        #expect(task1.status == BackgroundTaskStatus.running)

        // Spawn task 2 under run2
        let task2 = try await manager.spawn(
            command: "sleep 10",
            timeoutSeconds: 30,
            cwd: tempDir,
            workspace: workspace,
            profile: profile,
            customID: "task-2",
            sessionID: session2,
            runID: run2
        )
        #expect(task2.status == BackgroundTaskStatus.running)

        // Terminate tasks belonging to run1 only
        await manager.terminateTasks(runID: run1)

        let snap1 = try await manager.poll(id: "task-1")
        #expect(snap1.status == BackgroundTaskStatus.terminated)

        let snap2 = try await manager.poll(id: "task-2")
        #expect(snap2.status == BackgroundTaskStatus.running)

        // Cleanup task2
        _ = try? await manager.terminate(id: "task-2")
    }

    @Test("Branch Prediction Fabric: Variable-Order Markov Predictor with n-gram back-off and calibration")
    func testBranchPredictionVOMMAndCalibration() {
        let predictor = VariableOrderMarkovPredictor(maxOrder: 2)

        // Pattern: [read_file -> search_code -> edit_file -> run_command] repeated
        let t1 = ActionToken.tool(name: "read_file")
        let t2 = ActionToken.tool(name: "search_code")
        let t3 = ActionToken.tool(name: "edit_file")
        let t4 = ActionToken.tool(name: "run_command")

        let trainSeq: [[ActionToken]] = [
            [t1, t2, t3, t4, t1, t2, t3, t4],
            [t1, t2, t3, t4, t1, t2, t3, t4]
        ]
        predictor.train(sequences: trainSeq)

        // Test prediction given 2-gram context [t1, t2] -> should predict t3
        let predOrder2 = predictor.predictNext(context: [t1, t2])
        #expect(predOrder2.matchedOrder == 2)
        #expect(predOrder2.top1 == t3)
        #expect(predOrder2.topConfidence >= 0.99)

        // Test prediction given unseen 2-gram [t4, t2] -> should back-off to 1-gram [t2] -> predicts t3
        let predBackoff = predictor.predictNext(context: [t4, t2])
        #expect(predBackoff.matchedOrder == 1)
        #expect(predBackoff.top1 == t3)

        // Test offline evaluation metrics
        let testSeq: [[ActionToken]] = [
            [t1, t2, t3, t4, t1, t2, t3, t4]
        ]
        let metrics = predictor.evaluate(testSequences: testSeq)
        #expect(metrics.totalSamples > 0)
        #expect(metrics.top1Accuracy >= 0.8)
        #expect(metrics.top3Accuracy >= 0.9)
        #expect(metrics.brierScore < 0.5)
        #expect(metrics.expectedCalibrationError <= 0.3)
    }

    @Test("Trajectory Extractor: Preserves model decision order and records user interrupts")
    func testTrajectoryExtractionDecisionOrder() {
        let sessionID = SessionID(UUID().uuidString)
        let extractor = TrajectoryExtractor()

        let call1 = ToolInvocationSnapshot(
            callID: ToolCallID("call-1"),
            toolID: ToolID("file_search"),
            displayName: "Search",
            argumentsSummary: "{}",
            state: .completed,
            resultPreview: nil,
            resultRef: nil,
            durationMs: 10.0,
            error: nil
        )
        let call2 = ToolInvocationSnapshot(
            callID: ToolCallID("call-2"),
            toolID: ToolID("file_read"),
            displayName: "Read",
            argumentsSummary: "{}",
            state: .completed,
            resultPreview: nil,
            resultRef: nil,
            durationMs: 10.0,
            error: nil
        )

        let genID = EventLogGenerationID(sessionID.rawValue)
        let records: [SessionEventEnvelope] = [
            SessionEventEnvelope(
                cursor: EventCursor(generationID: genID, sequence: 1),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .toolRequested(call1)
            ),
            SessionEventEnvelope(
                cursor: EventCursor(generationID: genID, sequence: 2),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .toolRequested(call2)
            ),
            SessionEventEnvelope(
                cursor: EventCursor(generationID: genID, sequence: 3),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .assistantMessageCommitted(messageID: MessageID(), content: "Done", assistantFinalIndex: 1)
            ),
            SessionEventEnvelope(
                cursor: EventCursor(generationID: genID, sequence: 4),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .turnCompleted(turnID: TurnID(), terminalReason: .userCancelled)
            )
        ]

        let tokens = extractor.extract(from: records)
        #expect(tokens == [
            .tool(name: "file_search"),
            .tool(name: "file_read"),
            .directAnswer,
            .cancel
        ])
    }
}
