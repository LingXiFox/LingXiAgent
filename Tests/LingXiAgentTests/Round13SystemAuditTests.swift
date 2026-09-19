import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 13 System Audit & Architecture Hardening Tests")
struct Round13SystemAuditTests {

    // MARK: - 1. VNext End-to-End Command ID & Revision Preservation
    @Test("VNext Envelope metadata preservation: Client commandID and expectedRevision pass end-to-end to Server & Receipt")
    func testVNextCommandIDAndRevisionPreservedEndToEnd() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Setup in-process client connected to service to simulate full protocol transport contract
            let client = try await LingXiClientVNext.connectInProcess(service: host, handshakeImmediately: false)

            let fixedCommandID = CommandID("c-fixed-\(UUID().uuidString)")
            let fixedRevision: UInt64 = 42
            let envelope = CommandEnvelope(
                commandID: fixedCommandID,
                issuedAt: Date(),
                expectedRevision: fixedRevision,
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Hello IPC"), executionIntent: TurnExecutionIntent())
            )

            let receipt = try await client.turn.submitTurn(envelope: envelope)

            // Invariant: Receipt returns the EXACT same commandID created by client
            #expect(receipt.commandID == fixedCommandID)
            #expect(receipt.applied == true)

            // Invariant: CoreHost WAL recorded the exact client commandID
            let walReceipt = await host.commandWAL.getCommittedReceipt(commandID: fixedCommandID, as: SubmitTurnResult.self)
            #expect(walReceipt != nil)
            #expect(walReceipt?.commandID == fixedCommandID)
        }
    }

    // MARK: - 2. VNext Idempotent Retry
    @Test("VNext Idempotency: Retrying with identical commandID executes business logic exactly once")
    func testVNextIdempotentRetrySameCommandID() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            let client = try await LingXiClientVNext.connectInProcess(service: host, handshakeImmediately: false)

            let fixedCommandID = CommandID("retry-cmd-\(UUID().uuidString)")
            let envelope = CommandEnvelope(
                commandID: fixedCommandID,
                issuedAt: Date(),
                expectedRevision: nil,
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Idempotency check"), executionIntent: TurnExecutionIntent())
            )

            // Send first time
            let receipt1 = try await client.turn.submitTurn(envelope: envelope)
            #expect(receipt1.commandID == fixedCommandID)

            // Retry second time with identical commandID
            let receipt2 = try await client.turn.submitTurn(envelope: envelope)
            #expect(receipt2.commandID == fixedCommandID)
            #expect(receipt2.result?.turnID == receipt1.result?.turnID)
            #expect(receipt2.result?.runID == receipt1.result?.runID)

            // Verify only ONE turn was actually created in coordinator
            let coord = try await host.coordinator(for: sessionID)
            let allTurns = await coord.queuedTurnsSnapshot
            let activeRunID = await coord.activeRootRunID
            #expect(activeRunID == receipt1.result?.runID)
            #expect(allTurns.isEmpty)
        }
    }

    // MARK: - 3. Queue Recovery FIFO
    @Test("Recovery FIFO: Restored queued turn is never bypassed by newly submitted turns after restart")
    func testRecoveryFIFOPreservesQueueOrder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord1 = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Turn A active
        let decA = try await coord1.submitTurn(
            input: UserInput(text: "Turn A"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Turn A", createdAt: Date())
        )
        _ = try #require(decA.runID)

        // Turn B queued
        let msgIDB = MessageID()
        let decB = try await coord1.submitTurn(
            input: UserInput(text: "Turn B"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: msgIDB, role: .user, text: "Turn B", createdAt: Date())
        )
        let turnIDB = decB.turn.turnID
        #expect(await coord1.isTurnQueued(turnID: turnIDB))

        // Crash and restart with fresh coordinator instance
        let restartedEventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord2 = SessionTurnCoordinator(sessionID: sessionID, eventLog: restartedEventLog)
        await coord2.restoreHistoricalQueue()

        // Submit new Turn C
        let decC = try await coord2.submitTurn(
            input: UserInput(text: "Turn C"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Turn C", createdAt: Date())
        )
        let turnIDC = decC.turn.turnID

        // Invariant: Turn B MUST remain ahead of Turn C in FIFO queue order!
        #expect(decC.status == .queued)
        #expect(decC.shouldStartExecution == false)
        #expect(await coord2.queuedTurnsSnapshot.first?.turnID == turnIDB)
        #expect(await coord2.queuedTurnsSnapshot.last?.turnID == turnIDC)
    }

    // MARK: - 4. Crash During Started Run Never Restores as Queued
    @Test("Crash Recovery Safety: Started-but-nonterminal run is marked aborted/failed and never requeued from scratch")
    func testCrashDuringStartedRunNeverRestoresAsQueued() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord1 = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Submit B as queued
        let decB = try await coord1.submitTurn(
            input: UserInput(text: "Run B"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Run B", createdAt: Date())
        )
        let runIDB = try #require(decB.runID)

        // Simulate B actually started (e.g. executed tool/side-effect)
        let causal = CausalContext(sessionID: sessionID, turnID: decB.turn.turnID, runID: runIDB, rootRunID: runIDB)
        try await eventLog.append(causal: causal, payload: .runStarted(runID: runIDB))

        // Crash before terminal event!
        // Now restart:
        let restartedEventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord2 = SessionTurnCoordinator(sessionID: sessionID, eventLog: restartedEventLog)
        await coord2.restoreHistoricalQueue()

        // Invariant: B was already started, so it MUST NOT be requeued to run again!
        #expect(await coord2.isTurnQueued(turnID: decB.turn.turnID) == false)
        let restoredRunB = await coord2.getRun(runID: runIDB)
        #expect(restoredRunB?.status == RunStatus.failed)
        #expect(restoredRunB?.terminalReason == TerminalReason.runtimeFailure)
    }

    // MARK: - 5. Run Created Exactly Once
    @Test("Event Invariant: Run entity emits runCreated exactly once from queue to execution completion")
    func testRunCreatedExactlyOnceFromQueueToCompletion() async throws {
        let sessionID = SessionID(UUID().uuidString)
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Turn A active
        let decA = try await coord.submitTurn(
            input: UserInput(text: "Active A"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Active A", createdAt: Date())
        )
        let runIDA = try #require(decA.runID)

        // Turn B queued
        let decB = try await coord.submitTurn(
            input: UserInput(text: "Queued B"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Queued B", createdAt: Date())
        )
        let runIDB = try #require(decB.runID)

        // Finish A: triggers scheduling of B
        let nextToRun = await coord.finishRun(runID: runIDA, reason: .completed)
        let scheduled = try #require(nextToRun)
        #expect(scheduled.runID == runIDB)

        // Finish B
        _ = await coord.finishRun(runID: runIDB, reason: .completed)

        // Verify EventLog: runCreated for B must appear EXACTLY once!
        let allEvents = await eventLog.allEvents()
        var runBCreatedCount = 0
        for env in allEvents {
            if case let .runCreated(snap) = env.payload, snap.runID == runIDB {
                runBCreatedCount += 1
            }
        }
        #expect(runBCreatedCount == 1)
    }

    // MARK: - 6. Predictor Deterministic Tie-Breaker
    @Test("Predictor Determinism: Equal probability candidates sort deterministically without dictionary order fluctuation")
    func testPredictorDeterministicTieBreaking() {
        let predictor = VariableOrderMarkovPredictor(maxOrder: 2)

        // 50% tool:read, 50% tool:test
        predictor.train(sequences: [
            [.tool(name: "read")],
            [.tool(name: "test")]
        ])

        let result1 = predictor.predictNext(context: [])
        let result2 = predictor.predictNext(context: [])

        #expect(result1.candidates.count == 2)
        #expect(result1.candidates[0].token.description == result2.candidates[0].token.description)
        #expect(result1.candidates[1].token.description == result2.candidates[1].token.description)
        #expect(result1.candidates[0].token.description == "tool:read")
        #expect(result1.candidates[1].token.description == "tool:test")
    }

    // MARK: - 7. Predictor Episode Boundary Separation
    @Test("Predictor Episode Boundary: Extractor splits events into distinct episodes by terminal boundary")
    func testPredictorEpisodeBoundarySeparation() {
        let extractor = TrajectoryExtractor()
        let sessionID = SessionID("test-sess")

        let run1 = RunID("run-1")
        let run2 = RunID("run-2")

        let events: [SessionEventEnvelope] = [
            // Run 1: edit -> finish
            SessionEventEnvelope(
                cursor: EventCursor(generationID: "gen-1", sequence: 1),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID, runID: run1),
                payload: .toolRequested(ToolInvocationSnapshot(
                    callID: ToolCallID("c1"),
                    toolID: ToolID("edit"),
                    displayName: "edit",
                    argumentsSummary: "{}",
                    state: .requested
                ))
            ),
            SessionEventEnvelope(
                cursor: EventCursor(generationID: "gen-1", sequence: 2),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID, runID: run1),
                payload: .runCompleted(runID: run1, terminalReason: .completed)
            ),
            // Run 2: read -> finish
            SessionEventEnvelope(
                cursor: EventCursor(generationID: "gen-1", sequence: 3),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID, runID: run2),
                payload: .toolRequested(ToolInvocationSnapshot(
                    callID: ToolCallID("c2"),
                    toolID: ToolID("read"),
                    displayName: "read",
                    argumentsSummary: "{}",
                    state: .requested
                ))
            ),
            SessionEventEnvelope(
                cursor: EventCursor(generationID: "gen-1", sequence: 4),
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID, runID: run2),
                payload: .runCompleted(runID: run2, terminalReason: .completed)
            )
        ]

        let episodes = extractor.extractEpisodes(from: events)
        #expect(episodes.count == 2)
        #expect(episodes[0] == [.tool(name: "edit"), .finish])
        #expect(episodes[1] == [.tool(name: "read"), .finish])

        // Verify training on these episodes does NOT learn false transition .finish -> .tool(read)
        let predictor = VariableOrderMarkovPredictor(maxOrder: 2)
        predictor.train(sequences: episodes)

        let predAfterFinish = predictor.predictNext(context: [.finish])
        // Should NOT predict read with high confidence as transition from finish
        #expect(predAfterFinish.matchedOrder == 0) // Did not find a context matching order 1 after finish!
    }

    // MARK: - 8. Predictor Low Support Telemetry Flag
    @Test("Predictor Telemetry: Low support is explicitly flagged in PredictionSnapshot")
    func testPredictorLowSupportTelemetryFlag() {
        let result = PredictionResult(
            top1: .tool(name: "test"),
            topConfidence: 1.0,
            support: 1,
            matchedOrder: 4,
            candidates: [
                PredictionResult.Candidate(token: .tool(name: "test"), probability: 1.0, count: 1)
            ]
        )

        let snapshot = result.makeSnapshot(epoch: 1, sessionID: "session-1", runID: "run-1")
        #expect(snapshot.top1Action == "tool:test")
        #expect(snapshot.topConfidence == 1.0)
        #expect(snapshot.isLowSupport == true)
        #expect(snapshot.mode == "shadow")
        #expect(snapshot.compactSummary.contains("LOW SUPPORT"))
        #expect(snapshot.compactSummary.contains("TEST 100%"))
        #expect(snapshot.compactSummary.contains("n=1"))
    }
}
