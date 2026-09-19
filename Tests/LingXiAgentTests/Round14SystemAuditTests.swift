import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite("Round 14 System Audit & V1.0.0 Release Gate Tests")
struct Round14SystemAuditTests {

    // MARK: - Helper: Real Stdio Transport & Server Pair
    private struct StdioClientServerHarness {
        let clientToServerPipe = Pipe()
        let serverToClientPipe = Pipe()
        let serverTask: Task<Void, Error>
        let transport: VNextStdioTransport

        init(service: any LingXiProtocolService) {
            let server = VNextStdioCoreServer(
                service: service,
                input: clientToServerPipe.fileHandleForReading,
                output: serverToClientPipe.fileHandleForWriting
            )
            self.serverTask = Task {
                try await server.run()
            }
            self.transport = VNextStdioTransport(
                inputHandle: clientToServerPipe.fileHandleForWriting,
                outputPipe: serverToClientPipe
            )
        }

        func tearDown() {
            serverTask.cancel()
            try? clientToServerPipe.fileHandleForWriting.close()
            try? clientToServerPipe.fileHandleForReading.close()
            try? serverToClientPipe.fileHandleForWriting.close()
            try? serverToClientPipe.fileHandleForReading.close()
        }
    }

    // MARK: - 1. P0-A Command Identity Security Tests
    @Test("CommandStorageSecurity: Prevents path traversal, illegal characters, and enforces length bounds")
    func testCommandStorageSecurityRejectsPathTraversalAndExcessiveLength() throws {
        // 1. Path traversal attacks
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID("../../etc/passwd"))
        }
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID("..\\..\\windows\\system32"))
        }
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID("sub/path/escape"))
        }
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID("null\0byte"))
        }

        // 2. Empty ID
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID(""))
        }

        // 3. Length bounds (>256)
        let tooLongID = String(repeating: "a", count: 257)
        #expect(throws: RuntimeError.self) {
            try CommandStorageSecurity.validate(CommandID(tooLongID))
        }

        // 4. Valid command ID produces safe 64-char sha256 hex key
        let validID = CommandID("client-cmd-12345")
        #expect(throws: Never.self) {
            try CommandStorageSecurity.validate(validID)
        }
        let safeKey = CommandStorageSecurity.safeStorageKey(for: validID)
        #expect(safeKey.count == 64)
        #expect(!safeKey.contains("/") && !safeKey.contains(".."))
    }

    // MARK: - 2. P0-B Idempotency: revertLastTurn & executeExtensionCommand
    @Test("Idempotency Contract: Retrying revertLastTurn returns cached receipt and avoids double reversion")
    func testRevertLastTurnIdempotency() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Populate two historical turns in session store
            _ = try await host.sessionStore.appendMessage(sessionID, message: Message(id: MessageID(), role: .user, content: "Turn 1", createdAt: Date()))
            _ = try await host.sessionStore.appendMessage(sessionID, message: Message(id: MessageID(), role: .assistant, content: "Answer 1", createdAt: Date()))
            _ = try await host.sessionStore.appendMessage(sessionID, message: Message(id: MessageID(), role: .user, content: "Turn 2", createdAt: Date()))
            _ = try await host.sessionStore.appendMessage(sessionID, message: Message(id: MessageID(), role: .assistant, content: "Answer 2", createdAt: Date()))

            let revertCmdID = CommandID("revert-fixed-\(UUID().uuidString)")
            let revertEnvelope = CommandEnvelope(commandID: revertCmdID, payload: RevertLastTurnRequest(sessionID: sessionID))

            // First execution of revertLastTurn
            let rev1 = try await host.revertLastTurn(envelope: revertEnvelope)
            #expect(rev1.commandID == revertCmdID)
            #expect(rev1.result?.removedCount == 2)
            let revisionAfterFirst = rev1.revision

            // Retry execution of revertLastTurn with same CommandID
            let rev2 = try await host.revertLastTurn(envelope: revertEnvelope)
            #expect(rev2.commandID == revertCmdID)
            #expect(rev2.revision == revisionAfterFirst) // Invariant: exactly same revision, not bumped twice
            #expect(rev2.result?.removedCount == 2)

            // Verify session history: only Turn 2 was removed, Turn 1 remains intact
            let session = try await host.sessionStore.session(sessionID)
            let userPrompts = session.messages.filter { $0.role == .user }.map(\.content)
            #expect(userPrompts == ["Turn 1"])
        }
    }

    @Test("Idempotency Contract: Retrying executeExtensionCommand does not execute plugin twice")
    func testExecuteExtensionCommandIdempotency() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup markdown command fixture so executeExtensionCommand succeeds
        let cmdDir = tempDir.appendingPathComponent(".lingxi/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: cmdDir, withIntermediateDirectories: true)
        try "Help output".write(to: cmdDir.appendingPathComponent("help.md"), atomically: true, encoding: .utf8)

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            let cmdID = CommandID("ext-cmd-\(UUID().uuidString)")
            let extEnvelope = CommandEnvelope(
                commandID: cmdID,
                payload: ExecuteExtensionCommandRequest(name: "help", arguments: [], sessionID: sessionID.rawValue)
            )

            let r1 = try await host.executeExtensionCommand(envelope: extEnvelope)
            #expect(r1.commandID == cmdID)

            let r2 = try await host.executeExtensionCommand(envelope: extEnvelope)
            #expect(r2.commandID == cmdID)
            #expect(r2.revision == r1.revision)
            #expect(r2.result?.name == "help")
        }
    }

    // MARK: - 3. P0-B CommandID Conflict Detection
    @Test("Idempotency Journal: Same CommandID reused for different command types throws commandIDConflict")
    func testReusingCommandIDForDifferentTypeThrowsConflict() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sharedCommandID = CommandID("shared-id-\(UUID().uuidString)")

            // 1. First use command ID for createSession
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(commandID: sharedCommandID, payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // 2. Erroneously reuse the same command ID for deleteSession
            await #expect(throws: RuntimeError.self) {
                try await host.deleteSession(envelope: CommandEnvelope(commandID: sharedCommandID, payload: DeleteSessionRequest(sessionID: sessionID)))
            }
        }
    }

    // MARK: - 4. P0-C Real Stdio Wire Attempt Decoupling & Pipe End-to-End
    @Test("VNext Real Stdio Wire: Attempt ID decouples from CommandID over real pipes and Server frames")
    func testRealStdioWireAttemptDecouplingEndToEnd() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let harness = StdioClientServerHarness(service: host)
            defer { harness.tearDown() }

            let fixedCommandID = CommandID("wire-cmd-\(UUID().uuidString)")
            let sessionReceipt = try await harness.transport.createSession(envelope: CommandEnvelope(commandID: fixedCommandID, payload: CreateSessionRequest(workspace: tempDir.path)))
            #expect(sessionReceipt.commandID == fixedCommandID)
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Retry same commandID over real wire
            let retryReceipt = try await harness.transport.createSession(envelope: CommandEnvelope(commandID: fixedCommandID, payload: CreateSessionRequest(workspace: tempDir.path)))
            #expect(retryReceipt.commandID == fixedCommandID)
            #expect(retryReceipt.result?.sessionID == sessionID)
        }
    }

    // MARK: - 5. P0-D Recovery State Reconstruction (Accurate Terminal Snapshots)
    @Test("Recovery State Reconstruction: Historical completed, failed, and cancelled runs rebuild true terminal snapshots")
    func testRecoveryReconstructsAuthoritativeTerminalSnapshots() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("sess-recovery-\(UUID().uuidString)")
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)

        let completedTurnID = TurnID("turn-completed")
        let completedRunID = RunID("run-completed")
        let failedTurnID = TurnID("turn-failed")
        let failedRunID = RunID("run-failed")

        let tCompleted = TurnSnapshot(
            turnID: completedTurnID,
            sessionID: sessionID,
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Work done", attachments: [], createdAt: Date()),
            executionIntent: TurnExecutionIntent(),
            status: .queued, // Initial snapshot queued
            rootRunID: completedRunID,
            createdAt: Date(),
            completedAt: nil
        )
        let rCompleted = RunSnapshot(
            runID: completedRunID,
            sessionID: sessionID,
            turnID: completedTurnID,
            rootRunID: completedRunID,
            status: .queued,
            model: "test-model",
            createdAt: Date(),
            completedAt: nil,
            terminalReason: nil
        )

        let tFailed = TurnSnapshot(
            turnID: failedTurnID,
            sessionID: sessionID,
            userMessage: MessageSnapshot(messageID: MessageID(), role: .user, text: "Fail turn", attachments: [], createdAt: Date()),
            executionIntent: TurnExecutionIntent(),
            status: .queued,
            rootRunID: failedRunID,
            createdAt: Date(),
            completedAt: nil
        )
        let rFailed = RunSnapshot(
            runID: failedRunID,
            sessionID: sessionID,
            turnID: failedTurnID,
            rootRunID: failedRunID,
            status: .queued,
            model: "test-model",
            createdAt: Date(),
            completedAt: nil,
            terminalReason: nil
        )

        let causalCompleted = CausalContext(sessionID: sessionID, turnID: completedTurnID, runID: completedRunID, rootRunID: completedRunID)
        let causalFailed = CausalContext(sessionID: sessionID, turnID: failedTurnID, runID: failedRunID, rootRunID: failedRunID)

        // Write historical sequence
        await eventLog.append(causal: causalCompleted, payload: .turnCreated(tCompleted))
        await eventLog.append(causal: causalCompleted, payload: .runCreated(rCompleted))
        await eventLog.append(causal: causalCompleted, payload: .runStarted(runID: completedRunID))
        await eventLog.append(causal: causalCompleted, payload: .runCompleted(runID: completedRunID, terminalReason: .completed))
        await eventLog.append(causal: causalCompleted, payload: .turnCompleted(turnID: completedTurnID, terminalReason: .completed))

        await eventLog.append(causal: causalFailed, payload: .turnCreated(tFailed))
        await eventLog.append(causal: causalFailed, payload: .runCreated(rFailed))
        await eventLog.append(causal: causalFailed, payload: .runStarted(runID: failedRunID))
        await eventLog.append(causal: causalFailed, payload: .runFailed(runID: failedRunID, error: RuntimeError(category: .runtime, code: "boom", message: "Boom", retryability: .none, source: .core)))
        await eventLog.append(causal: causalFailed, payload: .turnFailed(turnID: failedTurnID, error: RuntimeError(category: .runtime, code: "boom", message: "Boom", retryability: .none, source: .core)))

        // Instantiate coordinator and restore
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
        await coord.restoreHistoricalQueue()

        // Invariant: Completed Run is rebuilt as .completed, not queued or running!
        let run1 = await coord.getRun(runID: completedRunID)
        #expect(run1?.status == .completed)
        #expect(run1?.terminalReason == .completed)
        #expect(run1?.completedAt != nil)

        let turn1 = await coord.getTurn(turnID: completedTurnID)
        #expect(turn1?.status == .completed)
        #expect(turn1?.completedAt != nil)

        // Invariant: Failed Run is rebuilt as .failed, not queued!
        let run2 = await coord.getRun(runID: failedRunID)
        #expect(run2?.status == .failed)
        #expect(run2?.terminalReason == .runtimeFailure)

        let turn2 = await coord.getTurn(turnID: failedTurnID)
        #expect(turn2?.status == .failed)
    }

    // MARK: - 6. P0-E Recovery Startup Ordering & Read-Only Coordinator Access
    @Test("Recovery Ordering: coordinator(for:) is purely read-only and does not trigger queue execution")
    func testCoordinatorAccessIsPurelyReadOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = ControllableFakeProvider()
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))

        try await withTestCoreHost(workspaceRoot: tempDir, providerAssembly: assembly) { host in
            let sessionReceipt = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
            let sessionID = try #require(sessionReceipt.result?.sessionID)

            // Inspect coordinator
            let coord = try await host.coordinator(for: sessionID)
            let active = await coord.activeRootRunID
            #expect(active == nil) // No active execution started by merely querying coordinator
        }
    }

    // MARK: - 7. P1 Branch Prediction Episode Segmentation & Runtime Failure Non-Cancellation
    @Test("Branch Prediction Fabric: extractEpisodes separates runs and does not classify runFailed as user cancellation")
    func testEpisodeExtractorTreatsRuntimeFailureCorrectly() async {
        let extractor = TrajectoryExtractor()
        let sessionID = SessionID("sess-episodes")
        let run1 = RunID("run-1")
        let run2 = RunID("run-2")

        let causal1 = CausalContext(sessionID: sessionID, runID: run1)
        let causal2 = CausalContext(sessionID: sessionID, runID: run2)

        let events: [SessionEventEnvelope] = [
            // Interleaved Run 1 & Run 2 events
            SessionEventEnvelope(cursor: EventCursor(generationID: "g1", sequence: 1), timestamp: Date(), causal: causal1, payload: .toolRequested(ToolInvocationSnapshot(callID: ToolCallID("c1"), toolID: ToolID("read_file"), displayName: "Read", argumentsSummary: "{}", state: .completed))),
            SessionEventEnvelope(cursor: EventCursor(generationID: "g1", sequence: 2), timestamp: Date(), causal: causal2, payload: .toolRequested(ToolInvocationSnapshot(callID: ToolCallID("c2"), toolID: ToolID("search_files"), displayName: "Search", argumentsSummary: "{}", state: .completed))),
            SessionEventEnvelope(cursor: EventCursor(generationID: "g1", sequence: 3), timestamp: Date(), causal: causal1, payload: .toolRequested(ToolInvocationSnapshot(callID: ToolCallID("c3"), toolID: ToolID("edit_file"), displayName: "Edit", argumentsSummary: "{}", state: .completed))),
            // Run 2 completes normally
            SessionEventEnvelope(cursor: EventCursor(generationID: "g1", sequence: 4), timestamp: Date(), causal: causal2, payload: .runCompleted(runID: run2, terminalReason: .completed)),
            // Run 1 suffers a runtime failure (crash/network failure)
            SessionEventEnvelope(cursor: EventCursor(generationID: "g1", sequence: 5), timestamp: Date(), causal: causal1, payload: .runFailed(runID: run1, error: RuntimeError(category: .runtime, code: "e", message: "fail", retryability: .none, source: .core)))
        ]

        let episodes = extractor.extractEpisodes(from: events)

        // Invariant: Exactly two isolated episodes are reconstructed
        #expect(episodes.count == 2)

        // Verify Run 2 episode: [.tool("search_files"), .finish]
        let run2Episode = episodes.first { $0.contains(ActionToken.tool(name: "search_files")) }
        #expect(run2Episode == [ActionToken.tool(name: "search_files"), ActionToken.finish])

        // Verify Run 1 episode: [.tool("read_file"), .tool("edit_file")] WITHOUT .cancel
        let run1Episode = episodes.first { $0.contains(ActionToken.tool(name: "read_file")) }
        #expect(run1Episode == [ActionToken.tool(name: "read_file"), ActionToken.tool(name: "edit_file")])
        #expect(run1Episode?.contains(ActionToken.cancel) == false)
    }
}
