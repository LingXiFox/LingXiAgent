import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Round 12 System Audit & Agent Loop Invariant Tests")
struct Round12SystemAuditTests {

    @Test("P0-A Single Terminalization Winner: Cancel A with B and C queued starts B once and never advances C")
    func testSingleTerminalizationQueueAdvanceWinner() async throws {
        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Turn A starts running
        let decisionA = try await coordinator.submitTurn(
            input: UserInput(text: "Prompt A"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Prompt A", createdAt: Date())
        )
        let runIDA = try #require(decisionA.runID)
        #expect(await coordinator.activeRootRunID == runIDA)

        // Turn B and Turn C queued
        let decisionB = try await coordinator.submitTurn(
            input: UserInput(text: "Prompt B"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Prompt B", createdAt: Date())
        )
        let runIDB = try #require(decisionB.runID)

        let decisionC = try await coordinator.submitTurn(
            input: UserInput(text: "Prompt C"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Prompt C", createdAt: Date())
        )
        _ = try #require(decisionC.runID)

        #expect(await coordinator.isTurnQueued(turnID: decisionB.turn.turnID))
        #expect(await coordinator.isTurnQueued(turnID: decisionC.turn.turnID))

        // Trigger cancelRun on A: exactly-once winner transition
        let next1 = try await coordinator.cancelRun(runID: runIDA, reason: "userCancelled")
        let scheduled = try #require(next1)

        // Verify: B becomes active root, C remains queued
        #expect(scheduled.runID == runIDB)
        #expect(await coordinator.activeRootRunID == runIDB)
        #expect(await coordinator.isTurnQueued(turnID: decisionB.turn.turnID) == false)
        #expect(await coordinator.isTurnQueued(turnID: decisionC.turn.turnID) == true)

        let runASnap = await coordinator.getRun(runID: runIDA)
        #expect(runASnap?.status == RunStatus.cancelled)
        #expect(runASnap?.terminalReason == TerminalReason.userCancelled)

        // Duplicate terminalization attempts (e.g. from cancellation catch path or late callback)
        // must be idempotent no-op and NEVER advance queue to C!
        let next2 = await coordinator.finishRun(runID: runIDA, reason: .userCancelled)
        #expect(next2 == nil)

        let next3 = try await coordinator.cancelRun(runID: runIDA, reason: "userCancelled")
        #expect(next3 == nil)

        // Verify active root run is STILL B, and C is STILL queued (no multi-root concurrency)
        #expect(await coordinator.activeRootRunID == runIDB)
        #expect(await coordinator.isTurnQueued(turnID: decisionC.turn.turnID) == true)
    }

    @Test("P0-D Validation Before Destruction: Cancel invalid TurnID throws turnNotFound with zero side effects")
    func testCancelInvalidTurnSideEffectFree() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))
        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionSummary = try #require(sessionReceipt.result)
            let sessionID = sessionSummary.sessionID

            // Start active Turn A
            let submitEnvelope = CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Active A"), executionIntent: TurnExecutionIntent())
            )
            let submitReceipt = try await host.submitTurn(envelope: submitEnvelope)
            let submitDecision = try #require(submitReceipt.result)
            let runIDA = try #require(submitDecision.runID)

            let coord = try await host.coordinator(for: sessionID)
            #expect(await coord.activeRootRunID == runIDA)

            // Attempt cancel with non-existent fake TurnID
            let fakeTurnID = TurnID("non-existent-turn")
            let cancelEnvelope = CommandEnvelope(
                payload: CancelTurnRequest(sessionID: sessionID, turnID: fakeTurnID)
            )

            await #expect(throws: RuntimeError.self) {
                try await host.cancelTurn(envelope: cancelEnvelope)
            }

            // Invariant: Turn A is still running, activeRootRunID is still runIDA (zero side effect)
            #expect(await coord.activeRootRunID == runIDA)
            let runSnap = await coord.getRun(runID: runIDA)
            #expect(runSnap?.status == RunStatus.running)
        }
    }

    @Test("P0-D Validation Before Destruction: cancelTurn on running Turn rejects with turnAlreadyRunning and leaves active run intact")
    func testCancelRunningTurnRejectionLeavesRunIntact() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))
        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionSummary = try #require(sessionReceipt.result)
            let sessionID = sessionSummary.sessionID

            let submitReceipt = try await host.submitTurn(envelope: CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Active Turn"), executionIntent: TurnExecutionIntent())
            ))
            let submitDecision = try #require(submitReceipt.result)
            let turnIDA = submitDecision.turnID
            let runIDA = try #require(submitDecision.runID)

            let coord = try await host.coordinator(for: sessionID)
            #expect(await coord.activeRootRunID == runIDA)

            // Calling cancelTurn on running turn must be rejected with turnAlreadyRunning
            let cancelEnvelope = CommandEnvelope(
                payload: CancelTurnRequest(sessionID: sessionID, turnID: turnIDA)
            )

            do {
                _ = try await host.cancelTurn(envelope: cancelEnvelope)
                Issue.record("Expected turnAlreadyRunning error")
            } catch let err as RuntimeError {
                #expect(err.code == "turnAlreadyRunning")
            }

            // Invariant: Active Run A remains intact and running
            #expect(await coord.activeRootRunID == runIDA)
            let runSnap = await coord.getRun(runID: runIDA)
            #expect(runSnap?.status == RunStatus.running)
        }
    }

    @Test("P0-D Cancel Queued Run Scope: cancelRun on queued run cancels only target and leaves active run untouched")
    func testCancelQueuedRunIsolatesActiveRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))
        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionSummary = try #require(sessionReceipt.result)
            let sessionID = sessionSummary.sessionID

            // Turn A running
            let receiptA = try await host.submitTurn(envelope: CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Run A"), executionIntent: TurnExecutionIntent())
            ))
            let decisionA = try #require(receiptA.result)
            let runIDA = try #require(decisionA.runID)

            // Turn B queued
            let receiptB = try await host.submitTurn(envelope: CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Run B"), executionIntent: TurnExecutionIntent())
            ))
            let decisionB = try #require(receiptB.result)
            let runIDB = try #require(decisionB.runID)

            let coord = try await host.coordinator(for: sessionID)
            #expect(await coord.activeRootRunID == runIDA)
            #expect(await coord.isTurnQueued(turnID: decisionB.turnID))

            // Cancel queued Run B
            let cancelReceipt = try await host.cancelRun(envelope: CommandEnvelope(
                payload: CancelRunRequest(sessionID: sessionID, runID: runIDB, reason: "userCancelled")
            ))
            #expect(cancelReceipt.applied == true)

            // Invariant: B is cancelled and removed from queue
            #expect(await coord.isTurnQueued(turnID: decisionB.turnID) == false)
            let runBSnap = await coord.getRun(runID: runIDB)
            #expect(runBSnap?.status == RunStatus.cancelled)

            // Invariant: Run A is still active and running!
            #expect(await coord.activeRootRunID == runIDA)
            let runASnap = await coord.getRun(runID: runIDA)
            #expect(runASnap?.status == RunStatus.running)
        }
    }

    @Test("P0-C Queue Durability: Coordinator restores uncompleted queued turns on restart")
    func testQueueDurabilityRestorationOnRestart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord1 = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Submit A (running)
        let decisionA = try await coord1.submitTurn(
            input: UserInput(text: "Active prompt"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Active prompt", createdAt: Date())
        )
        _ = try #require(decisionA.runID)

        // Submit B (queued)
        let msgIDB = MessageID()
        let decisionB = try await coord1.submitTurn(
            input: UserInput(text: "Queued prompt"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: msgIDB, role: .user, text: "Queued prompt", createdAt: Date())
        )
        let turnIDB = decisionB.turn.turnID
        let runIDB = try #require(decisionB.runID)

        #expect(await coord1.isTurnQueued(turnID: turnIDB))

        // Simulate crash/restart: create a new coordinator instance reading the persisted event log
        let restartedEventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord2 = SessionTurnCoordinator(sessionID: sessionID, eventLog: restartedEventLog)
        await coord2.restoreHistoricalQueue()

        // Invariant: Turn B is recovered in queuedTurns, turns, and runs
        #expect(await coord2.isTurnQueued(turnID: turnIDB))
        let recoveredTurnB = await coord2.getTurn(turnID: turnIDB)
        #expect(recoveredTurnB != nil)
        #expect(recoveredTurnB?.userMessage.messageID == msgIDB)
        #expect(recoveredTurnB?.status == TurnStatus.queued)

        let recoveredRunB = await coord2.getRun(runID: runIDB)
        #expect(recoveredRunB != nil)
        #expect(recoveredRunB?.status == RunStatus.queued)
    }

    @Test("P0 Background Ownership: Real Tool automatically inherits owner sessionID and runID from context")
    func testBackgroundCommandToolInheritsOwnerContext() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let manager = BackgroundCommandManager()
        let tool = RunBackgroundCommandTool(workspace: workspace, manager: manager)

        let testSessionID = SessionID(UUID().uuidString)
        let testRunID = RunID(UUID().uuidString)

        // Execute tool inside ToolExecutionContext with sessionID and runID set
        let jsonResult = try await ToolExecutionContext.$sessionID.withValue(testSessionID) {
            try await ToolExecutionContext.$runID.withValue(testRunID) { () async throws -> String in
                try await tool.execute(
                    arguments: #"{"command": "echo hello", "timeout_seconds": 30, "description": "ownership test"}"#,
                    profile: .workspace
                )
            }
        }

        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(BackgroundTaskSnapshot.self, from: Data(jsonResult.utf8))

        // Invariant: Task in manager state must inherit the exact causal owner
        let owner = await manager.taskOwner(id: snapshot.id)
        #expect(owner?.sessionID == testSessionID)
        #expect(owner?.runID == testRunID)
    }

    @Test("Predictor Regression: Real cancel event yields exactly one .cancel token and never duplicates")
    func testPredictorRealCancelEventExtraction() async throws {
        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let decision = try await coordinator.submitTurn(
            input: UserInput(text: "Run to cancel"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Run to cancel", createdAt: Date())
        )
        let runID = try #require(decision.runID)

        // Cancel run using real coordinator cancel path
        _ = try await coordinator.cancelRun(runID: runID, reason: "userCancelled")

        let events = await eventLog.allEvents()
        let extractor = TrajectoryExtractor()
        let tokens = extractor.extract(from: events)

        // Invariant: Exactly one .cancel token, NO double cancel, NO .userInterrupt
        let cancelTokens = tokens.filter { $0 == .cancel }
        #expect(cancelTokens.count == 1)
        #expect(!tokens.contains(.userInterrupt))
    }

    @Test("Predictor Regression: Context-key encoding is injective and resists delimiter collision")
    func testPredictorContextKeyCollisionResistance() {
        let predictor = VariableOrderMarkovPredictor(maxOrder: 2)

        // Path A: [tool("a|tool:b")] -> [directAnswer]
        let seqA: [ActionToken] = [.tool(name: "a|tool:b"), .directAnswer]
        // Path B: [tool("a"), tool("b")] -> [finish]
        let seqB: [ActionToken] = [.tool(name: "a"), .tool(name: "b"), .finish]

        predictor.train(sequences: [seqA, seqB])

        // Predict on context A: must predict directAnswer
        let predA = predictor.predictNext(context: [.tool(name: "a|tool:b")])
        #expect(predA.top1 == .directAnswer)

        // Predict on context B: must predict finish
        let predB = predictor.predictNext(context: [.tool(name: "a"), .tool(name: "b")])
        #expect(predB.top1 == .finish)

        // Invariant: Support is explicitly tracked and observable
        #expect(predA.support == 1)
        #expect(predB.support == 1)
    }
}
