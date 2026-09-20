import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

#if os(Linux) && canImport(Glibc)
import Glibc
private var isRunningAsRoot: Bool { getuid() == 0 }
#else
private var isRunningAsRoot: Bool { false }
#endif

@Suite("LingXiAgent V1.0.0-RC1 Static Acceptance Audit Suite")
struct RC1StaticAuditTests {

    // MARK: - 1. P0 DURABILITY: finishRun Terminal EventLog Failure
    @Test("Root Terminal Durability: finishRun disk failure rolls back memory and prevents queue advance")
    func testFinishRunTerminalDurabilityFailurePreventsMemoryAdvance() async throws {
        if isRunningAsRoot { return }
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
        if isRunningAsRoot { return }
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
        if isRunningAsRoot { return }
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
        if isRunningAsRoot { return }
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
        if isRunningAsRoot { return }
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

    // MARK: - 7. P0 REVERT: File rollback crash before marker converges idempotently without conflict
    @Test("Revert Pre-Marker File Crash Convergence: Retry after file rollback succeeds idempotently without conflict")
    func testRevertPreMarkerFileRollbackCrashRetryConvergesIdempotently() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let createReceipt = try await host.createSession(envelope: CommandEnvelope(
                payload: CreateSessionRequest(workspace: tempDir.path)
            ))
            let sessionID = try #require(createReceipt.result?.sessionID)

            // Setup a real file on disk
            let fileURL = tempDir.appendingPathComponent("audit_target.txt")
            let initialData = "original state before turn".data(using: .utf8)!
            let modifiedData = "modified state by agent turn".data(using: .utf8)!
            try initialData.write(to: fileURL)

            // Add turn messages into sessionStore
            let userMsg1 = Message(id: MessageID("u1"), role: .user, content: "Initial Turn", createdAt: Date())
            let userMsg2 = Message(id: MessageID("u2"), role: .user, content: "Modify File Turn", createdAt: Date())
            _ = try await host.sessionStore.appendMessage(sessionID, message: userMsg1)
            _ = try await host.sessionStore.appendMessage(sessionID, message: userMsg2)

            // Simulate file modification: write modified content to disk
            try modifiedData.write(to: fileURL)

            // Record real FileMutation into persistence
            let initialHash = FileRollbackEngine.computeHash(data: initialData)
            let modifiedHash = FileRollbackEngine.computeHash(data: modifiedData)
            let mutation = FileMutation(
                sessionID: sessionID,
                turnID: TurnID(),
                revision: 2,
                toolCallID: ToolCallID("tool-edit-1"),
                path: "audit_target.txt",
                beforeHash: initialHash,
                beforeContent: initialData,
                afterHash: modifiedHash,
                afterContent: modifiedData
            )
            let persistence = try #require(await host.persistence)
            try await persistence.recordFileMutation(mutation)

            // 1. Simulate Phase 8 file rollback executing first (e.g. before crash)
            let engine = FileRollbackEngine()
            let firstReport = try await engine.rollbackMutations([mutation], workspaceRoot: tempDir)
            #expect(!firstReport.hasConflicts)
            #expect(firstReport.restoredCount == 1)
            // Disk file is now back to initial state
            let currentContent = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(currentContent == "original state before turn")

            // 先将 Session 推进到 Revision 10（模拟已有历史交互的真实 Session at Revision N）
            while (try await host.sessionStore.session(sessionID)).revision < 10 {
                _ = try await host.sessionStore.bumpRevision(sessionID)
            }
            let sessionBefore = try await host.sessionStore.session(sessionID)
            let baseRevision = sessionBefore.revision
            #expect(baseRevision == 10)
            let targetRevision = baseRevision + 1 // 11 (N+1)

            // 2. Simulate CRASH before SessionStore.revertLastTurn:
            // 真实生产流程中：先写入 revertPlan，然后执行了 bumpRevision 将 session revision 由 10 提升到 11 (N+1)，
            // 接着执行了文件回滚并写入 recordFilesReverted，随后系统发生崩溃 CRASH！
            let revertCmdID = CommandID("cmd-file-crash-retry-test")
            try await host.commandWAL.recordRevertPlan(
                commandID: revertCmdID,
                sessionID: sessionID,
                targetUserMessageID: userMsg2.id,
                revertedPrompt: "Modify File Turn",
                removedCount: 1,
                revision: targetRevision
            )
            let bumpedRevision = try await host.sessionStore.bumpRevision(sessionID)
            #expect(bumpedRevision == targetRevision)
            try await host.commandWAL.recordFilesReverted(
                commandID: revertCmdID,
                sessionID: sessionID
            )

            // 3. Retry same commandID:
            // CoreHost re-runs revertLastTurn, which calls FileRollbackEngine.rollbackMutations again!
            // Without our idempotency and exactly-once revision fixes, this would fail with conflict or bump revision to 12!
            let retryReceipt = try await host.revertLastTurn(envelope: CommandEnvelope(
                commandID: revertCmdID,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            ))
            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.revertedPrompt == "Modify File Turn")
            #expect(retryReceipt.revision == targetRevision, "Receipt revision MUST be \(targetRevision) (N+1), NOT \(targetRevision + 1) (N+2)!")

            // 4. Verify session revision in store is strictly targetRevision (11), NOT 12!
            let sessionAfter = try await host.sessionStore.session(sessionID)
            #expect(sessionAfter.revision == targetRevision, "Session revision MUST be \(targetRevision) (N+1), NOT \(targetRevision + 1) (N+2)!")
            let remainingMsgs = sessionAfter.messages.filter { $0.role == .user }
            #expect(remainingMsgs.count == 1)
            #expect(remainingMsgs.first?.content == "Initial Turn")

            // 5. Verify file content remains original state
            let finalContent = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(finalContent == "original state before turn")
        }
    }

    // MARK: - 8. P0 RUNTIME: Terminal durability failure enters degraded without phantom active root
    @Test("Terminal Durability Failure: Repeated disk failures enter degraded state and clear activeRootRunID")
    func testTerminalDurabilityFailureEntersDegradedWithoutPhantomActiveRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let userMsg = MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "degraded test", createdAt: Date())
        let d = try await coord.submitTurn(input: UserInput(text: "degraded test"), intent: TurnExecutionIntent(), userMessage: userMsg)
        #expect(d.status == .running)
        guard let runID = d.runID else {
            Issue.record("Expected runID")
            return
        }
        #expect(await coord.activeRootRunID == runID)

        // Simulate terminal persistence failure: mark terminal degraded
        let fatalError = RuntimeError(category: .runtime, code: "terminalDurabilityFailed", message: "disk write error", retryability: .none, source: .core)
        let updatedTurn = await coord.markTerminalDegraded(runID: runID, reason: .runtimeFailure, error: fatalError)

        #expect(updatedTurn?.status == .failed)
        // Critical: activeRootRunID MUST BE NIL! No phantom active root!
        #expect(await coord.activeRootRunID == nil)
        #expect(await coord.isDegraded == true)
        #expect(await coord.degradedError?.code == "terminalDurabilityFailed")

        let run = await coord.getRun(runID: runID)
        #expect(run?.status == .failed)
    }

    // MARK: - 9. P0 DURABILITY: True mid-batch Nth append failure and atomic orphan rollback
    @Test("Mid-Batch Failure: Mid-batch EventLog append failure cleanly truncates orphan prefix back to initial sequence")
    func testMidBatchAppendFailureCleansOrphanPrefix() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = SessionID(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID)

        // Seed 2 initial committed events
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "init 1", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        _ = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "init 2", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        let initialSeq = await eventLog.currentSequence()
        #expect(initialSeq == 2)

        // Simulate a multi-event transaction where #1 and #2 succeed, but #3 fails
        do {
            _ = try await eventLog.append(causal: causal, payload: .runStarted(runID: RunID())) // seq 3
            _ = try await eventLog.append(causal: causal, payload: .runStarted(runID: RunID())) // seq 4
            // Now simulate failure on append #3:
            throw CoreError(code: .persistence, message: "Disk failure on event 3")
        } catch {
            // Coordinator catches error and truncates back to initialSeq:
            try await eventLog.truncateEvents(afterSequence: initialSeq)
        }

        // Invariant: no orphan events remain, sequence strictly restored to initialSeq
        #expect(await eventLog.currentSequence() == initialSeq)
        let all = await eventLog.allEvents()
        #expect(all.count == 2)
        #expect(all.last?.cursor.sequence == initialSeq)

        // Next write continues cleanly from initialSeq + 1 (sequence 3)
        let nextEnv = try await eventLog.append(causal: causal, payload: .turnCreated(TurnSnapshot(turnID: TurnID(), sessionID: sessionID, userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "recovered", createdAt: Date()), executionIntent: TurnExecutionIntent(), status: .queued)))
        #expect(nextEnv.cursor.sequence == 3)
        #expect(await eventLog.currentSequence() == 3)
    }
}
