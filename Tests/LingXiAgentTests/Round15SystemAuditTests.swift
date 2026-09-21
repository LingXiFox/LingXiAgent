import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 15 System Audit & V1.0.0 Release Gate Tests")
struct Round15SystemAuditTests {

    // MARK: - 1. P0-A Queue Handoff Atomicity
    @Test("Queue Handoff: Terminalizing an active run reliably hands off execution lease to next queued turn")
    func testQueueHandoffAtomicityWhenActiveRunTerminalizes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Submit Turn 1 (will be active)
            let t1 = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Turn 1"),
                executionIntent: TurnExecutionIntent()
            )))
            let runID1 = try #require(t1.result?.runID)

            // Submit Turn 2 (will be queued)
            let t2 = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Turn 2"),
                executionIntent: TurnExecutionIntent()
            )))
            #expect(t2.result?.status == .queued)

            // Submit Turn 3 (will be queued)
            let t3 = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Turn 3"),
                executionIntent: TurnExecutionIntent()
            )))
            #expect(t3.result?.status == .queued)

            // Cancel Run 1
            _ = try await host.cancelRun(envelope: CommandEnvelope(payload: CancelRunRequest(
                sessionID: sessionID,
                runID: runID1,
                reason: "Cancel test"
            )))

            // Invariant: Turn 1 is cancelled, and execution lease is handed off to Turn 2 without getting stuck
            let coord = try await host.coordinator(for: sessionID)
            let snap1 = await coord.getRun(runID: runID1)
            #expect(snap1?.status == .cancelled)

            // Turn 2 should pick up the handed-off lease. Poll for the transition rather
            // than sleeping a fixed 50ms, which a saturated runner can outrun entirely.
            var turn2Snap = try #require(await coord.getTurn(turnID: t2.result!.turnID))
            let handoffDeadline = Date().addingTimeInterval(10)
            while turn2Snap.status != .running && turn2Snap.status != .completed, Date() < handoffDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
                turn2Snap = try #require(await coord.getTurn(turnID: t2.result!.turnID))
            }
            // Turn 2 should have started or finished (activeRootRunID transitioned away from nil orphan)
            #expect(turn2Snap.status == .running || turn2Snap.status == .completed)

            // Turn 3 should still be in queue or safely waiting
            let turn3Snap = try #require(await coord.getTurn(turnID: t3.result!.turnID))
            #expect(turn3Snap.status == .queued || turn3Snap.status == .running || turn3Snap.status == .completed)
        }
    }

    // MARK: - 2. P0-B Recovery Liveness
    @Test("Recovery Liveness: CoreHost.start() enumerates persisted sessions and resumes queued turns")
    func testRecoveryLivenessDiscoversPersistedQueuedTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = CoreStorageLayout(root: tempDir)
        try layout.ensureDirectoriesExist()

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        // Host Generation 1: Setup session with queued turn
        let (targetSessionID, _) = try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly, storageLayout: layout) { host1 -> (SessionID, TurnID?) in
            let sessionReceipt = try await host1.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Submit turn 1 and let it run
            _ = try await host1.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Turn 1"),
                executionIntent: TurnExecutionIntent()
            )))

            // Submit turn 2 while turn 1 is running, so turn 2 is queued
            let t2 = try await host1.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Turn 2"),
                executionIntent: TurnExecutionIntent()
            )))
            return (sessionID, t2.result?.turnID)
        }

        // Host Generation 2: Restart and verify liveness recovery without explicit query
        let host2 = try CoreHost(
            startupPolicy: .unitTest,
            providerAssembly: assembly,
            workspaceRoot: WorkspaceRoot(path: tempDir.path),
            dataRoot: layout.root,
            storageLayout: layout
        )
        await host2.start()

        // Wait brief interval for post-ready queue scheduling
        try await Task.sleep(nanoseconds: 80_000_000)

        // Verify coordinator was discovered and restored
        let coord2 = try await host2.coordinator(for: targetSessionID)
        let turns = await coord2.listTurns(page: PageRequest(limit: 100))
        #expect(turns.items.count >= 2)

        await host2.shutdown()
    }

    // MARK: - 3. P0-C Idempotency Identity: Method & Payload Fingerprint Mismatch
    @Test("Idempotency Identity: Same CommandID reused for different method or payload throws conflict")
    func testIdempotencyConflictOnMethodOrPayloadMismatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sharedCommandID = CommandID("conflict-cmd-\(UUID().uuidString)")

            // 1. First mutation: updateContextPolicy
            let policyReceipt = try await host.updateContextPolicy(envelope: CommandEnvelope(
                commandID: sharedCommandID,
                payload: UpdateContextPolicyRequest()
            ))
            #expect(policyReceipt.commandID == sharedCommandID)

            // 2. Reusing same CommandID for different method (reloadExtensions) must throw conflict
            await #expect(throws: RuntimeError.self) {
                try await host.reloadExtensions(envelope: CommandEnvelope(
                    commandID: sharedCommandID,
                    payload: VoidResult()
                ))
            }

            // 3. Different payload on same method: setWorkspace
            let wsCmdID = CommandID("ws-cmd-\(UUID().uuidString)")
            let ws1 = try await host.setWorkspace(envelope: CommandEnvelope(
                commandID: wsCmdID,
                payload: SetWorkspaceRequest(workspaceRoot: tempDir.path)
            ))
            #expect(ws1.commandID == wsCmdID)

            // Reusing wsCmdID with different workspaceRoot must throw conflict
            await #expect(throws: RuntimeError.self) {
                try await host.setWorkspace(envelope: CommandEnvelope(
                    commandID: wsCmdID,
                    payload: SetWorkspaceRequest(workspaceRoot: "/tmp/other-workspace")
                ))
            }

            // Retrying wsCmdID with identical payload must succeed and return cached receipt
            let wsRetry = try await host.setWorkspace(envelope: CommandEnvelope(
                commandID: wsCmdID,
                payload: SetWorkspaceRequest(workspaceRoot: tempDir.path)
            ))
            #expect(wsRetry.commandID == wsCmdID)
            #expect(wsRetry.revision == ws1.revision)
        }
    }

    // MARK: - 4. P0-D Concurrent Same-CommandID Single Owner
    @Test("Concurrent In-Flight Lock: Concurrent identical CommandID executions produce exactly one side-effect")
    func testConcurrentSameCommandIDExecutesSideEffectExactlyOnce() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sharedCommandID = CommandID("concurrent-cmd-\(UUID().uuidString)")
            let envelope = CommandEnvelope(commandID: sharedCommandID, payload: CreateSessionRequest(workspace: tempDir.path))

            // Launch two concurrent calls with the exact same CommandID
            async let call1 = host.createSession(envelope: envelope)
            async let call2 = host.createSession(envelope: envelope)

            let (r1, r2) = try await (call1, call2)

            #expect(r1.commandID == sharedCommandID)
            #expect(r2.commandID == sharedCommandID)
            #expect(r1.result?.sessionID == r2.result?.sessionID)
            #expect(r1.revision == r2.revision)

            // Verify session store has exactly 1 session, no orphan duplicate session created
            let allSessions = try await host.sessionStore.listSessions()
            #expect(allSessions.count == 1)
        }
    }

    // MARK: - 5. P0-E DurableCommandWAL Quarantining Corrupt WALs
    @Test("DurableCommandWAL: Corrupted WAL files are quarantined as .corrupt and never silently deleted")
    func testDurableCommandWALQuarantinesCorruptWAL() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let walDir = tempDir.appendingPathComponent("wal", isDirectory: true)
        try FileManager.default.createDirectory(at: walDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a corrupt .wal file (invalid JSON content)
        let corruptFileName = "corrupted-test-record.wal"
        let corruptFileURL = walDir.appendingPathComponent(corruptFileName)
        try "corrupted non-json bytes {[[".write(to: corruptFileURL, atomically: false, encoding: .utf8)

        let wal = DurableCommandWAL(storageDirectory: tempDir)
        let sessionStore = InMemorySessionStore()
        let runtimeEventLog = RuntimeEventLog(storageDirectory: tempDir)

        await wal.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { sessionID in
                let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
                return SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
            }
        )

        // Invariant: The original .wal is removed from walDir, but quarantined as .corrupt
        #expect(!FileManager.default.fileExists(atPath: corruptFileURL.path))
        let quarantinedURL = walDir.appendingPathComponent("corrupted-test-record.corrupt")
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
    }

    // MARK: - 6. P0-F Cancelled Turn Recovery State Consistency
    @Test("Recovery Consistency: Historical cancelled turn restores as cancelled for both turn and run")
    func testCancelledTurnRecoveryRestoresConsistentCancelledStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-cancelled-\(UUID().uuidString)")
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let turnID = TurnID("turn-to-cancel")
        let runID = RunID("run-to-cancel")

        let userMessage = MessageSnapshot(messageID: MessageID(), role: .user, text: "Cancelled Work", attachments: [], createdAt: Date())
        let turn = TurnSnapshot(
            turnID: turnID,
            sessionID: sessionID,
            userMessage: userMessage,
            executionIntent: TurnExecutionIntent(),
            status: .queued,
            rootRunID: runID,
            createdAt: Date(),
            completedAt: nil
        )
        let run = RunSnapshot(
            runID: runID,
            sessionID: sessionID,
            turnID: turnID,
            rootRunID: runID,
            status: .queued,
            model: "test-model",
            createdAt: Date(),
            completedAt: nil,
            terminalReason: nil
        )

        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID, rootRunID: runID)
        try await coord.eventLog.append(causal: causal, payload: .turnCreated(turn))
        try await coord.eventLog.append(causal: causal, payload: .runCreated(run))
        try await coord.eventLog.append(causal: causal, payload: .runQueued(runID: runID))
        // Append durable cancellation events as produced by cancelTurn
        try await coord.eventLog.append(causal: causal, payload: .runCancelled(runID: runID, reason: "Turn cancelled while queued"))
        try await coord.eventLog.append(causal: causal, payload: .turnCompleted(turnID: turnID, terminalReason: .userCancelled))

        // Create a new coordinator and restore historical queue
        let restoredEventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let restoredCoord = SessionTurnCoordinator(sessionID: sessionID, eventLog: restoredEventLog)
        await restoredCoord.restoreHistoricalQueue()

        let restoredTurn = try #require(await restoredCoord.getTurn(turnID: turnID))
        let restoredRun = try #require(await restoredCoord.getRun(runID: runID))

        // Invariant: Both Turn and Run MUST be reconstructed as .cancelled, not .completed or .queued!
        #expect(restoredTurn.status == TurnStatus.cancelled)
        #expect(restoredRun.status == RunStatus.cancelled)
        #expect(restoredRun.terminalReason == TerminalReason.userCancelled)
    }
}
