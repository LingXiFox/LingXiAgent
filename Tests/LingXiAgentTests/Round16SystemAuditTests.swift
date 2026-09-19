import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 16 System Audit: Durability, Causal Frontier & Release Integrity")
struct Round16SystemAuditTests {

    // MARK: - 1. P0-A: Causal Frontier / Queued Message Leakage Prevention
    @Test("Causal Frontier: Queued turn input is NEVER written to sessionStore until execution lease is acquired")
    func testQueuedTurnMessageNeverLeakedBeforeExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Submit Turn 1 (becomes active running)
            let t1 = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: "Active Turn 1 Prompt"),
                executionIntent: TurnExecutionIntent()
            )))
            #expect(t1.result?.status == .running)

            // Submit Turn 2 while Turn 1 is running (must enter queued state)
            let queuedPrompt = "Queued Turn 2 Prompt (MUST NOT LEAK)"
            let t2 = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(
                sessionID: sessionID,
                input: UserInput(text: queuedPrompt),
                executionIntent: TurnExecutionIntent()
            )))
            #expect(t2.result?.status == .queued)

            // Critical Invariant: Read sessionStore immediately while Turn 1 is still active
            let storeSession = try await host.sessionStore.session(sessionID)
            let messagesInStore = storeSession.messages.map(\.content)

            // Turn 1 prompt is present
            #expect(messagesInStore.contains("Active Turn 1 Prompt"))
            // Turn 2 prompt MUST NOT be in sessionStore while it is queued!
            #expect(!messagesInStore.contains(queuedPrompt), "Queued message leaked to sessionStore ahead of execution schedule!")
        }
    }

    // MARK: - 2. P0-B: Corrupt WAL Quarantining & Diagnostics Visibility
    @Test("Durability Chain: Corrupted WAL files are quarantined and exposed in diagnostics")
    func testCorruptWALQuarantineExposedInDiagnostics() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = CoreStorageLayout(root: tempDir)
        try layout.ensureDirectoriesExist()

        let walDir = layout.eventLog.appendingPathComponent("wal", isDirectory: true)
        try FileManager.default.createDirectory(at: walDir, withIntermediateDirectories: true)

        // Inject a corrupt WAL file (invalid JSON content)
        let corruptFileName = "corrupt_cmd_12345.wal"
        let corruptFileURL = walDir.appendingPathComponent(corruptFileName)
        try Data("NOT_A_VALID_WAL_RECORD_CONTENT".utf8).write(to: corruptFileURL)

        try await withTestCoreHost(workspaceRoot: tempDir, storageLayout: layout) { host in
            // Verify quarantine happened
            let quarantined = await host.commandWAL.quarantinedCorruptWALs
            #expect(quarantined.contains(corruptFileName))

            // Verify the file was renamed to .corrupt on disk
            let quarantinedURL = walDir.appendingPathComponent("corrupt_cmd_12345.corrupt")
            #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
            #expect(!FileManager.default.fileExists(atPath: corruptFileURL.path))

            // Verify diagnostics exposes the quarantine anomaly
            let diagResp = try await host.getDiagnostics(envelope: QueryEnvelope(payload: VoidResult()))
            let summary = diagResp.payload.configurationSummary
            let reportedWALs = summary["quarantinedCorruptWALs"] ?? ""
            #expect(reportedWALs.contains(corruptFileName), "Corrupt WAL anomaly was not surfaced in diagnostics!")
        }
    }

    // MARK: - 3. P0-C: Crash-Durable Idempotency & WAL Fallback Conflict
    @Test("Crash-Durable Idempotency: WAL fallback catches command method and fingerprint conflict")
    func testWALCommittedReceiptIntentConflictOnMissingJournal() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wal = DurableCommandWAL(storageDirectory: tempDir)

        let cmdID = CommandID("tx_test_idempotent_01")
        let receipt = CommandReceipt<SessionSummary>(
            commandID: cmdID,
            applied: true,
            revision: 1,
            observedThrough: [],
            result: SessionSummary(
                sessionID: SessionID("sess-1"),
                title: "Test Session",
                createdAt: Date(),
                updatedAt: Date(),
                turnCount: 0,
                mode: .build
            )
        )

        // Commit transaction with specific method and fingerprint
        try await wal.commitTransaction(
            commandID: cmdID,
            commandName: "createSession",
            payloadFingerprint: "fingerprint_abc",
            receipt: receipt
        )

        // 1. Exact match hit
        let hitResult = await wal.lookupCommittedReceipt(
            commandID: cmdID,
            commandName: "createSession",
            payloadFingerprint: "fingerprint_abc",
            as: SessionSummary.self
        )
        guard case .hit = hitResult else {
            Issue.record("Expected .hit for matching intent, got: \(hitResult)")
            return
        }

        // 2. Command name conflict
        let nameConflict = await wal.lookupCommittedReceipt(
            commandID: cmdID,
            commandName: "renameSession",
            payloadFingerprint: "fingerprint_abc",
            as: SessionSummary.self
        )
        guard case let .conflict(_, _, reason) = nameConflict else {
            Issue.record("Expected .conflict on command name mismatch, got: \(nameConflict)")
            return
        }
        #expect(reason.contains("Command method mismatch"))

        // 3. Payload fingerprint conflict
        let fpConflict = await wal.lookupCommittedReceipt(
            commandID: cmdID,
            commandName: "createSession",
            payloadFingerprint: "fingerprint_xyz_different",
            as: SessionSummary.self
        )
        guard case let .conflict(_, _, reason) = fpConflict else {
            Issue.record("Expected .conflict on fingerprint mismatch, got: \(fpConflict)")
            return
        }
        #expect(reason.contains("Payload fingerprint mismatch"))

        // 4. Return type conflict
        let typeConflict = await wal.lookupCommittedReceipt(
            commandID: cmdID,
            commandName: "createSession",
            payloadFingerprint: "fingerprint_abc",
            as: SubmitTurnResult.self
        )
        guard case .conflict = typeConflict else {
            Issue.record("Expected .conflict on return type mismatch, got: \(typeConflict)")
            return
        }
    }

    // MARK: - 4. P0-C: revertLastTurn Crash-Durable Idempotency
    @Test("Idempotency: Replaying revertLastTurn with same CommandID returns cached receipt without double-revert")
    func testRevertLastTurnCrashDurableIdempotency() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Seed two completed turns directly into sessionStore
            let now = Date()
            _ = try await host.sessionStore.appendMessage(
                sessionID,
                message: Message(id: MessageID(), role: .user, content: "User message 1", createdAt: now)
            )
            _ = try await host.sessionStore.appendMessage(
                sessionID,
                message: Message(id: MessageID(), role: .assistant, content: "Assistant reply 1", createdAt: now)
            )
            _ = try await host.sessionStore.appendMessage(
                sessionID,
                message: Message(id: MessageID(), role: .user, content: "User message 2", createdAt: now)
            )
            _ = try await host.sessionStore.appendMessage(
                sessionID,
                message: Message(id: MessageID(), role: .assistant, content: "Assistant reply 2", createdAt: now)
            )

            let beforeSession = try await host.sessionStore.session(sessionID)
            let userCountBefore = beforeSession.messages.filter { $0.role == .user }.count
            #expect(userCountBefore == 2)

            // Call revertLastTurn with fixed commandID
            let revertCmdID = CommandID("revert-turn-deterministic-id")
            let firstRevertReceipt = try await host.revertLastTurn(envelope: CommandEnvelope(
                commandID: revertCmdID,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            ))
            #expect(firstRevertReceipt.applied == true)
            #expect(firstRevertReceipt.result?.revertedPrompt == "User message 2")

            let midSession = try await host.sessionStore.session(sessionID)
            let userCountMid = midSession.messages.filter { $0.role == .user }.count
            #expect(userCountMid == 1, "Expected 1 remaining user turn after single revert")

            // Crash/Network Retry: Replay exact same command envelope with same commandID
            let retryRevertReceipt = try await host.revertLastTurn(envelope: CommandEnvelope(
                commandID: revertCmdID,
                payload: RevertLastTurnRequest(sessionID: sessionID)
            ))

            // Invariant: Must return identical cached receipt, and MUST NOT revert Turn 1!
            #expect(retryRevertReceipt.applied == true)
            #expect(retryRevertReceipt.result?.revertedPrompt == firstRevertReceipt.result?.revertedPrompt)

            let afterSession = try await host.sessionStore.session(sessionID)
            let userCountAfter = afterSession.messages.filter { $0.role == .user }.count
            #expect(userCountAfter == 1, "Double-revert occurred! Retry stripped an extra turn!")
        }
    }

    // MARK: - 5. P0-D: Recovery Authority & Started-Run Terminal Transition
    @Test("Recovery Authority: Started-but-crashed runs deterministically restore to terminal .failed")
    func testStartedRunInterruptedByCrashBecomesTerminalFailed() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-crash-test")
        let turnID = TurnID("turn-crashed-1")
        let runID = RunID("run-crashed-1")

        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID)

        // Seed events: Turn and Run were created and started, but crash happened before any terminal event
        let turnSnap = TurnSnapshot(
            turnID: turnID,
            sessionID: sessionID,
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Crash prompt", attachments: [], createdAt: Date()),
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
        try await eventLog.append(causal: causal, payload: .turnCreated(turnSnap))
        try await eventLog.append(causal: causal, payload: .runCreated(runSnap))
        try await eventLog.append(causal: causal, payload: .runStarted(runID: runID))

        // Replay/Restore in SessionTurnCoordinator
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
        await coord.restoreHistoricalQueue()

        // Invariant: The crashed run must be terminal .failed, NOT left in running or recoveryRequired
        let restoredRun = try #require(await coord.getRun(runID: runID))
        #expect(restoredRun.status == .failed)
        #expect(restoredRun.terminalReason == .runtimeFailure)

        let restoredTurn = try #require(await coord.getTurn(turnID: turnID))
        #expect(restoredTurn.status == .failed)

        // Verify terminal failure event was appended to durable log for future replays
        let logEvents = await eventLog.allEvents()
        let hasRunFailed = logEvents.contains {
            if case let .runFailed(rID, _) = $0.payload { return rID == runID }
            return false
        }
        let hasTurnFailed = logEvents.contains {
            if case let .turnFailed(tID, _) = $0.payload { return tID == turnID }
            return false
        }
        #expect(hasRunFailed, "runFailed terminal event was not persisted during recovery!")
        #expect(hasTurnFailed, "turnFailed terminal event was not persisted during recovery!")
    }

    // MARK: - 6. P0-E: Official Installer Sidecar Deployment Completeness
    @Test("Official Installer: Sidecars/browser-host is bundled and resolvable")
    func testOfficialInstallerDeploysBrowserSidecar() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sidecarScript = repoRoot.appendingPathComponent("Sidecars/browser-host/index.mjs")
        let sidecarPackage = repoRoot.appendingPathComponent("Sidecars/browser-host/package.json")

        #expect(FileManager.default.fileExists(atPath: sidecarScript.path), "browser-host/index.mjs missing in source repo!")
        #expect(FileManager.default.fileExists(atPath: sidecarPackage.path), "browser-host/package.json missing in source repo!")

        // Verify package-release.sh packages Sidecars/browser-host
        let releaseScriptPath = repoRoot.appendingPathComponent("scripts/package-release.sh").path
        let releaseScriptContent = try String(contentsOfFile: releaseScriptPath, encoding: .utf8)
        #expect(releaseScriptContent.contains("Sidecars/browser-host"), "package-release.sh must package Sidecars/browser-host into archive!")

        // Verify install.sh installs Sidecars/browser-host
        let installScriptPath = repoRoot.appendingPathComponent("install.sh").path
        let installScriptContent = try String(contentsOfFile: installScriptPath, encoding: .utf8)
        #expect(installScriptContent.contains("install_sidecars"), "install.sh must invoke install_sidecars!")
        #expect(installScriptContent.contains("$INSTALL_ROOT/sidecars/browser-host"), "install.sh must deploy to $INSTALL_ROOT/sidecars/browser-host!")
    }
}
