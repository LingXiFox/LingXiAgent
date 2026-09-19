import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 19 System Audit: Execution Ownership, Event Frontier Rollback, and Crash-Safe Revert")
struct Round19SystemAuditTests {

    // MARK: - 1. P0-A: Committed Turn Execution Ownership
    @Test("Execution Ownership: submitTurn post-commit failure retains active execution task and prevents phantom run")
    func testCommittedTurnRetainsExecutionOwnershipOnPostCommitFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            let turnCmdID = CommandID("cmd-turn-exec-ownership-1")
            let turnEnvelope = CommandEnvelope(
                commandID: turnCmdID,
                payload: SubmitTurnRequest(
                    sessionID: sessionID,
                    input: UserInput(text: "Execute with ownership")
                )
            )

            // Inject failure right after durable commit before response
            await host.setCommitFailpoint(.afterCommitBeforeResponse)

            do {
                _ = try await host.submitTurn(envelope: turnEnvelope)
                Issue.record("Expected submitTurn to throw due to afterCommitBeforeResponse")
            } catch let err as RuntimeError {
                #expect(err.code == "injectedCrashAfterCommitBeforeResponse")
            }

            // Invariant 1: Transaction was committed, so turn was NOT rolled back
            let coord = try await host.coordinator(for: sessionID)
            let activeRunID = await coord.activeRootRunID
            #expect(activeRunID != nil, "Active run was erroneously rolled back!")
            let runID = try #require(activeRunID)

            // Invariant 2 (P0-A Core): Execution Task MUST exist!
            // Even though delivery failed with an error, the execution ownership was registered at commit time.
            let hasTaskImmediately = await host.hasActiveTurnTask(runID: runID)
            #expect(hasTaskImmediately, "Phantom active Run detected: committed run has NO active execution task!")

            // Invariant 3: Retry with same CommandID returns idempotent receipt AND ensures execution task remains alive
            await host.setCommitFailpoint(nil)
            let retryReceipt = try await host.submitTurn(envelope: turnEnvelope)
            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.status == .running)
            #expect(await host.hasActiveTurnTask(runID: runID), "Retry failed to preserve active execution task!")
        }
    }

    // MARK: - 2. P0-B: Pre-commit Compensation Full Frontier Rollback
    @Test("Event Frontier Rollback: Pre-commit failure truncates entire event batch back to initial sequence")
    func testPreCommitFailureTruncatesEntireEventBatchToInitialSequence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)
            let coord = try await host.coordinator(for: sessionID)

            let initialSessionSeq = await coord.eventLog.currentSequence()
            let initialEventCount = (await coord.eventLog.allEvents()).count

            // Inject failpoint after event append before receipt record (pre-commit)
            await host.setCommitFailpoint(.afterEventAppendBeforeReceipt)

            let turnCmdID = CommandID("cmd-precommit-fail-event-batch")
            let turnEnvelope = CommandEnvelope(
                commandID: turnCmdID,
                payload: SubmitTurnRequest(
                    sessionID: sessionID,
                    input: UserInput(text: "This turn must be completely rolled back")
                )
            )

            do {
                _ = try await host.submitTurn(envelope: turnEnvelope)
                Issue.record("Expected submitTurn to throw due to afterEventAppendBeforeReceipt")
            } catch let err as RuntimeError {
                #expect(err.code == "injectedCrashAfterEventBeforeReceipt")
            }

            // Invariant 1: Entire event batch must be truncated back to initial sequence!
            let currentSeq = await coord.eventLog.currentSequence()
            #expect(currentSeq == initialSessionSeq, "EventLog sequence leaked orphan events! Expected \(initialSessionSeq), got \(currentSeq)")

            let allEvents = await coord.eventLog.allEvents()
            #expect(allEvents.count == initialEventCount, "EventLog contains orphan events from aborted batch!")

            // Invariant 2: SessionStore user message must not exist
            let session = try await host.sessionStore.session(sessionID)
            #expect(session.messages.isEmpty, "User message was not purged from sessionStore!")

            // Invariant 3: Coordinator state must have zero active runs or queued turns
            #expect(await coord.activeRootRunID == nil, "activeRootRunID was not cleared!")
            #expect(await coord.queuedTurnsSnapshot.isEmpty, "Queued turns were not cleared!")
        }
    }

    // MARK: - 3. P0-C: EventLog Append Persistence Failure-Aware
    @Test("Failure-Aware Persistence: EventLog append throws on disk failure and prevents state advancement")
    func testEventLogAppendDiskFailureRejectsCommandAndPreventsWALEventsAppended() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-disk-failure-test")
        let eventLogDir = tempDir.appendingPathComponent("eventlog-\(sessionID.rawValue)")
        try FileManager.default.createDirectory(at: eventLogDir, withIntermediateDirectories: true)

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: eventLogDir)
        let initialSeq = await eventLog.currentSequence()

        // 1. Normal append succeeds
        try await eventLog.append(
            causal: CausalContext(sessionID: sessionID),
            payload: .runQueued(runID: RunID("r1"))
        )
        let seqAfter1 = await eventLog.currentSequence()
        #expect(seqAfter1 == initialSeq + 1)

        // 2. Set events.jsonl to read-only to trigger I/O failure on next append
        let sessionDir = eventLogDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        let metaFile = sessionDir.appendingPathComponent("meta.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventsFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metaFile.path)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: eventsFile.path)
        if FileManager.default.fileExists(atPath: metaFile.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: metaFile.path)
        }

        // 3. Next append MUST throw an error, NOT silently swallow!
        do {
            try await eventLog.append(
                causal: CausalContext(sessionID: sessionID),
                payload: .runStarted(runID: RunID("r1"))
            )
            Issue.record("Expected append to throw on disk failure, but it succeeded silently!")
        } catch {
            #expect(true, "Append threw error as expected")
        }

        // 4. Memory sequence MUST NOT have incremented on failed disk append!
        let seqAfterFailed = await eventLog.currentSequence()
        #expect(seqAfterFailed == seqAfter1, "Memory sequence advanced despite disk append failure!")

        // 5. Test degraded state directly throws on append
        let degradedLog = SessionEventLog(sessionID: sessionID, isDegraded: true)
        let isDeg = await degradedLog.isDegraded
        #expect(isDeg)
        do {
            try await degradedLog.append(
                causal: CausalContext(sessionID: sessionID),
                payload: .runStarted(runID: RunID("r2"))
            )
            Issue.record("Expected append on degraded log to throw")
        } catch {
            #expect(true)
        }
    }

    // MARK: - 4. P0-D: Revert Crash Consistency & Exactly-Once Logical Revert
    @Test("Revert Crash Consistency: Crash after state mutation does not double-revert on retry")
    func testRevertLastTurnCrashMidwayDoesNotDoubleRevertOnRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = CoreStorageLayout.temporarySandbox()
        try layout.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let revertCmdID = CommandID("cmd-revert-crash-safe-1")

        // 1. Initial run: Create session and add two turns
        let targetSessionID: SessionID = try await withTestCoreHost(workspaceRoot: tempDir, storageLayout: layout) { host -> SessionID in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            // Turn 1
            _ = try await host.sessionStore.appendMessage(sessionID, role: .user, content: "Turn 1 Prompt")
            _ = try await host.sessionStore.appendMessage(sessionID, role: .assistant, content: "Turn 1 Response")

            // Turn 2
            _ = try await host.sessionStore.appendMessage(sessionID, role: .user, content: "Turn 2 Prompt")
            _ = try await host.sessionStore.appendMessage(sessionID, role: .assistant, content: "Turn 2 Response")

            let msgs = try await host.sessionStore.session(sessionID).messages
            #expect(msgs.count == 4, "Setup failed: expected 4 messages")

            // Simulate crash midway during revertLastTurn:
            // The state mutation occurred (Turn 2 removed), and WAL recordRevertState was written,
            // but process crashed before commitTransaction.
            try await host.commandWAL.beginTransaction(commandID: revertCmdID, commandName: "revertLastTurn", sessionID: sessionID.rawValue)
            let (prompt, count) = try await host.sessionStore.revertLastTurn(sessionID, bumpRevision: false)
            #expect(prompt == "Turn 2 Prompt")
            #expect(count == 2)

            try await host.commandWAL.recordRevertState(
                commandID: revertCmdID,
                sessionID: sessionID,
                revertedPrompt: prompt,
                removedCount: count,
                revision: 1
            )
            return sessionID
            // Process exits / crashes here!
        }

        // 2. Cold restart: Start new CoreHost with the same layout
        try await withTestCoreHost(workspaceRoot: tempDir, storageLayout: layout) { host2 in
            // Check session messages immediately after start
            let msgsAfterRestart = try await host2.sessionStore.session(targetSessionID).messages
            #expect(msgsAfterRestart.count == 2, "Expected 2 remaining messages after crash before retry")

            // 3. Client retries with the SAME revert commandID
            let retryEnvelope = CommandEnvelope(
                commandID: revertCmdID,
                payload: RevertLastTurnRequest(sessionID: targetSessionID)
            )
            let retryReceipt = try await host2.revertLastTurn(envelope: retryEnvelope)

            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.removedCount == 2)
            #expect(retryReceipt.result?.revertedPrompt == "Turn 2 Prompt")

            // CRITICAL INVARIANT: Double-revert MUST NOT happen!
            // Messages must STILL be 2 (Turn 1 was NOT removed)!
            let finalMsgs = try await host2.sessionStore.session(targetSessionID).messages
            #expect(finalMsgs.count == 2, "DOUBLE-REVERT DETECTED: Retry deleted Turn 1 messages instead of returning cached revert state!")
            #expect(finalMsgs.first?.content == "Turn 1 Prompt")
        }
    }
}
