import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

#if os(Windows)
private var isRunningAsRoot: Bool { true }
#elseif os(Linux) && canImport(Glibc)
import Glibc
private var isRunningAsRoot: Bool { getuid() == 0 }
#else
private var isRunningAsRoot: Bool { false }
#endif

@Suite("Round 20 System Audit: Durable Lifecycle, Single Commit Point & Revert Convergence")
struct Round20SystemAuditTests {

    // MARK: - 1. P0-B: EventLog Single Commit Point Invariant
    @Test("Single Commit Point: meta failure after events.jsonl durability advances sequence without duplicate cursor collision")
    func testSingleCommitPointPreventsDuplicateSequenceOnMetaFailure() async throws {
        if isRunningAsRoot { return }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID)

        // 1. Append first event normally
        let env1 = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "msg1", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(env1.cursor.sequence == 1)
        #expect(await eventLog.currentSequence() == 1)

        // 2. Make meta.json a non-writable directory so meta writing fails while events.jsonl succeeds
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        try? FileManager.default.removeItem(at: metaURL)
        try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
        // Make it read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: metaURL.path)

        // 3. Append second event: events.jsonl succeeds, meta.json fails
        let env2 = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "msg2", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(env2.cursor.sequence == 2)
        #expect(await eventLog.currentSequence() == 2)

        // Restore meta permissions for cleanup
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: metaURL.path)
        try? FileManager.default.removeItem(at: metaURL)

        // 4. Append third event: sequence MUST be 3, NEVER duplicate cursor collision at 2!
        let env3 = try await eventLog.append(causal: causal, payload: .turnCompleted(turnID: TurnID(), terminalReason: .completed))
        #expect(env3.cursor.sequence == 3)
        #expect(await eventLog.currentSequence() == 3)

        // 5. Verify all events in events.jsonl have strictly monotonic sequences
        let reloadedLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let reloadedEvents = await reloadedLog.allEvents()
        #expect(reloadedEvents.count == 3)
        #expect(reloadedEvents[0].cursor.sequence == 1)
        #expect(reloadedEvents[1].cursor.sequence == 2)
        #expect(reloadedEvents[2].cursor.sequence == 3)
    }

    // MARK: - 2. P0-B: Coordinator Atomic Batch Rollback on Mid-Append Failure
    @Test("Partial Batch Rollback: Mid-batch failure cleanly truncates eventlog to initial sequence without orphan events")
    func testCoordinatorPartialBatchRollbackOnFailure() async throws {
        if isRunningAsRoot { return }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID)

        // Seed initial event
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "seed", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        let initialSeq = await eventLog.currentSequence()
        #expect(initialSeq == 1)

        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // Make events.jsonl read-only right before submitTurn to cause append failure
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: eventsURL.path)

        let userMsg = MessageSnapshot(messageID: MessageID(), role: .user, text: "hello", createdAt: Date())
        do {
            _ = try await coord.submitTurn(input: UserInput(text: "hello"), intent: TurnExecutionIntent(), userMessage: userMsg)
            Issue.record("Expected submitTurn to throw due to read-only disk")
        } catch {
            // Expected
        }

        // Restore write permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsURL.path)

        // Verify coordinator and eventLog frontier remained strictly at initialSeq without partial orphan events
        #expect(await eventLog.currentSequence() == initialSeq)
        #expect(await coord.activeRootRunID == nil)
        #expect(await coord.getTurn(turnID: TurnID()) == nil)
    }

    // MARK: - 3. P0-A: Queued Turn Cancellation Durability
    @Test("Queue Cancellation Durability: Disk persistence failure reverts cancellation and prevents zombie resurrection")
    func testQueueCancellationDurabilityPreventsZombieTurns() async throws {
        if isRunningAsRoot { return }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // 1. Submit turn 1 (starts execution)
        let userMsg1 = MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "turn 1", createdAt: Date())
        let d1 = try await coord.submitTurn(input: UserInput(text: "turn 1"), intent: TurnExecutionIntent(), userMessage: userMsg1)
        #expect(d1.status == TurnStatus.running)

        // 2. Submit turn 2 (queued)
        let userMsg2 = MessageSnapshot(messageID: MessageID("m2"), role: .user, text: "turn 2", createdAt: Date())
        let d2 = try await coord.submitTurn(input: UserInput(text: "turn 2"), intent: TurnExecutionIntent(), userMessage: userMsg2)
        #expect(d2.status == TurnStatus.queued)
        let turnID2 = d2.turn.turnID
        #expect(await coord.isTurnQueued(turnID: turnID2) == true)

        // 3. Make events.jsonl read-only so cancellation cannot be made durable
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: eventsURL.path)

        // 4. cancelTurn must THROW and rollback memory state
        do {
            try await coord.cancelTurn(turnID: turnID2)
            Issue.record("Expected cancelTurn to throw due to disk failure")
        } catch {
            // Expected
        }

        // 5. Memory state MUST have rolled back: turn 2 is still queued, not falsely claimed cancelled!
        #expect(await coord.isTurnQueued(turnID: turnID2) == true)
        let turn2Snap = await coord.getTurn(turnID: turnID2)
        #expect(turn2Snap?.status == TurnStatus.queued)

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsURL.path)

        // 6. When disk is writable, cancellation succeeds and persists durably
        try await coord.cancelTurn(turnID: turnID2)
        #expect(await coord.isTurnQueued(turnID: turnID2) == false)
        #expect(await coord.getTurn(turnID: turnID2)?.status == TurnStatus.cancelled)
    }

    // MARK: - 4. P0-C: SessionEventLog.resetToEvents Disk-First Durability
    @Test("Reset Durability: resetToEvents throws and preserves memory state if disk write fails")
    func testResetToEventsDurabilityPreservesMemoryOnFailure() async throws {
        if isRunningAsRoot { return }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID)

        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "seed", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(await eventLog.currentSequence() == 1)

        // Make session dir read-only so resetToEvents cannot write to disk
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionDir.path)

        do {
            try await eventLog.resetToEvents([])
            Issue.record("Expected resetToEvents to throw on read-only disk")
        } catch {
            // Expected
        }

        // Memory sequence must not be corrupted to 0 on disk write failure
        #expect(await eventLog.currentSequence() == 1)
        #expect(await eventLog.allEvents().count == 1)

        // Restore permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDir.path)
        try await eventLog.resetToEvents([])
        #expect(await eventLog.currentSequence() == 0)
        #expect(await eventLog.allEvents().isEmpty == true)
    }

    // MARK: - 5. P0-C: Revert Full Crash State Machine Convergence
    @Test("Revert Crash Convergence: lookupRevertedRecord hit completes full coordinator and cache reconciliation")
    func testRevertLookupRevertedRecordCompletesConvergence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            // Submit a turn
            let turnReceipt = try await host.submitTurn(envelope: CommandEnvelope(
                payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Hello Revert"))
            ))
            #expect(turnReceipt.applied == true)

            // Simulate a crashed revert: manually insert a staged reverted record in WAL
            let revertCmdID = CommandID("cmd-revert-crash-test-1")
            try await host.commandWAL.recordRevertState(
                commandID: revertCmdID,
                sessionID: sessionID,
                revertedPrompt: "Hello Revert",
                removedCount: 2,
                revision: 10
            )

            // Execute revertLastTurn with same CommandID: will hit lookupRevertedRecord
            let revertEnvelope = CommandEnvelope(
                commandID: revertCmdID,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            )
            let receipt = try await host.revertLastTurn(envelope: revertEnvelope)
            #expect(receipt.applied == true)
            #expect(receipt.result?.revertedPrompt == "Hello Revert")
            #expect(receipt.result?.removedCount == 2)
            #expect(receipt.result?.snapshot != nil, "Reconciled snapshot must not be nil!")

            // Verify coordinator is completely clean after convergence
            let coord = try await host.coordinator(for: sessionID)
            #expect(await coord.activeRootRunID == nil)
        }
    }
}
