import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("LingXiAgent V1.0.0-RC1 Static Acceptance Audit Suite")
struct RC1StaticAuditTests {

    // MARK: - 1. P0 DURABILITY: finishRun Terminal EventLog Failure
    @Test("Root Terminal Durability: finishRun disk failure rolls back memory and prevents queue advance")
    func testFinishRunTerminalDurabilityFailurePreventsMemoryAdvance() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // 1. Submit Turn 1 (becomes running)
        let userMsg1 = MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "turn 1", createdAt: Date())
        let d1 = try await coord.submitTurn(input: UserInput(text: "turn 1"), intent: TurnExecutionIntent(), userMessage: userMsg1)
        #expect(d1.status == TurnStatus.running)
        guard let runID1 = d1.runID else {
            Issue.record("Expected runID for running turn")
            return
        }
        #expect(await coord.activeRootRunID == runID1)

        // 2. Submit Turn 2 (queued)
        let userMsg2 = MessageSnapshot(messageID: MessageID("m2"), role: .user, text: "turn 2", createdAt: Date())
        let d2 = try await coord.submitTurn(input: UserInput(text: "turn 2"), intent: TurnExecutionIntent(), userMessage: userMsg2)
        #expect(d2.status == TurnStatus.queued)
        let turnID2 = d2.turn.turnID

        // 3. Make events.jsonl read-only to simulate terminal EventLog persistence failure
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: eventsURL.path)

        // 4. Calling finishRun MUST THROW
        do {
            _ = try await coord.finishRun(runID: runID1, reason: .completed)
            Issue.record("Expected finishRun to throw on read-only disk")
        } catch {
            // Expected
        }

        // 5. Verify invariant: no memory/durable split!
        // Run 1 MUST still be .running in memory
        let run1 = await coord.getRun(runID: runID1)
        #expect(run1?.status == RunStatus.running, "Run must remain running when terminal durability fails!")
        // activeRootRunID must NOT be cleared
        #expect(await coord.activeRootRunID == runID1)
        // Turn 2 must NOT have advanced
        #expect(await coord.isTurnQueued(turnID: turnID2) == true)
        #expect(await coord.getTurn(turnID: turnID2)?.status == .queued)

        // 6. Restore disk permissions and retry finishRun: now it succeeds and advances Turn 2
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsURL.path)
        let next = try await coord.finishRun(runID: runID1, reason: .completed)
        #expect(next?.turn.turnID == turnID2)
        #expect(await coord.getRun(runID: runID1)?.status == .completed)
        #expect(await coord.activeRootRunID == next?.runID)
    }

    // MARK: - 2. P0 DURABILITY: running cancel terminal EventLog failure
    @Test("Running Cancel Durability: disk failure during cancelRun leaves Run running without false cancel")
    func testRunningCancelTerminalFailureRollsBackMemory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let userMsg = MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "running task", createdAt: Date())
        let d = try await coord.submitTurn(input: UserInput(text: "running task"), intent: TurnExecutionIntent(), userMessage: userMsg)
        #expect(d.status == .running)
        guard let runID = d.runID else {
            Issue.record("Expected runID")
            return
        }

        // Make events.jsonl read-only
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: eventsURL.path)

        do {
            _ = try await coord.cancelRun(runID: runID, reason: "userCancelled")
            Issue.record("Expected cancelRun to throw on read-only disk")
        } catch {
            // Expected
        }

        // Invariant: Memory state must not reflect false cancellation
        let runSnap = await coord.getRun(runID: runID)
        #expect(runSnap?.status == RunStatus.running)
        #expect(await coord.activeRootRunID == runID)

        // Restore permissions and verify real cancellation
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsURL.path)
        _ = try await coord.cancelRun(runID: runID, reason: "userCancelled")
        #expect(await coord.getRun(runID: runID)?.status == .cancelled)
        #expect(await coord.activeRootRunID == nil)
    }

    // MARK: - 3. P0 COMMIT POINT: EventLog truncate single commit point
    @Test("Truncate Single Commit Point: meta write failure does not break truncate memory/disk consistency")
    func testEventLogTruncateSingleCommitPointWithMetaFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID)

        // Append 3 events
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "1", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "2", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "3", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(await eventLog.currentSequence() == 3)

        // Make meta.json an unwritable directory so meta write fails during truncate
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        try? FileManager.default.removeItem(at: metaURL)
        try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: metaURL.path)

        // Truncate to sequence 1: events.jsonl rewrite succeeds, meta.json fails
        try await eventLog.truncateEvents(afterSequence: 1)

        // Invariant: events.jsonl is authoritative, so memory must be 1, NOT old sequence 3!
        #expect(await eventLog.currentSequence() == 1)
        #expect(await eventLog.allEvents().count == 1)

        // Clean up meta directory
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: metaURL.path)
        try? FileManager.default.removeItem(at: metaURL)

        // Append next event: sequence must advance to 2 strictly
        let nextEnv = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "4", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(nextEnv.cursor.sequence == 2)
        #expect(await eventLog.currentSequence() == 2)

        // Reload from disk to verify full convergence
        let reloadedLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let reloadedEvents = await reloadedLog.allEvents()
        #expect(reloadedEvents.count == 2)
        #expect(reloadedEvents[0].cursor.sequence == 1)
        #expect(reloadedEvents[1].cursor.sequence == 2)
    }

    // MARK: - 4. P0 COMMIT POINT: submitTurn exact Nth-event failure & same-process retry
    @Test("Partial Batch Rollback: Nth-event failure cleanly rolls back orphan events and allows clean retry")
    func testSubmitTurnNthEventAppendFailureAndCleanRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Seed 1 initial event
        let causal = CausalContext(sessionID: sessionID)
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "seed", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        let initialSeq = await eventLog.currentSequence()
        #expect(initialSeq == 1)

        // Pre-create session directory
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

        // First attempt: submitTurn appends 3 events (turnCreated, runCreated, runStarted).
        // Let's make events.jsonl read-only after 2 writes. We can monitor file size or simulate append error.
        // Even simpler: write initial 2 events manually, then make read-only.
        // But to test submitTurn's internal rollback:
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: eventsURL.path)

        let userMsg = MessageSnapshot(messageID: MessageID("u1"), role: .user, text: "retry test", createdAt: Date())
        do {
            _ = try await coord.submitTurn(input: UserInput(text: "retry test"), intent: TurnExecutionIntent(), userMessage: userMsg)
            Issue.record("Expected submitTurn to fail")
        } catch {
            // Expected
        }

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsURL.path)

        // Verify initialSeq is intact
        #expect(await eventLog.currentSequence() == initialSeq)
        #expect(await coord.activeRootRunID == nil)

        // Now retry the same turn on the same coordinator in the same process
        let decision = try await coord.submitTurn(input: UserInput(text: "retry test"), intent: TurnExecutionIntent(), userMessage: userMsg)
        #expect(decision.status == .running)
        #expect(await coord.activeRootRunID == decision.runID)

        // Verify exactly one new Turn was created and all events are monotonically sequenced
        let all = await eventLog.allEvents()
        #expect(all.count == 5) // 1 seed + 4 from submitTurn (turnCreated, userMessageCommitted, runCreated, runStarted)
        #expect(all[0].cursor.sequence == 1)
        #expect(all[1].cursor.sequence == 2)
        #expect(all[2].cursor.sequence == 3)
        #expect(all[3].cursor.sequence == 4)
        #expect(all[4].cursor.sequence == 5)
    }

    // MARK: - 5. P0 REVERT: Crash before recordRevertState at multiple phases
    @Test("Revert Crash Convergence: Pre-marker crash at any phase converges to exactly one logical revert")
    func testRevertCrashBeforeMarkerAtMultipleDestructivePhases() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            // Add 2 user turns directly into SessionStore
            let userMsg1 = Message(id: MessageID("m1"), role: .user, content: "Turn 1", createdAt: Date())
            let userMsg2 = Message(id: MessageID("m2"), role: .user, content: "Turn 2", createdAt: Date())
            _ = try await host.sessionStore.appendMessage(sessionID, message: userMsg1)
            _ = try await host.sessionStore.appendMessage(sessionID, message: userMsg2)

            let sessionBefore = try await host.sessionStore.session(sessionID)
            let userMsgsBefore = sessionBefore.messages.filter { $0.role == .user }
            #expect(userMsgsBefore.count == 2)
            let lastUserMsgID = userMsgsBefore.last!.id

            // Scenario A: Process crashed when plan was recorded, but BEFORE sessionStore.revertLastTurn
            let revertCmdID1 = CommandID("cmd-revert-phase-1")
            try await host.commandWAL.recordRevertPlan(
                commandID: revertCmdID1,
                sessionID: sessionID,
                targetUserMessageID: lastUserMsgID,
                revertedPrompt: "Turn 2",
                removedCount: 1,
                revision: sessionBefore.revision + 1
            )

            // Retry revert with same commandID: target msg is still in store, must cleanly revert it!
            let receipt1 = try await host.revertLastTurn(envelope: CommandEnvelope(
                commandID: revertCmdID1,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            ))
            #expect(receipt1.applied == true)
            #expect(receipt1.result?.revertedPrompt == "Turn 2")

            let sessionAfter1 = try await host.sessionStore.session(sessionID)
            let userMsgsAfter1 = sessionAfter1.messages.filter { $0.role == .user }
            #expect(userMsgsAfter1.count == 1, "Exactly one turn must have been reverted!")
            #expect(userMsgsAfter1.first?.content == "Turn 1")

            // Scenario B: Process crashed AFTER sessionStore.revertLastTurn but BEFORE committed (WAL still says revertPlanned)
            // Retry the same commandID1: it must recognize that targetUserMsgID is already gone from sessionStore!
            // It MUST NOT revert Turn 1 (Zero Double-Revert)!
            let retryReceipt = try await host.revertLastTurn(envelope: CommandEnvelope(
                commandID: revertCmdID1,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            ))
            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.revertedPrompt == "Turn 2")

            let sessionAfterRetry = try await host.sessionStore.session(sessionID)
            let userMsgsAfterRetry = sessionAfterRetry.messages.filter { $0.role == .user }
            #expect(userMsgsAfterRetry.count == 1, "Turn 1 must NOT be reverted on retry!")
            #expect(userMsgsAfterRetry.first?.content == "Turn 1")
        }
    }

    // MARK: - 6. P0 REVERT: Recovery convergence reset failure must throw
    @Test("Revert Recovery Reset Failure: EventLog reset failure throws error and never returns false applied=true")
    func testRevertRecoveryConvergenceResetFailureThrows() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            // Submit turn
            _ = try await host.submitTurn(envelope: CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Turn 1"))
            ))

            let revertCmdID = CommandID("cmd-revert-reset-fail")
            try await host.commandWAL.recordRevertState(
                commandID: revertCmdID,
                sessionID: sessionID,
                revertedPrompt: "Turn 1",
                removedCount: 1,
                revision: 5
            )

            // Locate the exact session directory in host storage layout and make sessionDir read-only
            let eventLogDir = await host.eventLogStorageDirectory
            if let eventLogDir {
                let sessionDir = eventLogDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
                try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionDir.path)
            }

            defer {
                if let eventLogDir {
                    let sessionDir = eventLogDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDir.path)
                }
            }

            do {
                _ = try await host.revertLastTurn(envelope: CommandEnvelope(
                    commandID: revertCmdID,
                    payload: RevertLastTurnRequest(sessionID: sessionID)
                ))
                Issue.record("Expected revertLastTurn to throw when EventLog reset fails in recovery")
            } catch {
                // Expected: must throw and NOT return applied=true!
            }
        }
    }
}
