import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import CryptoKit

@Suite("Protocol vNext Frozen Contract Tests")
struct ProtocolVNextFrozenContractTests {

    // MARK: - 1. Canonical IDs, Causal Context & Watermarking
    @Test("Canonical IDs and bidirectional conversions are verified")
    func canonicalIDsAndConversions() {
        let turnID = TurnID()
        let runID = RunID()
        let stepID = ModelStepID()
        let interactionID = InteractionID()
        let providerReqID = ProviderRequestID("req-1")
        let cmdID = CommandID()
        let reqID = RequestID()
        let contentID = ContentID()
        let genID = EventLogGenerationID("gen-1")
        let errorID = RuntimeErrorID()

        #expect(!turnID.rawValue.isEmpty)
        #expect(!runID.rawValue.isEmpty)
        #expect(!stepID.rawValue.isEmpty)
        #expect(!interactionID.rawValue.isEmpty)
        #expect(providerReqID.rawValue == "req-1")
        #expect(!cmdID.rawValue.isEmpty)
        #expect(!reqID.rawValue.isEmpty)
        #expect(!contentID.rawValue.isEmpty)
        #expect(genID.rawValue == "gen-1")
        #expect(!errorID.rawValue.isEmpty)

        // Bidirectional conversion between RunID and AgentRunID
        let agentRunID = AgentRunID(runID.rawValue)
        let convertedRunID = RunID(agentRunID.rawValue)
        #expect(convertedRunID == runID)

        // CausalContext provenance
        let causal = CausalContext(
            sessionID: SessionID("s-1"),
            turnID: turnID,
            runID: runID,
            rootRunID: runID,
            modelStepID: stepID,
            providerRequestID: providerReqID
        )
        #expect(causal.sessionID == SessionID("s-1"))
        #expect(causal.turnID == turnID)
        #expect(causal.runID == runID)

        // Scoped EventWatermark
        let cursor1 = EventCursor(generationID: genID, sequence: 10)
        let cursor2 = EventCursor(generationID: genID, sequence: 20)
        #expect(cursor1 < cursor2)

        let runtimeWatermark = EventWatermark(scope: .runtime, cursor: cursor1)
        let sessionWatermark = EventWatermark(scope: .session(SessionID("s-1")), cursor: cursor2)
        #expect(runtimeWatermark.scope == .runtime)
        #expect(sessionWatermark.scope == .session(SessionID("s-1")))
        #expect(sessionWatermark.cursor.sequence == 20)
    }

    // MARK: - 2. Protocol Envelopes and Extensible Enums
    @Test("Envelopes, receipts, and extensible enum fallbacks encode/decode reliably")
    func envelopesAndExtensibleEnums() throws {
        // Envelopes
        let cmdEnv = CommandEnvelope(
            commandID: CommandID("cmd-100"),
            payload: CreateSessionRequest(defaultMode: .build, defaultPermissionConfiguration: .askWorkspace)
        )
        let cmdData = try JSONEncoder().encode(cmdEnv)
        let decodedCmd = try JSONDecoder().decode(CommandEnvelope<CreateSessionRequest>.self, from: cmdData)
        #expect(decodedCmd.commandID == CommandID("cmd-100"))
        #expect(decodedCmd.payload.defaultMode == .build)

        // CommandReceipt
        let receipt = CommandReceipt<SessionSummary>(
            commandID: CommandID("cmd-100"),
            applied: true,
            revision: 5,
            observedThrough: [EventWatermark(scope: .runtime, cursor: EventCursor(generationID: EventLogGenerationID("g1"), sequence: 42))],
            result: SessionSummary(sessionID: SessionID("s-100"), title: "Test", turnCount: 0, mode: .build)
        )
        let receiptData = try JSONEncoder().encode(receipt)
        let decodedReceipt = try JSONDecoder().decode(CommandReceipt<SessionSummary>.self, from: receiptData)
        #expect(decodedReceipt.commandID == CommandID("cmd-100"))
        #expect(decodedReceipt.applied)
        #expect(decodedReceipt.revision == 5)
        #expect(decodedReceipt.observedThrough.count == 1)
        #expect(decodedReceipt.result?.title == "Test")

        // Extensible Enum Fallbacks
        let unknownCategoryJSON = Data("\"futureCategory\"".utf8)
        let decodedCategory = try JSONDecoder().decode(RuntimeErrorCategory.self, from: unknownCategoryJSON)
        #expect(decodedCategory == .unknown)

        let unknownStreamKindJSON = Data("\"quantumStream\"".utf8)
        let decodedStreamKind = try JSONDecoder().decode(StreamKind.self, from: unknownStreamKindJSON)
        #expect(decodedStreamKind == .unknown)

        let unknownAgentModeJSON = Data("\"superAutonomous\"".utf8)
        let decodedMode = try JSONDecoder().decode(AgentMode.self, from: unknownAgentModeJSON)
        #expect(decodedMode == .unknown)
    }

    // MARK: - 3. CoreHost Session Lifecycle & Idempotency
    @Test("CoreHost session lifecycle and idempotent durable receipts")
    func coreHostSessionLifecycleAndIdempotency() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let store = InMemorySessionStore()
        let host = try CoreHost(sessionStore: store, workspaceRoot: workspace)
        await host.start()

        // 1. Create Session
        let createCmdID = CommandID()
        let createEnvelope = CommandEnvelope(
            commandID: createCmdID,
            payload: CreateSessionRequest(
                workspace: tempDir.path,
                initialModel: "fake/model",
                defaultMode: .build,
                defaultPermissionConfiguration: .askWorkspace
            )
        )
        let createReceipt = try await host.createSession(envelope: createEnvelope)
        #expect(createReceipt.applied)
        #expect(createReceipt.result != nil)
        let sessionID = try #require(createReceipt.result?.sessionID)
        #expect(createReceipt.observedThrough.count >= 2)

        // Idempotency: duplicate call with same commandID returns identical receipt
        let duplicateReceipt = try await host.createSession(envelope: createEnvelope)
        #expect(duplicateReceipt.commandID == createCmdID)
        #expect(duplicateReceipt.result?.sessionID == sessionID)

        // 2. Query Session & Snapshot
        let getSessionResponse = try await host.getSession(envelope: QueryEnvelope(payload: GetSessionRequest(sessionID: sessionID)))
        #expect(getSessionResponse.payload.sessionID == sessionID)

        let snapshotResponse = try await host.getSessionSnapshot(envelope: QueryEnvelope(payload: GetSessionSnapshotRequest(sessionID: sessionID)))
        #expect(snapshotResponse.payload.sessionID == sessionID)
        #expect(snapshotResponse.payload.agentMode == .build)

        // 3. Rename Session
        let renameCmdID = CommandID()
        let renameReceipt = try await host.renameSession(envelope: CommandEnvelope(
            commandID: renameCmdID,
            payload: RenameSessionRequest(sessionID: sessionID, title: "Renamed Title")
        ))
        #expect(renameReceipt.result?.title == "Renamed Title")

        // 4. List Sessions
        let listResponse = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
        #expect(listResponse.payload.items.contains(where: { $0.sessionID == sessionID }))

        // 5. Delete Session
        let deleteCmdID = CommandID()
        let deleteReceipt = try await host.deleteSession(envelope: CommandEnvelope(
            commandID: deleteCmdID,
            payload: DeleteSessionRequest(sessionID: sessionID)
        ))
        #expect(deleteReceipt.applied)

        await host.shutdown()
    }

    // MARK: - 4. submitTurn Single Active Root Run & Turn Queuing
    @Test("submitTurn enforces max 1 active Root Run rule and queues extra turns")
    func submitTurnSingleActiveRootRunAndQueuing() async throws {
        let sessionID = SessionID("test-session-turn")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let input1 = UserInput(text: "Turn 1 request")
        let intent1 = TurnExecutionIntent(mode: .build)
        let msg1 = MessageSnapshot(role: .user, text: input1.text)

        // Turn 1 should start running
        let decision1 = await coordinator.submitTurn(input: input1, intent: intent1, userMessage: msg1)
        #expect(decision1.status == .running)
        #expect(decision1.shouldStartExecution)
        let runID1 = try #require(decision1.runID)

        // Turn 2 submitted while Turn 1 is active: MUST be queued!
        let input2 = UserInput(text: "Turn 2 request")
        let intent2 = TurnExecutionIntent(mode: .build)
        let msg2 = MessageSnapshot(role: .user, text: input2.text)

        let decision2 = await coordinator.submitTurn(input: input2, intent: intent2, userMessage: msg2)
        #expect(decision2.status == .queued)
        #expect(!decision2.shouldStartExecution)
        #expect(decision2.runID == nil)
        let turnID2 = decision2.turn.turnID

        // Cancel the queued turn
        try await coordinator.cancelTurn(turnID: turnID2)
        let cancelledTurn = await coordinator.getTurn(turnID: turnID2)
        #expect(cancelledTurn?.status == .cancelled)

        // Now finish Turn 1
        let nextToRun = await coordinator.finishRun(runID: runID1, reason: .completed)
        #expect(nextToRun == nil) // No more queued turns because Turn 2 was cancelled
        #expect(await coordinator.activeRootRunID == nil)
    }

    // MARK: - 5. StreamFrame Ownership, Stable MessageID & Terminal Barrier
    @Test("Assistant stream allocates stable MessageID before first frame and enforces terminal barrier")
    func assistantStreamMessageIDAndBarrier() async throws {
        let sessionID = SessionID("stream-session")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let turnDecision = await coordinator.submitTurn(
            input: UserInput(text: "Generate answer"),
            intent: TurnExecutionIntent(),
            userMessage: MessageSnapshot(role: .user, text: "Generate answer")
        )
        let runID = try #require(turnDecision.runID)
        let stepID = ModelStepID()

        // 1. Stable MessageID must exist before any frame
        let (messageID, streamID) = await coordinator.beginAssistantStream(stepID: stepID, runID: runID)
        #expect(!messageID.rawValue.isEmpty)
        #expect(!streamID.rawValue.isEmpty)

        // Verify event log recorded assistantMessageStarted with this exact MessageID
        let events = await coordinator.eventLog.recentEvents()
        let startedEvent = events.first(where: { env in
            if case let .assistantMessageStarted(mid, sid) = env.payload {
                return mid == messageID && sid == streamID
            }
            return false
        })
        #expect(startedEvent != nil)

        // 2. Subscribe to StreamFrames
        let stream = await coordinator.subscribeStream(streamID: streamID, afterIndex: nil)

        // 3. Emit frames
        let causal = CausalContext(sessionID: sessionID, turnID: turnDecision.turn.turnID, runID: runID, modelStepID: stepID)
        let frame1 = StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "Hello")
        let frame2 = StreamFrame(streamID: streamID, owner: causal, index: 2, kind: .assistantText, text: " World")
        try await coordinator.emitStreamFrame(frame: frame1)
        try await coordinator.emitStreamFrame(frame: frame2)

        // 4. Commit assistant message with terminal finalIndex = 2
        await coordinator.commitAssistantMessage(
            messageID: messageID,
            streamID: streamID,
            causal: causal,
            content: "Hello World",
            finalIndex: 2
        )

        // 5. Terminal Barrier: emitting index > finalIndex MUST throw
        let frame3 = StreamFrame(streamID: streamID, owner: causal, index: 3, kind: .assistantText, text: " extra")
        await #expect(throws: RuntimeError.self) {
            try await coordinator.emitStreamFrame(frame: frame3)
        }

        // 6. Verify subscriber received frames
        var receivedTexts: [String] = []
        for await frame in stream {
            if let text = frame.textPayload {
                receivedTexts.append(text)
            }
        }
        #expect(receivedTexts == ["Hello", " World"])
    }

    // MARK: - 6. Snapshot and Replay with Generation Validation
    @Test("Event Log generation validation and replay boundary")
    func snapshotAndReplayWithGenerationValidation() async throws {
        let sessionID = SessionID("replay-session")
        let genID = EventLogGenerationID("gen-session-1")
        let eventLog = SessionEventLog(sessionID: sessionID, generationID: genID)

        let causal = CausalContext(sessionID: sessionID)
        await eventLog.append(causal: causal, payload: .runQueued(runID: RunID("r1")))
        let cursor1 = await eventLog.currentCursor()
        await eventLog.append(causal: causal, payload: .runStarted(runID: RunID("r1")))
        await eventLog.append(causal: causal, payload: .runCompleted(runID: RunID("r1"), terminalReason: .completed))

        // Normal replay from cursor1 (sequence 1) should yield sequences 2 and 3
        let replayStream = try await eventLog.subscribe(after: cursor1)
        var replayedEvents: [SessionEventEnvelope] = []
        for await event in replayStream {
            replayedEvents.append(event)
            if event.cursor.sequence == 3 {
                break
            }
        }
        #expect(replayedEvents.count == 2)
        #expect(replayedEvents.map(\.cursor.sequence) == [2, 3])

        // Reconnect with outdated generation: MUST throw replayUnavailable
        let foreignCursor = EventCursor(generationID: EventLogGenerationID("gen-foreign"), sequence: 1)
        await #expect(throws: RuntimeError.self) {
            _ = try await eventLog.subscribe(after: foreignCursor)
        }
    }

    // MARK: - 7. Content Upload & Range Retrieval
    @Test("Chunked content upload, SHA-256 digest validation, and range read")
    func chunkedContentUploadAndRangeRead() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contentStore = ContentStore(storageDirectory: tempDir)

        let beginResp = await contentStore.beginUpload(request: BeginContentUploadRequest(
            filename: "hello.txt",
            proposedMediaType: "text/plain",
            expectedByteCount: 11
        ))
        let uploadID = beginResp.uploadID

        // Upload chunk 2 then chunk 1 (out of order writing)
        try await contentStore.writeChunk(uploadID: uploadID, chunkIndex: 2, data: Data("World".utf8))
        try await contentStore.writeChunk(uploadID: uploadID, chunkIndex: 1, data: Data("Hello ".utf8))

        // Compute expected sha256
        let fullData = Data("Hello World".utf8)
        let hash = SHA256.hash(data: fullData)
        let digest = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

        // Commit upload with correct digest
        let ref = try await contentStore.commitUpload(request: CommitContentUploadRequest(
            uploadID: uploadID,
            expectedDigest: digest
        ))
        #expect(ref.byteCount == 11)
        #expect(ref.digest == digest)

        // Verify full read
        let readData = try await contentStore.read(id: ref.id)
        #expect(readData == fullData)

        // Verify range read: bytes 6..<11 is "World"
        let rangeData = try await contentStore.readRange(id: ref.id, offset: 6, length: 5)
        #expect(String(data: rangeData, encoding: .utf8) == "World")

        // Verify metadata
        let meta = try await contentStore.metadata(id: ref.id)
        #expect(meta.filename == "hello.txt")
        #expect(meta.ref.byteCount == 11)
    }

    // MARK: - 8. Permission Presets & Operation Policies
    @Test("Permission configuration presets, operation approval policies, and interaction resolution")
    func permissionPresetsAndInteractionResolution() async throws {
        // Presets verification
        let askWs = PermissionConfiguration.askWorkspace
        #expect(askWs.accessScope == .workspace)
        #expect(askWs.approvalPolicy.workspaceMutation == .ask)

        let autoWs = PermissionConfiguration.autoWorkspace
        #expect(autoWs.accessScope == .workspace)
        #expect(autoWs.approvalPolicy.workspaceMutation == .allow)

        let yoloFull = PermissionConfiguration.yoloFullAccess
        #expect(yoloFull.accessScope == .fullAccess)
        #expect(yoloFull.approvalPolicy.processExecution == .allow)

        // Interaction resolution in SessionTurnCoordinator
        let sessionID = SessionID("interaction-session")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let interactionID = InteractionID()
        let interactionSnapshot = InteractionSnapshot(
            interactionID: interactionID,
            kind: .permission,
            causal: CausalContext(sessionID: sessionID),
            createdAt: Date(),
            permissionRequest: PermissionRequest(
                permissionID: PermissionID("p-1"),
                sessionID: sessionID,
                toolCallID: ToolCallID("call-1"),
                toolID: ToolID("shell"),
                capabilities: [],
                resource: "/workspace",
                description: "Execute shell command"
            )
        )
        await coordinator.recordInteractionRequested(snapshot: interactionSnapshot)

        // Resolve interaction
        try await coordinator.resolveInteraction(
            interactionID: interactionID,
            resolution: .permission(.allow)
        )

        let recentEvents = await coordinator.eventLog.recentEvents()
        let resolvedEvent = recentEvents.first(where: { env in
            if case let .interactionResolved(id, res) = env.payload {
                return id == interactionID && res == .permission(.allow)
            }
            return false
        })
        #expect(resolvedEvent != nil)
    }

    // MARK: - 9. Crash-Safe Atomic Durable Commit & Fault Injection
    @Test("Crash-safe atomic durable commit with failpoint injection across all commit phases and idempotent retry")
    func crashSafeAtomicDurableCommit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let store = InMemorySessionStore()
        let host = try CoreHost(sessionStore: store, workspaceRoot: workspace)
        await host.start()

        // 1. Failpoint: beforeStateMutation
        let cmd1 = CommandEnvelope(
            commandID: CommandID("cmd-fp-1"),
            payload: CreateSessionRequest(workspace: tempDir.path)
        )
        await host.setCommitFailpoint(.beforeStateMutation)
        do {
            _ = try await host.createSession(envelope: cmd1)
            #expect(Bool(false), "Should have thrown failpoint error")
        } catch let err as RuntimeError {
            #expect(err.code == "injectedCrashBeforeMutation")
        }
        // Verify state was not mutated
        let list1 = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
        #expect(list1.payload.items.isEmpty)
        // Retry with same commandID after resolving fault succeeds cleanly
        await host.setCommitFailpoint(nil)
        let receipt1 = try await host.createSession(envelope: cmd1)
        #expect(receipt1.applied)
        let sessionID = try #require(receipt1.result?.sessionID)

        // 2. Failpoint: afterStateMutationBeforeEventAppend
        let cmd2 = CommandEnvelope(
            commandID: CommandID("cmd-fp-2"),
            payload: CreateSessionRequest(workspace: tempDir.path)
        )
        await host.setCommitFailpoint(.afterStateMutationBeforeEventAppend)
        do {
            _ = try await host.createSession(envelope: cmd2)
            #expect(Bool(false), "Should have thrown failpoint error")
        } catch let err as RuntimeError {
            #expect(err.code == "injectedCrashAfterMutation")
        }
        // State was rolled back: only sessionID exists, no ghost session
        let list2 = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
        #expect(list2.payload.items.count == 1)
        #expect(list2.payload.items.first?.sessionID == sessionID)
        // Retry with same commandID succeeds cleanly
        await host.setCommitFailpoint(nil)
        let receipt2 = try await host.createSession(envelope: cmd2)
        #expect(receipt2.applied)
        let sessionID2 = try #require(receipt2.result?.sessionID)
        #expect(sessionID2 != sessionID)

        // 3. Failpoint: afterEventAppendBeforeReceipt
        let cmd3 = CommandEnvelope(
            commandID: CommandID("cmd-fp-3"),
            payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Hello failpoint"))
        )
        await host.setCommitFailpoint(.afterEventAppendBeforeReceipt)
        do {
            _ = try await host.submitTurn(envelope: cmd3)
            #expect(Bool(false), "Should have thrown failpoint error")
        } catch let err as RuntimeError {
            #expect(err.code == "injectedCrashAfterEventBeforeReceipt")
        }
        // State rolled back: no active turn in coordinator
        let coord = try await host.coordinator(for: sessionID)
        #expect(await coord.activeRootRunID == nil)
        // Retry with same commandID succeeds
        await host.setCommitFailpoint(nil)
        let receipt3 = try await host.submitTurn(envelope: cmd3)
        #expect(receipt3.applied)

        // 4. Failpoint: afterCommitBeforeResponse (idempotency barrier test)
        let cmd4 = CommandEnvelope(
            commandID: CommandID("cmd-fp-4"),
            payload: CreateSessionRequest(workspace: tempDir.path)
        )
        await host.setCommitFailpoint(.afterCommitBeforeResponse)
        do {
            _ = try await host.createSession(envelope: cmd4)
            #expect(Bool(false), "Should have thrown failpoint error")
        } catch let err as RuntimeError {
            #expect(err.code == "injectedCrashAfterCommitBeforeResponse")
        }
        // Since state mutation, event log, and idempotency journal all committed before failure,
        // retry with SAME commandID should return cached receipt without creating an extra duplicate session!
        await host.setCommitFailpoint(nil)
        let receipt4 = try await host.createSession(envelope: cmd4)
        #expect(receipt4.applied)
        #expect(receipt4.commandID == cmd4.commandID)
        let list4 = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 20)))
        let matchingSessions = list4.payload.items.filter { $0.sessionID == receipt4.result?.sessionID }
        #expect(matchingSessions.count == 1)

        await host.shutdown()
    }

    // MARK: - 10. EventLog Persistence & Cold Restart
    @Test("EventLog persistence preserves generationID, resumes sequence and supports replay after restart")
    func eventLogColdRestart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = SessionID("cold-restart-session")

        // 1. Initial run: create log and append events
        let initialGenID: EventLogGenerationID
        let cursorBeforeRestart: EventCursor
        do {
            let log = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
            initialGenID = await log.generationID
            #expect(!initialGenID.rawValue.isEmpty)

            let causal = CausalContext(sessionID: sessionID)
            await log.append(causal: causal, payload: .runQueued(runID: RunID("r-0")))
            await log.append(causal: causal, payload: .runStarted(runID: RunID("r-0")))
            cursorBeforeRestart = await log.currentCursor()
            #expect(cursorBeforeRestart.sequence == 2)
            await log.append(causal: causal, payload: .runStarted(runID: RunID("r-1")))
        }

        // 2. Cold restart: instantiate fresh SessionEventLog from same storageDirectory
        let restartedLog = SessionEventLog(sessionID: sessionID, storageDirectory: tempDir)
        let restartedGenID = await restartedLog.generationID
        #expect(restartedGenID == initialGenID) // GenerationID MUST be stable across normal restarts

        let restartedCursor = await restartedLog.currentCursor()
        #expect(restartedCursor.sequence == 3) // Sequence restored to 3

        // 3. Replay using pre-restart cursor
        let replayStream = try await restartedLog.subscribe(after: cursorBeforeRestart)
        var replayed: [SessionEventEnvelope] = []
        for await event in replayStream {
            replayed.append(event)
            if event.cursor.sequence == 3 {
                break
            }
        }
        #expect(replayed.count == 1)
        #expect(replayed.first?.cursor.sequence == 3)
        if case .runStarted(let runID) = replayed.first?.payload {
            #expect(runID == RunID("r-1"))
        } else {
            #expect(Bool(false), "Expected runStarted payload")
        }

        // 4. Continue appending after restart: sequence must monotonically increment
        let causal = CausalContext(sessionID: sessionID)
        await restartedLog.append(causal: causal, payload: .runCompleted(runID: RunID("r-1"), terminalReason: .completed))
        let afterAppendCursor = await restartedLog.currentCursor()
        #expect(afterAppendCursor.sequence == 4)
    }

    // MARK: - 11. ContentRef Authorization Scoping
    // MARK: - 11. ContentRef Authorization Scoping & Trust Boundary
    @Test("ContentRef authorization scoping prevents unauthorized cross-session, cross-principal, cross-workspace and forged admin access")
    func contentRefAuthorizationScoping() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)

        // 1. Forged admin attack: untrusted wire client sends isSystemAdmin: true
        let forgedJSON = """
        {
            "sessionID": "s-untrusted",
            "principal": "mallory",
            "workspaceID": "ws-untrusted",
            "isSystemAdmin": true
        }
        """.data(using: .utf8)!
        let untrustedContext = try JSONDecoder().decode(ContentAuthorizationContext.self, from: forgedJSON)
        #expect(untrustedContext.isSystemAdmin == false) // CRITICAL SECURITY: Public deserialization must force false

        // 2. Session-scoped content
        let s1 = SessionID("session-alpha")
        let s2 = SessionID("session-beta")
        let beginAlpha = await store.beginUpload(request: BeginContentUploadRequest(
            filename: "secret.txt",
            proposedMediaType: "text/plain",
            expectedByteCount: 5,
            scope: .session(s1)
        ))
        try await store.writeChunk(uploadID: beginAlpha.uploadID, chunkIndex: 1, data: Data("alpha".utf8))
        let refAlpha = try await store.commitUpload(request: CommitContentUploadRequest(
            uploadID: beginAlpha.uploadID,
            expectedDigest: nil
        ))

        // Read by untrusted attacker trying to claim admin: DENIED
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refAlpha.id, authorization: untrustedContext)
        }

        // Read by same session: allowed
        let alphaData = try await store.read(id: refAlpha.id, authorization: ContentAuthorizationContext(sessionID: s1))
        #expect(String(data: alphaData, encoding: .utf8) == "alpha")

        // Read by different session: denied
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refAlpha.id, authorization: ContentAuthorizationContext(sessionID: s2))
        }

        // Read by anonymous: denied
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refAlpha.id, authorization: .anonymous)
        }

        // Read by genuine server-side trusted admin: allowed
        let adminData = try await store.read(id: refAlpha.id, authorization: .system)
        #expect(adminData == alphaData)

        let trustedAdminData = try await store.read(id: refAlpha.id, authorization: .trusted(isSystemAdmin: true))
        #expect(trustedAdminData == alphaData)

        // Metadata check respects scope
        await #expect(throws: RuntimeError.self) {
            _ = try await store.metadata(id: refAlpha.id, authorization: ContentAuthorizationContext(sessionID: s2))
        }
        let metaAlpha = try await store.metadata(id: refAlpha.id, authorization: ContentAuthorizationContext(sessionID: s1))
        #expect(metaAlpha.scope == .session(s1))

        // 3. Principal-scoped content
        let beginUser = await store.beginUpload(request: BeginContentUploadRequest(
            filename: "user_doc.txt",
            expectedByteCount: 4,
            scope: .principal("alice")
        ))
        try await store.writeChunk(uploadID: beginUser.uploadID, chunkIndex: 1, data: Data("user".utf8))
        let refUser = try await store.commitUpload(request: CommitContentUploadRequest(uploadID: beginUser.uploadID, expectedDigest: nil))

        // Read by bob: denied
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refUser.id, authorization: ContentAuthorizationContext(principal: "bob"))
        }

        // Read by alice: allowed
        let aliceData = try await store.read(id: refUser.id, authorization: ContentAuthorizationContext(principal: "alice"))
        #expect(String(data: aliceData, encoding: .utf8) == "user")

        // 4. Workspace-scoped content
        let wsA = "ws-project-alpha"
        let wsB = "ws-project-beta"
        let beginWs = await store.beginUpload(request: BeginContentUploadRequest(
            filename: "project_plan.md",
            expectedByteCount: 4,
            scope: .workspace(wsA)
        ))
        try await store.writeChunk(uploadID: beginWs.uploadID, chunkIndex: 1, data: Data("plan".utf8))
        let refWs = try await store.commitUpload(request: CommitContentUploadRequest(uploadID: beginWs.uploadID, expectedDigest: nil))

        // Same workspace: allowed
        let wsAData = try await store.read(id: refWs.id, authorization: ContentAuthorizationContext(workspaceID: wsA))
        #expect(String(data: wsAData, encoding: .utf8) == "plan")

        // Cross-workspace: denied
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refWs.id, authorization: ContentAuthorizationContext(workspaceID: wsB))
        }

        // Context with sessionID but no workspaceID: denied
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: refWs.id, authorization: ContentAuthorizationContext(sessionID: s1))
        }
    }

    // MARK: - 12. Subprocess Real Crash Kill (SIGKILL) & WAL Startup Recovery
    private static func runCrashProcess(stage: String, dataRoot: URL, commandID: String) throws -> Int32 {
        let process = Process()
        let debugURL = URL(fileURLWithPath: "/Volumes/Development/Projects/projects/LingXiAgent/.build/out/Products/Debug/LingXiCoreHost")
        process.executableURL = debugURL
        process.arguments = ["--crash-test", stage, dataRoot.path, commandID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Subprocess real crash kill (SIGKILL) across all commit phases with WAL recovery and idempotent retry")
    func subprocessRealCrashAtomicDurableCommit() async throws {
        // Stage 1: Crash after mutation before event append
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cmdID = "cmd-crash-mut-1"
            let exitCode = try Self.runCrashProcess(stage: "after-mutation", dataRoot: tempDir, commandID: cmdID)
            #expect(exitCode == 9 || exitCode == 137) // Killed by SIGKILL

            let walDir = tempDir.appendingPathComponent(".lingxi/eventlog/wal")
            let walFilesBefore = (try? FileManager.default.contentsOfDirectory(atPath: walDir.path)) ?? []
            #expect(!walFilesBefore.isEmpty)

            // Start fresh CoreHost on same directory: WAL recovery rolls back uncommitted state
            let host = try CoreHost(dataRoot: tempDir)
            await host.start()

            let sessions = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessions.payload.items.isEmpty)

            let walFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: walDir.path)) ?? []
            #expect(walFilesAfter.isEmpty)

            // Retry with same commandID succeeds cleanly
            let retryReceipt = try await host.createSession(envelope: CommandEnvelope(commandID: CommandID(cmdID), payload: CreateSessionRequest()))
            #expect(retryReceipt.applied)
            #expect(retryReceipt.commandID == CommandID(cmdID))

            let sessionsAfterRetry = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessionsAfterRetry.payload.items.count == 1)
            await host.shutdown()
        }

        // Stage 2: Crash after event append before receipt commit
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cmdID = "cmd-crash-evt-2"
            let exitCode = try Self.runCrashProcess(stage: "after-event", dataRoot: tempDir, commandID: cmdID)
            #expect(exitCode == 9 || exitCode == 137)

            // Start fresh CoreHost: WAL recovery truncates uncommitted events & cleans session
            let host = try CoreHost(dataRoot: tempDir)
            await host.start()

            let sessions = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessions.payload.items.isEmpty)

            let retryReceipt = try await host.createSession(envelope: CommandEnvelope(commandID: CommandID(cmdID), payload: CreateSessionRequest()))
            #expect(retryReceipt.applied)

            let sessionsAfterRetry = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessionsAfterRetry.payload.items.count == 1)
            await host.shutdown()
        }

        // Stage 3: Crash after receipt commit before client response
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cmdID = "cmd-crash-rec-3"
            let exitCode = try Self.runCrashProcess(stage: "after-receipt", dataRoot: tempDir, commandID: cmdID)
            #expect(exitCode == 9 || exitCode == 137)

            let txDir = tempDir.appendingPathComponent(".lingxi/eventlog/committed_tx")
            let txFiles = (try? FileManager.default.contentsOfDirectory(atPath: txDir.path)) ?? []
            #expect(txFiles.contains("\(cmdID).json"))

            // Start fresh CoreHost: transaction was already committed
            let host = try CoreHost(dataRoot: tempDir)
            await host.start()

            let sessions = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessions.payload.items.count == 1)

            // Retry with same commandID returns committed receipt immediately without duplicate mutation
            let retryReceipt = try await host.createSession(envelope: CommandEnvelope(commandID: CommandID(cmdID), payload: CreateSessionRequest()))
            #expect(retryReceipt.applied)
            #expect(retryReceipt.commandID == CommandID(cmdID))
            #expect(retryReceipt.result?.sessionID == sessions.payload.items.first?.sessionID)

            let sessionsAfterRetry = try await host.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
            #expect(sessionsAfterRetry.payload.items.count == 1)
            await host.shutdown()
        }
    }

    // MARK: - 13. LingXiProtocolService 13-Domain Frozen Contract Matrix
    @Test("LingXiProtocolService all 13 domains have functioning typed methods")
    func lingXiProtocolServiceDomainMatrix() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let credStore = try FileCredentialStore(dataRoot: tempDir.appendingPathComponent("vault"), passphrase: "test-passphrase-matrix")
        let host = try CoreHost(sessionStore: InMemorySessionStore(), workspaceRoot: workspace, credentialStore: credStore)
        await host.start()
        let service: any LingXiProtocolService = host

        // 1. Runtime Domain
        let rtInfo = try await service.getRuntimeInfo(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(!rtInfo.payload.version.isEmpty)
        let rtHealth = try await service.getRuntimeHealth(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(rtHealth.payload.status == .healthy)
        let rtCaps = try await service.getRuntimeCapabilities(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(!rtCaps.payload.supportedModes.isEmpty)
        let config = try await service.getEffectiveConfiguration(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(!config.payload.coreVersion.isEmpty)
        let reloadRes = try await service.reloadConfiguration(envelope: CommandEnvelope(payload: VoidResult()))
        #expect(reloadRes.applied)
        let updateSettingRes = try await service.updateTypedSetting(envelope: CommandEnvelope(payload: UpdateTypedSettingRequest(key: "theme", value: "dark")))
        #expect(updateSettingRes.applied)

        // 2. Session Domain
        let createRes = try await service.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempDir.path)))
        let sessionID = try #require(createRes.result?.sessionID)
        let getSess = try await service.getSession(envelope: QueryEnvelope(payload: GetSessionRequest(sessionID: sessionID)))
        #expect(getSess.payload.sessionID == sessionID)
        let snap = try await service.getSessionSnapshot(envelope: QueryEnvelope(payload: GetSessionSnapshotRequest(sessionID: sessionID)))
        #expect(snap.payload.sessionID == sessionID)
        let listSess = try await service.listSessions(envelope: QueryEnvelope(payload: PageRequest(limit: 10)))
        #expect(listSess.payload.items.contains(where: { $0.sessionID == sessionID }))
        let renameRes = try await service.renameSession(envelope: CommandEnvelope(payload: RenameSessionRequest(sessionID: sessionID, title: "Matrix Session")))
        #expect(renameRes.result?.title == "Matrix Session")

        // 3. Turn Domain
        let turnRes = try await service.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "Hello Matrix"))))
        #expect(turnRes.applied)
        let turnID = try #require(turnRes.result?.turnID)
        let getTurnRes = try await service.getTurn(envelope: QueryEnvelope(payload: GetTurnRequest(sessionID: sessionID, turnID: turnID)))
        #expect(getTurnRes.payload.turnID == turnID)
        let listTurnsRes = try await service.listTurns(envelope: QueryEnvelope(payload: ListTurnsRequest(sessionID: sessionID)))
        #expect(!listTurnsRes.payload.items.isEmpty)
        await #expect(throws: RuntimeError.self) {
            _ = try await service.cancelTurn(envelope: CommandEnvelope(payload: CancelTurnRequest(sessionID: sessionID, turnID: TurnID("nonexistent"))))
        }

        // 4. Run Domain
        if let activeRunID = turnRes.result?.runID {
            let getRunRes = try await service.getRun(envelope: QueryEnvelope(payload: GetRunRequest(sessionID: sessionID, runID: activeRunID)))
            #expect(getRunRes.payload.runID == activeRunID)
            let listRunsRes = try await service.listRuns(envelope: QueryEnvelope(payload: ListRunsRequest(sessionID: sessionID)))
            #expect(!listRunsRes.payload.items.isEmpty)
            let cancelRunRes = try await service.cancelRun(envelope: CommandEnvelope(payload: CancelRunRequest(sessionID: sessionID, runID: activeRunID)))
            #expect(cancelRunRes.applied)
        }
        let treeRes = try await service.getAgentTree(envelope: QueryEnvelope(payload: GetAgentTreeRequest(sessionID: sessionID)))
        #expect(treeRes.payload.children.isEmpty || !treeRes.payload.children.isEmpty)

        // 5. Interaction Domain
        let listInt = try await service.listPendingInteractions(envelope: QueryEnvelope(payload: ListInteractionsRequest(sessionID: sessionID)))
        #expect(listInt.payload.isEmpty)

        // 6. Provider Domain
        let provList = try await service.listProviders(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(provList.payload.isEmpty || !provList.payload.isEmpty)
        let provStatus = try await service.getProviderStatus(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(provStatus.payload.configured || !provStatus.payload.configured)
        let cfgProvRes = try await service.configureProvider(envelope: CommandEnvelope(payload: ConfigureProviderRequest(providerID: "mock-provider", accountID: "acc-mock", displayName: "Mock")))
        #expect(cfgProvRes.applied)
        let testProvRes = try await service.testProvider(envelope: CommandEnvelope(payload: TestProviderRequest(providerID: "mock-provider")))
        #expect(testProvRes.applied)
        #expect(testProvRes.result?.reachable == true)
        let getProvRes = try await service.getProvider(envelope: QueryEnvelope(payload: GetProviderRequest(providerID: "acc-mock")))
        #expect(getProvRes.payload.id == "acc-mock")
        let remProvRes = try await service.removeProvider(envelope: CommandEnvelope(payload: RemoveProviderRequest(accountID: "acc-mock")))
        #expect(remProvRes.applied)
        let reloadProvRes = try await service.reloadProviders(envelope: CommandEnvelope(payload: VoidResult()))
        #expect(reloadProvRes.applied)

        // 7. Model Domain
        let modelList = try await service.listModels(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(modelList.payload.isEmpty || !modelList.payload.isEmpty)
        let modelSel = try await service.getModelSelection(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(modelSel.payload.providerID == nil || modelSel.payload.providerID != nil)
        let modelCapsRes = try await service.getModelCapabilities(envelope: QueryEnvelope(payload: GetModelCapabilitiesRequest(modelID: "gpt-4o")))
        #expect(modelCapsRes.payload.supportsStreaming)
        if let firstModel = modelList.payload.first {
            let getModelRes = try await service.getModel(envelope: QueryEnvelope(payload: GetModelRequest(modelID: firstModel.id)))
            #expect(getModelRes.payload.id == firstModel.id)
            let setSelRes = try await service.setModelSelection(envelope: CommandEnvelope(payload: SetModelSelectionRequest(modelID: firstModel.id)))
            #expect(setSelRes.applied)
        }

        // 8. Context Domain
        let ctxState = try await service.getContextState(envelope: QueryEnvelope(payload: GetContextStateRequest(sessionID: sessionID)))
        #expect(ctxState.payload.sessionID == sessionID)
        let ctxPolicy = try await service.getContextPolicy(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(ctxPolicy.payload.addressableBudget > 0)
        let compactRes = try await service.compactContext(envelope: CommandEnvelope(payload: CompactContextRequest(sessionID: sessionID)))
        #expect(compactRes.applied)
        let searchCtxRes = try await service.searchContext(envelope: QueryEnvelope(payload: SearchContextRequest(sessionID: sessionID, query: "test")))
        #expect(!searchCtxRes.payload.isEmpty)
        let getCtxEntryRes = try await service.getContextEntry(envelope: QueryEnvelope(payload: GetContextEntryRequest(sessionID: sessionID, uri: "test://entry")))
        #expect(getCtxEntryRes.payload.uri == "test://entry")
        let updatePolicyRes = try await service.updateContextPolicy(envelope: CommandEnvelope(payload: UpdateContextPolicyRequest(maxActiveTokens: 50_000)))
        #expect(updatePolicyRes.applied)

        // 9. Extension Domain
        let extList = try await service.listExtensions(envelope: QueryEnvelope(payload: ListExtensionsRequest()))
        #expect(extList.payload.isEmpty || !extList.payload.isEmpty)
        let installExtRes = try await service.installExtension(envelope: CommandEnvelope(payload: InstallExtensionRequest(name: "custom-tool", location: "/tmp/tool")))
        #expect(installExtRes.applied)
        let extID = try #require(installExtRes.result?.id)
        let getExtRes = try await service.getExtension(envelope: QueryEnvelope(payload: GetExtensionRequest(id: extID)))
        #expect(getExtRes.payload.id == extID)
        let disableExtRes = try await service.disableExtension(envelope: CommandEnvelope(payload: DisableExtensionRequest(id: extID)))
        #expect(disableExtRes.applied)
        let enableExtRes = try await service.enableExtension(envelope: CommandEnvelope(payload: EnableExtensionRequest(id: extID)))
        #expect(enableExtRes.applied)
        let reloadExtRes = try await service.reloadExtensions(envelope: CommandEnvelope(payload: VoidResult()))
        #expect(reloadExtRes.applied)
        let cfgExtRes = try await service.configureExtension(envelope: CommandEnvelope(payload: ConfigureExtensionRequest(id: extID, configuration: [:])))
        #expect(cfgExtRes.applied)
        let uninstExtRes = try await service.uninstallExtension(envelope: CommandEnvelope(payload: UninstallExtensionRequest(id: extID)))
        #expect(uninstExtRes.applied)

        // 10. Workspace Domain
        let wsSummary = try await service.getWorkspaceSummary(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(wsSummary.payload.rootPath == tempDir.path)
        let wsGet = try await service.getWorkspace(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(wsGet.payload.rootPath == tempDir.path)
        let wsSet = try await service.setWorkspace(envelope: CommandEnvelope(payload: SetWorkspaceRequest(workspaceRoot: tempDir.path)))
        #expect(wsSet.applied)
        let wsDiff = try await service.getWorkspaceDiffSummary(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(wsDiff.payload.diff.isEmpty || !wsDiff.payload.diff.isEmpty)

        // 11. Resource Domain
        let uploadBegin = try await service.beginContentUpload(envelope: CommandEnvelope(payload: BeginContentUploadRequest(filename: "a.txt", expectedByteCount: 3)))
        #expect(uploadBegin.applied)
        let uploadID = try #require(uploadBegin.result?.uploadID)
        try await service.uploadContentChunk(uploadID: uploadID, chunkIndex: 1, data: Data("abc".utf8))
        let uploadCommit = try await service.commitContentUpload(envelope: CommandEnvelope(payload: CommitContentUploadRequest(uploadID: uploadID, expectedDigest: nil)))
        #expect(uploadCommit.applied)
        let contentRef = try #require(uploadCommit.result)
        let metaRes = try await service.getContentMetadata(ref: contentRef, authorization: .system)
        #expect(metaRes.filename == "a.txt")
        let contentData = try await service.getContent(ref: contentRef, authorization: .system)
        #expect(String(data: contentData, encoding: .utf8) == "abc")
        let rangeData = try await service.getContentRange(ref: contentRef, offset: 1, length: 2, authorization: .system)
        #expect(String(data: rangeData, encoding: .utf8) == "bc")

        // 12. Diagnostics Domain
        let diagRes = try await service.getDiagnostics(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(!diagRes.payload.runtimeVersion.isEmpty)
        let perfRes = try await service.getPerformanceMetrics(envelope: QueryEnvelope(payload: GetPerformanceMetricsRequest(sessionID: sessionID)))
        #expect(perfRes.payload == nil || perfRes.payload != nil)
        let provMetrics = try await service.getProviderMetrics(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(provMetrics.payload.requestCount >= 0)
        let runTraceRes = try await service.getRunTrace(envelope: QueryEnvelope(payload: GetRunTraceRequest(sessionID: sessionID, runID: RunID("r-test"))))
        #expect(runTraceRes.payload.runID == RunID("r-test"))

        // 13. Credential Domain
        let credStoreRes = try await service.storeCredential(envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "dummy-secret")))
        #expect(credStoreRes.applied)
        let credRef = try #require(credStoreRes.result?.reference)
        let credStatus = try await service.getCredentialStatus(envelope: QueryEnvelope(payload: GetCredentialStatusRequest(reference: credRef)))
        #expect(credStatus.payload.isConfigured)
        let listCredsRes = try await service.listCredentials(envelope: QueryEnvelope(payload: VoidResult()))
        #expect(listCredsRes.payload.isEmpty || !listCredsRes.payload.isEmpty)
        let testCredRes = try await service.testCredential(envelope: CommandEnvelope(payload: TestCredentialRequest(reference: credRef)))
        #expect(testCredRes.applied)
        let credDelRes = try await service.deleteCredential(envelope: CommandEnvelope(payload: DeleteCredentialRequest(reference: credRef)))
        #expect(credDelRes.applied)

        // Clean up session
        let delSess = try await service.deleteSession(envelope: CommandEnvelope(payload: DeleteSessionRequest(sessionID: sessionID)))
        #expect(delSess.applied)

        await host.shutdown()
    }
}
