import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 18 System Audit: Commit Boundary, EventLog Durability & Real CoreHost Recovery")
struct Round18SystemAuditTests {

    // MARK: - 1. P0-A: Commit Boundary — createSession
    @Test("Commit Boundary: createSession post-commit failure NEVER deletes committed session")
    func testCreateSessionPostCommitFailurePreservesSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let cmdID = CommandID("cmd-post-commit-create-1")
            let envelope = CommandEnvelope(
                commandID: cmdID,
                payload: CreateSessionRequest(workspace: tempDir.path)
            )

            // 1. Inject failpoint after durable commit before response
            await host.setCommitFailpoint(.afterCommitBeforeResponse)

            // 2. Call must throw error representing post-commit delivery failure
            do {
                _ = try await host.createSession(envelope: envelope)
                Issue.record("Expected createSession to throw due to afterCommitBeforeResponse failpoint")
            } catch let err as RuntimeError {
                #expect(err.code == "injectedCrashAfterCommitBeforeResponse")
            }

            // 3. Commit Boundary Invariant:
            // - The session MUST STILL EXIST in sessionStore! It must NOT have been deleted by catch-block compensation!
            let sessionsAfterFail = try await host.sessionStore.listSessions()
            #expect(sessionsAfterFail.count == 1, "Committed session was wrongfully deleted by post-commit catch block!")
            let committedSessionID = sessionsAfterFail.first?.id

            // 4. Client retry with SAME CommandID:
            // - Must hit idempotency / committed receipt and return the SAME session cleanly!
            await host.setCommitFailpoint(nil)
            let retryReceipt = try await host.createSession(envelope: envelope)
            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.sessionID == committedSessionID)

            // - No duplicate session was created
            let finalSessions = try await host.sessionStore.listSessions()
            #expect(finalSessions.count == 1, "Retry created duplicate session instead of idempotent hit!")
        }
    }

    // MARK: - 2. P0-A: Commit Boundary — submitTurn
    @Test("Commit Boundary: submitTurn post-commit failure NEVER rolls back turn or purges user prompt")
    func testSubmitTurnPostCommitFailurePreservesTurnAndPrompt() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await withTestCoreHost(workspaceRoot: tempDir) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            let cmdID = CommandID("cmd-post-commit-turn-1")
            let turnPrompt = "Durable turn prompt across post-commit failure"
            let turnEnvelope = CommandEnvelope(
                commandID: cmdID,
                payload: SubmitTurnRequest(
                    sessionID: sessionID,
                    input: UserInput(text: turnPrompt),
                    executionIntent: TurnExecutionIntent()
                )
            )

            // 1. Inject failpoint after durable commit before response
            await host.setCommitFailpoint(.afterCommitBeforeResponse)

            // 2. Call throws
            do {
                _ = try await host.submitTurn(envelope: turnEnvelope)
                Issue.record("Expected submitTurn to throw due to afterCommitBeforeResponse failpoint")
            } catch let err as RuntimeError {
                #expect(err.code == "injectedCrashAfterCommitBeforeResponse")
            }

            // 3. Commit Boundary Invariant:
            // - User message MUST STILL EXIST in sessionStore!
            let storeSession = try await host.sessionStore.session(sessionID)
            let promptExists = storeSession.messages.contains(where: { $0.content == turnPrompt })
            #expect(promptExists, "Committed turn prompt was purged from sessionStore by post-commit catch block!")

            // 4. Retry with SAME CommandID:
            // - Must return identical cached receipt without rollback or creating duplicate turns
            await host.setCommitFailpoint(nil)
            let retryReceipt = try await host.submitTurn(envelope: turnEnvelope)
            #expect(retryReceipt.applied == true)
            #expect(retryReceipt.result?.turnID != nil)

            let storeSessionAfterRetry = try await host.sessionStore.session(sessionID)
            let userMessages = storeSessionAfterRetry.messages.filter { $0.role == .user }
            #expect(userMessages.count == 1, "Duplicate user prompt created on idempotent retry!")
        }
    }

    // MARK: - 3. P0-B: Torn Event Tail Auto-Truncation & Isolation
    @Test("Torn Tail: EventLog detects and truncates unclosed partial JSON line at file end")
    func testEventLogDetectsAndTruncatesTornTail() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-torn-tail-test")
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let genID = EventLogGenerationID("gen-torn-1")
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

        // 1. Write 2 valid events
        var validContent = ""
        for seq in 1...2 {
            let cursor = EventCursor(generationID: genID, sequence: UInt64(seq))
            let env = SessionEventEnvelope(
                cursor: cursor,
                timestamp: Date(),
                causal: CausalContext(sessionID: sessionID),
                payload: .runStarted(runID: RunID("run-\(seq)"))
            )
            let data = try JSONEncoder().encode(env)
            validContent += String(decoding: data, as: UTF8.self) + "\n"
        }

        // 2. Simulate SIGKILL crash mid-write: append a partial, unclosed JSON line without trailing newline
        let corruptTail = "{\"cursor\":{\"generationID\":\"\(genID.rawValue)\",\"sequence\":3},\"payload\":{\"run"
        let fullFileContent = validContent + corruptTail
        try Data(fullFileContent.utf8).write(to: eventsURL)

        // 3. Start SessionEventLog: must calibrate to 2 and physically truncate the corrupt tail
        let eventLog1 = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let seq1 = await eventLog1.currentSequence()
        #expect(seq1 == 2, "EventLog failed to calibrate sequence from valid lines: got \(seq1)")

        // Check file on disk: corrupt tail must be gone!
        let truncatedData = try Data(contentsOf: eventsURL)
        let truncatedStr = String(decoding: truncatedData, as: UTF8.self)
        #expect(!truncatedStr.contains(corruptTail), "Torn tail was not truncated from disk!")
        #expect(truncatedStr.hasSuffix("\n"), "File does not end with newline after torn tail truncation!")

        // 4. Append next event: must be cleanly written as sequence 3
        await eventLog1.append(
            causal: CausalContext(sessionID: sessionID),
            payload: .runCompleted(runID: RunID("run-3"), terminalReason: .completed)
        )
        let seq2 = await eventLog1.currentSequence()
        #expect(seq2 == 3)

        // 5. Cold restart: must successfully load all 3 events without decoding errors
        let eventLog2 = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let seqAfterRestart = await eventLog2.currentSequence()
        #expect(seqAfterRestart == 3, "New event appended after torn tail truncation failed to load on cold restart!")
        let allEvents = await eventLog2.allEvents()
        #expect(allEvents.count == 3)
    }

    // MARK: - 4. P0-B: UTF-8 Multi-Byte Torn Tail Resilience
    @Test("Torn Tail: Incomplete UTF-8 code point at EOF does not cause entire eventlog to be lost")
    func testIncompleteUTF8AtEOFDoesNotDropValidEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-utf8-torn-test")
        let sessionDir = tempDir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let genID = EventLogGenerationID("gen-utf8-1")
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

        // 1. Write 1 valid event with Chinese characters
        let cursor = EventCursor(generationID: genID, sequence: 1)
        let env = SessionEventEnvelope(
            cursor: cursor,
            timestamp: Date(),
            causal: CausalContext(sessionID: sessionID),
            payload: .runStarted(runID: RunID("run-valid-中文事件"))
        )
        let data = try JSONEncoder().encode(env)
        var fileBytes = Array(data)
        fileBytes.append(0x0A) // '\n'

        // 2. Append 2 bytes of a 3-byte or 4-byte UTF-8 character (e.g., '狐' is E7 8B 90; append E7 8B only)
        fileBytes.append(0xE7)
        fileBytes.append(0x8B)
        try Data(fileBytes).write(to: eventsURL)

        // 3. Load EventLog
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let seq = await eventLog.currentSequence()

        // Invariant: Sequence must be 1, valid event must be preserved!
        #expect(seq == 1, "Incomplete UTF-8 byte at EOF wiped valid events!")
        let loaded = await eventLog.allEvents()
        #expect(loaded.count == 1)
    }

    // MARK: - 5. P0-D: Real CoreHost WAL Recovery Without Self-Conflict
    @Test("Real CoreHost: Uncommitted createSession recovery cleanly deletes session and clears WAL")
    func testRealCoreHostCreateSessionRecoveryClearsWAL() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = CoreStorageLayout(root: tempDir)
        try layout.ensureDirectoriesExist()

        let walDir = layout.eventLog.appendingPathComponent("wal", isDirectory: true)
        try FileManager.default.createDirectory(at: walDir, withIntermediateDirectories: true)

        let orphanSessionID = SessionID("orphan-session-real-host")
        let cmdID = CommandID("cmd-orphan-create-1")

        // Pre-create the orphan session in persistent DB
        let p = try SQLitePersistenceStore(dataRoot: tempDir, mainRoot: tempDir)
        let binding = try await p.mainRootBinding()
        _ = try await p.createSession(Session(
            id: orphanSessionID,
            createdAt: Date(),
            kind: .primary,
            rootSessionID: orphanSessionID,
            projectID: p.projectID,
            cwdRootBindingID: binding.id
        ))

        // Write an uncommitted staged WAL record (simulating crash before commit)
        let safeKey = CommandStorageSecurity.safeStorageKey(for: cmdID)
        let walFile = walDir.appendingPathComponent("\(safeKey).wal")
        let walRecord = StagedWALRecord(
            commandID: cmdID.rawValue,
            commandName: "createSession",
            stage: "staged",
            createdSessionID: orphanSessionID.rawValue
        )
        try JSONEncoder().encode(walRecord).write(to: walFile, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: walFile.path))

        // Start real CoreHost (triggers real commandWAL.recover with production coordinatorProvider)
        try await withTestCoreHost(workspaceRoot: tempDir, storageLayout: layout) { host in
            // 1. Orphan session must have been deleted from store
            let sessions = try await host.sessionStore.listSessions()
            let orphanFound = sessions.contains(where: { $0.id == orphanSessionID })
            #expect(!orphanFound, "Orphan session was not deleted during real CoreHost recovery!")

            // 2. WAL file must have been cleanly removed without self-conflict error
            #expect(!FileManager.default.fileExists(atPath: walFile.path), "WAL file remained stuck on disk due to coordinatorProvider self-conflict!")
        }
    }

    // MARK: - 6. P0-F: IdempotencyJournal Corruption Quarantine
    @Test("Idempotency: Corrupted journal entry is quarantined and never confused with commandID")
    func testIdempotencyJournalCorruptedFileQuarantined() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let journalDir = tempDir.appendingPathComponent("idempotency", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        // Inject a corrupt/partial journal JSON file named after a SHA-256 hash
        let hashFileName = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2.json"
        let corruptFileURL = journalDir.appendingPathComponent(hashFileName)
        try Data("NOT_A_VALID_JOURNAL_ENTRY_JSON".utf8).write(to: corruptFileURL)

        // Initialize IdempotencyJournal
        let journal = IdempotencyJournal(storageDirectory: tempDir)

        // 1. Quarantined check
        let quarantined = await journal.quarantinedCorruptEntries
        #expect(quarantined.contains(hashFileName))

        // 2. Disk check: file renamed to .corrupt
        let corruptRenamedURL = journalDir.appendingPathComponent("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2.corrupt")
        #expect(FileManager.default.fileExists(atPath: corruptRenamedURL.path))
        #expect(!FileManager.default.fileExists(atPath: corruptFileURL.path))

        // 3. Invariant check: SHA-256 hash was NOT loaded as a valid CommandID in memory
        let fakeCmdID = CommandID("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        let lookup = await journal.lookup(commandID: fakeCmdID, as: SessionSummary.self)
        guard case .notFound = lookup else {
            Issue.record("Corrupted SHA-256 file was mistakenly recognized as a valid legacy CommandID!")
            return
        }
    }
}
