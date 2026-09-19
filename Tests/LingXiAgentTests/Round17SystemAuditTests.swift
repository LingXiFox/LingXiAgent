import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 17 System Audit: Durable Truth Protocol, WAL Atomicity & Crash Resistance")
struct Round17SystemAuditTests {

    // MARK: - 1. P0-D: Committed Receipt + Stale WAL Invariant
    @Test("Committed Invariant: Stale WAL with existing committed receipt is never rolled back")
    func testCommittedReceiptWithStaleWALNeverRolledBack() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wal = DurableCommandWAL(storageDirectory: tempDir)
        let sessionStore = InMemorySessionStore()

        let cmdID = CommandID("cmd-committed-test-1")
        let sessionID = SessionID("session-committed-preserve")

        // 1. Pre-create the session in sessionStore
        _ = try await sessionStore.create(id: sessionID)

        // 2. Commit transaction (writes committed_tx/<cmd>.json)
        let summary = SessionSummary(
            sessionID: sessionID,
            title: "Durable Session",
            createdAt: Date(),
            updatedAt: Date(),
            turnCount: 0,
            mode: .build,
            reasoningEffort: .auto
        )
        let receipt = CommandReceipt<SessionSummary>(
            commandID: cmdID,
            applied: true,
            revision: 1,
            observedThrough: [],
            result: summary
        )
        try await wal.commitTransaction(
            commandID: cmdID,
            commandName: "createSession",
            payloadFingerprint: "fp_test_123",
            receipt: receipt
        )

        // 3. Inject a stale .wal file with the same commandID (simulating failure to delete .wal due to crash or file lock)
        let walDir = tempDir.appendingPathComponent("wal", isDirectory: true)
        let safeKey = CommandStorageSecurity.safeStorageKey(for: cmdID)
        let staleWALURL = walDir.appendingPathComponent("\(safeKey).wal")
        let staleRecord = StagedWALRecord(
            commandID: cmdID.rawValue,
            commandName: "createSession",
            stage: "staged",
            createdSessionID: sessionID.rawValue
        )
        let walData = try JSONEncoder().encode(staleRecord)
        try walData.write(to: staleWALURL, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: staleWALURL.path))

        // 4. Run crash recovery
        let runtimeEventLog = RuntimeEventLog(storageDirectory: tempDir)
        await wal.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { sid in
                let eventLog = SessionEventLog(sessionID: sid, storageDirectory: tempDir)
                return SessionTurnCoordinator(sessionID: sid, eventLog: eventLog)
            }
        )

        // 5. Invariant Check:
        // - The session MUST NOT be rolled back or deleted because receipt proves it was committed!
        let preservedSession = try await sessionStore.session(sessionID)
        #expect(preservedSession.id == sessionID, "Committed session was wrongfully rolled back by stale WAL!")

        // - The stale WAL file MUST be safely cleaned up!
        #expect(!FileManager.default.fileExists(atPath: staleWALURL.path), "Stale WAL file was not cleaned up after recovery!")
    }

    // MARK: - 2. P0-A: Write-Ahead Session Creation Crash Recovery
    @Test("Write-Ahead Invariant: Session created before crash is precisely purged during WAL recovery")
    func testWriteAheadSessionCreationCrashRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wal = DurableCommandWAL(storageDirectory: tempDir)
        let sessionStore = InMemorySessionStore()

        let cmdID = CommandID("cmd-crash-create-session")
        let orphanSessionID = SessionID("session-orphan-to-purge")

        // 1. Write-Ahead: WAL records createdSessionID BEFORE transaction commits
        try await wal.beginTransaction(
            commandID: cmdID,
            commandName: "createSession",
            createdSessionID: orphanSessionID.rawValue
        )

        // 2. Mutation occurred in sessionStore
        _ = try await sessionStore.create(id: orphanSessionID)
        #expect((try? await sessionStore.session(orphanSessionID)) != nil)

        // 3. System crashes here before commitTransaction occurs
        // 4. Restart & Recovery
        let runtimeEventLog = RuntimeEventLog(storageDirectory: tempDir)
        await wal.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { sid in
                let eventLog = SessionEventLog(sessionID: sid, storageDirectory: tempDir)
                return SessionTurnCoordinator(sessionID: sid, eventLog: eventLog)
            }
        )

        // 5. Invariant Check: Orphan session was cleaned up
        let sessionExists = (try? await sessionStore.session(orphanSessionID)) != nil
        #expect(!sessionExists, "Orphan session survived crash recovery despite uncommitted WAL!")
    }

    // MARK: - 3. P0-B: Running Turn Crash Purges Staged User Message (Orphan Prompt Elimination)
    @Test("Turn Atomicity: Interrupted running turn purges staged user prompt from sessionStore")
    func testRunningTurnCrashRemovesStagedUserMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wal = DurableCommandWAL(storageDirectory: tempDir)
        let sessionStore = InMemorySessionStore()

        let sessionID = SessionID("session-turn-purge-prompt")
        _ = try await sessionStore.create(id: sessionID)

        let cmdID = CommandID("cmd-turn-crash")
        let stagedPromptID = MessageID("msg-prompt-crashed-1")

        // 1. Append user prompt to sessionStore (as running turn does)
        let userMessage = Message(
            id: stagedPromptID,
            role: .user,
            content: "Why did the fox cross the cyber road?",
            createdAt: Date()
        )
        _ = try await sessionStore.appendMessage(sessionID, message: userMessage)

        let storeBefore = try await sessionStore.session(sessionID)
        #expect(storeBefore.messages.contains(where: { $0.id == stagedPromptID }))

        // 2. WAL staged record contains stagedUserMessageID
        try await wal.beginTransaction(
            commandID: cmdID,
            commandName: "submitTurn",
            sessionID: sessionID.rawValue
        )
        try await wal.recordState(
            commandID: cmdID,
            sessionID: sessionID,
            stagedUserMessageID: stagedPromptID,
            turnID: TurnID("turn-crashed-1"),
            runID: RunID("run-crashed-1")
        )

        // 3. Crash before commit! (Uncommitted transaction)
        let runtimeEventLog = RuntimeEventLog(storageDirectory: tempDir)
        await wal.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { sid in
                let eventLog = SessionEventLog(sessionID: sid, storageDirectory: tempDir)
                return SessionTurnCoordinator(sessionID: sid, eventLog: eventLog)
            }
        )

        // 4. Invariant Check: The staged user prompt was purged from sessionStore
        let storeAfter = try await sessionStore.session(sessionID)
        let promptLeaked = storeAfter.messages.contains(where: { $0.id == stagedPromptID })
        #expect(!promptLeaked, "Orphan prompt leaked in sessionStore after crash recovery!")
    }

    // MARK: - 4. P0-C: EventLog Single Source of Truth Calibration
    @Test("Single Source of Truth: EventLog reconciles sequence from disk events, healing meta split-brain")
    func testEventLogSingleSourceOfTruthCalibration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("session-eventlog-truth")
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let genID = EventLogGenerationID("gen-truth-1")

        // 1. Manually write 3 real events into events.jsonl
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        var fileContent = ""
        for seq in 1...3 {
            let cursor = EventCursor(generationID: genID, sequence: UInt64(seq))
            let envelope = SessionEventEnvelope(
                cursor: cursor,
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .runStarted(runID: RunID("run-\(seq)"))
            )
            let envData = try JSONEncoder().encode(envelope)
            let line = String(decoding: envData, as: UTF8.self)
            fileContent += line + "\n"
        }
        try Data(fileContent.utf8).write(to: eventsURL)

        // 2. Simulate split-brain: meta.json contains incorrect sequence (e.g., 999 due to partial write)
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        let corruptMetaJSON = "{\"generationID\":\"\(genID.rawValue)\",\"sequence\":999}"
        try Data(corruptMetaJSON.utf8).write(to: metaURL)

        // 3. Initialize SessionEventLog - must calibrate sequence from events.jsonl tail
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let calibratedSeq = await eventLog.currentSequence()

        // 4. Invariant Checks:
        // - Sequence must be 3 (the exact tail cursor of events.jsonl), NOT 999!
        #expect(calibratedSeq == 3, "EventLog did not calibrate sequence to events.jsonl tail: got \(calibratedSeq)")

        // - meta.json on disk must be self-healed to sequence 3
        let healedMetaData = try Data(contentsOf: metaURL)
        let healedMetaStr = String(decoding: healedMetaData, as: UTF8.self)
        #expect(healedMetaStr.contains("\"sequence\":3"), "meta.json was not self-healed on disk!")

        // - Next append must produce sequence 4 without duplicate or gap
        await eventLog.append(
            causal: CausalContext(sessionID: sessionID),
            payload: .runCompleted(runID: RunID("run-4"), terminalReason: .completed)
        )
        let nextSeq = await eventLog.currentSequence()
        #expect(nextSeq == 4, "Next append produced incorrect sequence: expected 4, got \(nextSeq)")
    }

    // MARK: - 5. Live Process Failure Compensation
    @Test("Live Compensation: Mid-transaction failure cleanly compensates without orphan state")
    func testLiveProcessFailureCompensatesCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            // Set failpoint: fail immediately after mutation before event append
            await host.setCommitFailpoint(.afterStateMutationBeforeEventAppend)

            // Attempt to create session - must fail
            do {
                _ = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
                Issue.record("Expected createSession to throw error due to injected failpoint")
            } catch {
                // Expected failure
            }

            // Invariant Check: Live process compensation caught the failure and deleted the session
            let sessions = try await host.sessionStore.listSessions()
            #expect(sessions.isEmpty, "Orphan session remained in sessionStore after live-process failure compensation!")
        }
    }

    // MARK: - 6. P0-F: Recovery Authority Uniform Failed Status
    @Test("Recovery Authority: Interrupted non-terminal runs uniformly restore to terminal .failed")
    func testRecoveryAuthorityUniformFailedStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-recovery-authority")
        let turnID = TurnID("turn-unsettled")
        let runID = RunID("run-unsettled")

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID)

        let turnSnap = TurnSnapshot(
            turnID: turnID,
            sessionID: sessionID,
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Unsettled prompt", attachments: [], createdAt: Date()),
            executionIntent: TurnExecutionIntent(),
            status: .running,
            rootRunID: runID,
            createdAt: Date()
        )
        let runSnap = RunSnapshot(
            runID: runID,
            sessionID: sessionID,
            turnID: turnID,
            rootRunID: runID,
            status: .running,
            model: "test-model",
            createdAt: Date(),
            completedAt: nil,
            terminalReason: nil
        )
        await eventLog.append(causal: causal, payload: .turnCreated(turnSnap))
        await eventLog.append(causal: causal, payload: .runCreated(runSnap))
        await eventLog.append(causal: causal, payload: .runStarted(runID: runID))

        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
        await coord.restoreHistoricalQueue()

        let restoredRun = try #require(await coord.getRun(runID: runID))
        #expect(restoredRun.status == .failed)
        #expect(restoredRun.terminalReason == .runtimeFailure)
    }
}
