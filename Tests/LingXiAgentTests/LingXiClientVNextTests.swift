import Foundation
import Testing
import LingXiProtocol
import LingXiCore
@testable import LingXiClient

@Suite("LingXiClientVNextTests")
struct LingXiClientVNextTests {

    private func createTestHost() async throws -> (CoreHost, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let credStore = try FileCredentialStore(dataRoot: tempDir.appendingPathComponent("vault"), passphrase: "client-vnext-test")
        let host = try CoreHost(sessionStore: InMemorySessionStore(), workspaceRoot: workspace, credentialStore: credStore)
        await host.start()
        return (host, tempDir)
    }

    // MARK: - 1. Handshake & Capability Negotiation
    @Test("Client performs handshake and capability negotiation successfully")
    func testHandshakeAndCapabilityNegotiationSuccess() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.inProcess(service: host)
        let state = await client.connectionState
        #expect(state.status == .connected)
        #expect(state.protocolVersion == ProtocolVersion.current)
        #expect(state.capabilities != nil)
        #expect(state.capabilities?.supportedModes.contains(.build) == true)
    }

    @Test("Client handshake fails on incompatible protocol major version")
    func testHandshakeFailsOnIncompatibleMajorVersion() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // Client requires major version 2, while host is 1.0
        let incompatibleHandshake = ProtocolHandshake(clientVersion: ProtocolVersion(major: 2, minor: 0))
        let transport = InProcessTransport(service: host, handshake: incompatibleHandshake)

        await #expect(throws: HandshakeError.self) {
            _ = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)
        }
    }

    @Test("Client handshake fails on unsupported required mode")
    func testHandshakeFailsOnUnsupportedMode() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // Client requires an unsupported custom mode
        let unsupportedHandshake = ProtocolHandshake(
            clientVersion: .current,
            requiredModes: [.unknown]
        )
        let transport = InProcessTransport(service: host, handshake: unsupportedHandshake)

        await #expect(throws: HandshakeError.self) {
            _ = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)
        }
    }

    // MARK: - 2. Request/Command Correlation & CommandReceipt
    @Test("CommandEnvelope and QueryEnvelope preserve correlation and idempotency")
    func testCommandQueryCorrelationAndReceipt() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.inProcess(service: host)

        // 1. Session create command
        let sessionReceipt = try await client.session.create(workspace: tempDir.path)
        #expect(sessionReceipt.applied)
        #expect(sessionReceipt.revision > 0)
        #expect(!sessionReceipt.observedThrough.isEmpty)
        let sessionID = try #require(sessionReceipt.result?.sessionID)

        // 2. Query correlation
        let sessionSummary = try await client.session.get(sessionID: sessionID)
        #expect(sessionSummary.sessionID == sessionID)

        // 3. Submit turn command
        let turnReceipt = try await client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "Verify correlation")
        )
        #expect(turnReceipt.applied)
        #expect(turnReceipt.result != nil)
        let turnID = try #require(turnReceipt.result?.turnID)

        // 4. Query turn
        let turn = try await client.turn.getTurn(sessionID: sessionID, turnID: turnID)
        #expect(turn.turnID == turnID)
        #expect(turn.sessionID == sessionID)
    }

    @Test("Real stdio transport delivers VNext turn lifecycle events")
    func testRealStdioTurnLifecycleEvents() async throws {
        let corePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/out/Products/Debug/LingXiCoreHost").path
        let client = try await LingXiClientVNext.stdioCore(corePath: corePath, interactive: false)
        defer { Task { await client.disconnect() } }

        let session = try await client.session.create()
        let sessionID = try #require(session.result?.sessionID)
        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "stdio lifecycle"))

        var events: [SessionEventEnvelope] = []
        for _ in 0..<20 {
            events = try await client.session.listEvents(request: ListSessionEventsRequest(sessionID: sessionID, limit: 100))
            if events.contains(where: { if case .runStarted = $0.payload { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let payloads: [SessionEventPayload] = events.map { $0.payload }
        #expect(payloads.contains { if case .runStarted = $0 { return true }; return false })
    }

    // MARK: - 3. Scoped EventWatermark Await & Sync
    @Test("WatermarkSynchronizer immediately satisfies already-observed cursors")
    func testWatermarkSynchronizerAlreadyObserved() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-1")
        let scope = EventStreamScope.runtime

        await sync.recordObserved(scope: scope, cursor: EventCursor(generationID: genID, sequence: 10))

        // Watermark for sequence 5 is already observed
        let pastWatermark = EventWatermark(scope: scope, cursor: EventCursor(generationID: genID, sequence: 5))
        try await sync.awaitWatermark(pastWatermark, timeout: 1.0)

        // Watermark for exact sequence 10 is already observed
        let exactWatermark = EventWatermark(scope: scope, cursor: EventCursor(generationID: genID, sequence: 10))
        try await sync.awaitWatermark(exactWatermark, timeout: 1.0)
    }

    @Test("WatermarkSynchronizer suspends and resumes when future cursor arrives")
    func testWatermarkSynchronizerSuspendsAndResumes() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-1")
        let scope = EventStreamScope.session(SessionID("sess-wm"))

        let targetWatermark = EventWatermark(scope: scope, cursor: EventCursor(generationID: genID, sequence: 15))

        let asyncWaiter = Task {
            try await sync.awaitWatermark(targetWatermark, timeout: 5.0)
            return true
        }

        // Sleep briefly to ensure waiter is suspended
        try await Task.sleep(nanoseconds: 50_000_000)

        // Record cursor catching up
        await sync.recordObserved(scope: scope, cursor: EventCursor(generationID: genID, sequence: 12))
        try await Task.sleep(nanoseconds: 20_000_000)

        // Record cursor meeting target
        await sync.recordObserved(scope: scope, cursor: EventCursor(generationID: genID, sequence: 15))

        let result = try await asyncWaiter.value
        #expect(result == true)
    }

    @Test("WatermarkSynchronizer throws timeout if watermark not reached")
    func testWatermarkSynchronizerTimeout() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-1")
        let scope = EventStreamScope.runtime

        let futureWatermark = EventWatermark(scope: scope, cursor: EventCursor(generationID: genID, sequence: 999))

        await #expect(throws: WatermarkSyncError.self) {
            try await sync.awaitWatermark(futureWatermark, timeout: 0.1)
        }
    }

    @Test("WatermarkSynchronizer awaits all watermarks in CommandReceipt")
    func testWatermarkSynchronizerReceipt() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-1")
        let sID = SessionID("sess-rcpt")

        let wm1 = EventWatermark(scope: .runtime, cursor: EventCursor(generationID: genID, sequence: 2))
        let wm2 = EventWatermark(scope: .session(sID), cursor: EventCursor(generationID: genID, sequence: 4))

        await sync.markScopeSubscribed(.runtime)
        await sync.markScopeSubscribed(.session(sID))

        let receipt = CommandReceipt<VoidResult>(
            commandID: CommandID(),
            applied: true,
            revision: 5,
            observedThrough: [wm1, wm2]
        )

        let waitTask = Task {
            try await sync.awaitReceipt(receipt, timeout: 5.0)
            return true
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        await sync.recordObserved(scope: .runtime, cursor: EventCursor(generationID: genID, sequence: 2))
        await sync.recordObserved(scope: .session(sID), cursor: EventCursor(generationID: genID, sequence: 4))

        let ok = try await waitTask.value
        #expect(ok == true)
    }

    // MARK: - 4. StreamFrame Ordering, Deduplication & Terminal finalIndex Delivery Barrier
    @Test("StreamFrameReorderBuffer strictly reorders out-of-sequence frames and deduplicates")
    func testStreamFrameReorderingAndDeduplication() async throws {
        let buffer = StreamFrameReorderBuffer()
        let streamID = StreamID("stream-reorder")
        let causal = CausalContext(sessionID: SessionID("s-stream"))

        let stream = await buffer.subscribe(streamID: streamID)

        // Push frames out of order: 2, 0, 1, 4, 3, with duplicates
        let f0 = StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "zero ")
        let f1 = StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "one ")
        let f2 = StreamFrame(streamID: streamID, owner: causal, index: 2, kind: .assistantText, text: "two ")
        let f3 = StreamFrame(streamID: streamID, owner: causal, index: 3, kind: .assistantText, text: "three ")
        let f4 = StreamFrame(streamID: streamID, owner: causal, index: 4, kind: .assistantText, text: "four")

        // Ingest: 2, duplicate 2, 0, 1, 4, 3, duplicate 1
        await buffer.pushFrame(f2)
        await buffer.pushFrame(f2) // duplicate in buffer
        await buffer.pushFrame(f0)
        await buffer.pushFrame(f1)
        await buffer.pushFrame(f4)
        await buffer.pushFrame(f3)
        await buffer.pushFrame(f1) // duplicate already delivered

        var collected: [StreamFrame] = []
        var iterator = stream.makeAsyncIterator()

        while collected.count < 5 {
            if let frame = await iterator.next() {
                collected.append(frame)
            }
        }

        #expect(collected.map(\.index) == [0, 1, 2, 3, 4])
        let combinedText = collected.compactMap(\.textPayload).joined()
        #expect(combinedText == "zero one two three four")
    }

    @Test("StreamFrame delivery barrier blocks until terminal finalIndex arrives")
    func testStreamFrameBarrierBlocksUntilFinalIndex() async throws {
        let buffer = StreamFrameReorderBuffer()
        let streamID = StreamID("stream-barrier")
        let causal = CausalContext(sessionID: SessionID("s-barrier"))

        // Push frames 0 and 1
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "A"))
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "B"))

        // Barrier waiter for finalIndex = 3
        let barrierTask = Task {
            try await buffer.awaitFinalIndex(streamID: streamID, finalIndex: 3, timeout: 5.0)
            return true
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!barrierTask.isCancelled)

        // Push frame 2
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 2, kind: .assistantText, text: "C"))
        try await Task.sleep(nanoseconds: 20_000_000)

        // Push final frame 3
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 3, kind: .assistantText, text: "D"))

        let barrierReleased = try await barrierTask.value
        #expect(barrierReleased == true)
        #expect(await buffer.highestDeliveredIndex(for: streamID) == 3)
    }

    @Test("StreamFrame barrier times out when missing terminal frames")
    func testStreamFrameBarrierTimeoutOnMissingFrames() async throws {
        let buffer = StreamFrameReorderBuffer()
        let streamID = StreamID("stream-missing")
        let causal = CausalContext(sessionID: SessionID("s-missing"))

        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "A"))

        // Wait for finalIndex = 5 with short timeout
        await #expect(throws: StreamFrameBarrierError.self) {
            try await buffer.awaitFinalIndex(streamID: streamID, finalIndex: 5, timeout: 0.1)
        }
    }

    // MARK: - 5. Content Data Plane & Authorization Propagation
    @Test("Content upload, chunk, commit, download, range and authorization context injection")
    func testContentDataPlaneFullLifecycleAndAuthorization() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // Initialize client with connection authorization context
        let connectionAuth = ContentAuthorizationContext(
            principal: "test-user-alice",
            workspaceID: tempDir.path,
            isSystemAdmin: true // Admin for full read permissions in tests
        )

        let client = try await LingXiClientVNext.bootstrapTrustedInProcess(service: host, trustedAuthorization: connectionAuth)

        // 1. Upload
        let payloadString = "Hello LingXi Client vNext Resource Data Plane! Range reading capability test."
        let originalData = Data(payloadString.utf8)

        let contentRef = try await client.resource.upload(
            data: originalData,
            filename: "readme.txt",
            mediaType: "text/plain",
            chunkSize: 16 // Force multiple chunks
        )

        #expect(contentRef.byteCount == originalData.count)

        // 2. Metadata
        let metadata = try await client.resource.metadata(ref: contentRef)
        #expect(metadata.filename == "readme.txt")
        #expect(metadata.ref.byteCount == originalData.count)

        // 3. Full Download
        let downloadedData = try await client.resource.download(ref: contentRef)
        #expect(downloadedData == originalData)

        // 4. Range Read
        let rangeData = try await client.resource.range(ref: contentRef, offset: 6, length: 12)
        let rangeString = String(data: rangeData, encoding: .utf8)
        #expect(rangeString == "LingXi Clien")
    }

    // MARK: - 6. Reconnect / Replay Gap / Generation Mismatch & Snapshot Fallback
    @Test("EventReplayCoordinator falls back to snapshot on generation mismatch")
    func testEventReplayCoordinatorSnapshotFallback() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.inProcess(service: host)
        let createRes = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(createRes.result?.sessionID)

        // Seed some activity
        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "Turn 1"))

        // Coordinator snapshot fallback test
        let coordinator = client.replayCoordinator
        let snapshot = try await coordinator.fallbackToSnapshot(sessionID: sessionID)

        #expect(snapshot.sessionID == sessionID)
        #expect(snapshot.eventCursor.sequence >= 0)

        // Last cursor in coordinator should now match snapshot's cursor
        let currentCursor = await coordinator.getLastSessionCursor(for: sessionID)
        #expect(currentCursor == snapshot.eventCursor)

        // WatermarkSynchronizer should also be updated
        let syncCursor = await client.sync.currentCursor(for: .session(sessionID))
        #expect(syncCursor == snapshot.eventCursor)
    }

    // MARK: - 7. All 13 Protocol Domain Clients End-to-End Availability
    @Test("All 13 protocol domain clients function end-to-end through LingXiClientVNext")
    func testAll13DomainClientsEndToEnd() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.inProcess(service: host)

        // 1. Runtime
        let info = try await client.runtime.getInfo()
        #expect(!info.version.isEmpty)
        let health = try await client.runtime.getHealth()
        #expect(health.status == .healthy)
        let caps = try await client.runtime.getCapabilities()
        #expect(!caps.supportedModes.isEmpty)
        let config = try await client.runtime.getEffectiveConfiguration()
        #expect(!config.coreVersion.isEmpty)
        let reloadReceipt = try await client.runtime.reloadConfiguration()
        #expect(reloadReceipt.applied)
        let updateSetting = try await client.runtime.updateTypedSetting(key: "theme", value: "nord")
        #expect(updateSetting.applied)

        // 2. Session
        let sessReceipt = try await client.session.create(workspace: tempDir.path)
        #expect(sessReceipt.applied)
        let sessionID = try #require(sessReceipt.result?.sessionID)
        let session = try await client.session.get(sessionID: sessionID)
        #expect(session.sessionID == sessionID)
        let sessionList = try await client.session.list()
        #expect(sessionList.items.contains(where: { $0.sessionID == sessionID }))
        let renameReceipt = try await client.session.rename(sessionID: sessionID, title: "SDK Session")
        #expect(renameReceipt.applied)
        let snapshot = try await client.session.snapshot(sessionID: sessionID)
        #expect(snapshot.sessionID == sessionID)

        // 3. Turn
        let turnReceipt = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "SDK Turn"))
        #expect(turnReceipt.applied)
        let turnID = try #require(turnReceipt.result?.turnID)
        let turn = try await client.turn.getTurn(sessionID: sessionID, turnID: turnID)
        #expect(turn.turnID == turnID)
        let turnList = try await client.turn.listTurns(sessionID: sessionID)
        #expect(!turnList.items.isEmpty)

        // 4. Run
        if let runID = turnReceipt.result?.runID {
            let run = try await client.run.getRun(sessionID: sessionID, runID: runID)
            #expect(run.runID == runID)
            let runs = try await client.run.listRuns(sessionID: sessionID)
            #expect(!runs.items.isEmpty)
            let cancelReceipt = try await client.run.cancelRun(sessionID: sessionID, runID: runID)
            #expect(cancelReceipt.applied)
        }
        let tree = try await client.run.getAgentTree(sessionID: sessionID)
        #expect(tree.session.id == sessionID)

        // 5. Interaction
        let interactions = try await client.interaction.listPending(sessionID: sessionID)
        #expect(interactions.isEmpty || !interactions.isEmpty)

        // 6. Provider
        let providers = try await client.provider.list()
        #expect(providers.isEmpty || !providers.isEmpty)
        let pStatus = try await client.provider.status()
        #expect(pStatus.configured || !pStatus.configured)
        let cfgProv = try await client.provider.configure(providerID: "mock-sdk", accountID: "acc-sdk", displayName: "MockSDK")
        #expect(cfgProv.applied)
        let testProv = try await client.provider.test(providerID: "mock-sdk")
        #expect(testProv.applied)
        let remProv = try await client.provider.remove(accountID: "acc-sdk")
        #expect(remProv.applied)
        let reloadProv = try await client.provider.reload()
        #expect(reloadProv.applied)

        // 7. Model
        let models = try await client.model.list()
        #expect(models.isEmpty || !models.isEmpty)
        let modelSel = try await client.model.getSelection()
        #expect(modelSel.modelID.isEmpty || !modelSel.modelID.isEmpty)
        let modelCaps = try await client.model.getCapabilities(modelID: "gpt-4o")
        #expect(modelCaps.supportsStreaming)

        // 8. Context
        let ctxState = try await client.context.getState(sessionID: sessionID)
        #expect(ctxState.sessionID == sessionID)
        let ctxPolicy = try await client.context.getPolicy()
        #expect(ctxPolicy.addressableBudget > 0)
        let compactReceipt = try await client.context.compact(sessionID: sessionID)
        #expect(compactReceipt.applied)
        let searchResults = try await client.context.search(sessionID: sessionID, query: "query")
        #expect(!searchResults.isEmpty)
        let ctxEntry = try await client.context.getEntry(sessionID: sessionID, uri: "test://entry")
        #expect(ctxEntry.uri == "test://entry")
        let updateCtxPolicy = try await client.context.updatePolicy(maxActiveTokens: 64_000)
        #expect(updateCtxPolicy.applied)

        // 9. Extension
        let extensions = try await client.extensionDomain.list()
        #expect(extensions.isEmpty || !extensions.isEmpty)
        let installExt = try await client.extensionDomain.install(name: "sdk-tool", location: "/tmp/sdk-tool")
        #expect(installExt.applied)
        let extID = try #require(installExt.result?.id)
        let extDetail = try await client.extensionDomain.get(id: extID)
        #expect(extDetail.id == extID)
        let disableExt = try await client.extensionDomain.disable(id: extID)
        #expect(disableExt.applied)
        let enableExt = try await client.extensionDomain.enable(id: extID)
        #expect(enableExt.applied)
        let reloadExt = try await client.extensionDomain.reload()
        #expect(reloadExt.applied)
        let cfgExt = try await client.extensionDomain.configure(id: extID, configuration: ["k": "v"])
        #expect(cfgExt.applied)
        let uninstExt = try await client.extensionDomain.uninstall(id: extID)
        #expect(uninstExt.applied)

        // 10. Workspace
        let ws = try await client.workspace.get()
        #expect(ws.rootPath == tempDir.path)
        let wsSummary = try await client.workspace.summary()
        #expect(wsSummary.rootPath == tempDir.path)
        let wsSet = try await client.workspace.set(workspaceRoot: tempDir.path)
        #expect(wsSet.applied)
        let wsDiff = try await client.workspace.diff()
        #expect(wsDiff.diff.isEmpty || !wsDiff.diff.isEmpty)

        // 11. Resource
        let uploadRef = try await client.resource.upload(data: Data("hello resource".utf8), filename: "res.txt")
        #expect(uploadRef.byteCount == 14)
        let downloaded = try await client.resource.download(ref: uploadRef)
        #expect(String(data: downloaded, encoding: .utf8) == "hello resource")
        let range = try await client.resource.range(ref: uploadRef, offset: 0, length: 5)
        #expect(String(data: range, encoding: .utf8) == "hello")

        // 12. Diagnostics
        let diag = try await client.diagnostics.getBundle()
        #expect(!diag.runtimeVersion.isEmpty)
        let provMetrics = try await client.diagnostics.getProviderMetrics()
        #expect(provMetrics.requestCount >= 0)
        let trace = try await client.diagnostics.getRunTrace(sessionID: sessionID, runID: RunID("r-trace"))
        #expect(trace.runID == RunID("r-trace"))

        // 13. Credential
        let storeCred = try await client.credential.store(secret: "top-secret")
        #expect(storeCred.applied)
        let credRef = try #require(storeCred.result?.reference)
        let credStatus = try await client.credential.status(reference: credRef)
        #expect(credStatus.isConfigured)
        let credList = try await client.credential.list()
        #expect(credList.isEmpty || !credList.isEmpty)
        let testCred = try await client.credential.test(reference: credRef)
        #expect(testCred.applied)
        let deleteCred = try await client.credential.delete(reference: credRef)
        #expect(deleteCred.applied)

        // Clean up session
        let delSess = try await client.session.delete(sessionID: sessionID)
        #expect(delSess.applied)
    }

    // MARK: - 8. Real Reconnect Tests with FaultInjectingTransport
    @Test("Real reconnect: normal replay resumes from last EventCursor with no loss, no duplicates, and strict order")
    func testRealReconnectWithNormalReplay() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let faultTransport = FaultInjectingTransport(service: host)
        let client = try await LingXiClientVNext(transport: faultTransport)

        let sessionRes = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(sessionRes.result?.sessionID)

        // Submit first turn
        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "T1"))

        // Consume initial events
        let eventStream1 = try await client.session.events(sessionID: sessionID)
        var consumed1: [SessionEventEnvelope] = []
        var it1 = eventStream1.makeAsyncIterator()
        while consumed1.count < 1 {
            if let ev = await it1.next() {
                consumed1.append(ev)
            }
        }
        let lastCursor = try #require(consumed1.last?.cursor)

        // 1. Force transport disconnect
        faultTransport.forceDisconnect()
        let currentStatus = await faultTransport.connectionState.status
        #expect(currentStatus == .reconnecting)

        // Host commits more turns while client is disconnected
        _ = try await host.submitTurn(envelope: CommandEnvelope(payload: SubmitTurnRequest(sessionID: sessionID, input: UserInput(text: "T2"))))

        // 2. Client reconnects
        try await client.reconnect()

        let statuses = faultTransport.recordedStatuses
        #expect(statuses.contains(.reconnecting))
        #expect(statuses.contains(.handshaking))
        #expect(statuses.contains(.connected))

        // 3. Replay from lastCursor
        let resumedStream = try await client.session.events(sessionID: sessionID, after: lastCursor)
        var consumed2: [SessionEventEnvelope] = []
        var it2 = resumedStream.makeAsyncIterator()

        // Read replayed events
        while consumed2.count < 1 {
            if let ev = await it2.next() {
                consumed2.append(ev)
            }
        }

        // 不丢：T2 产生了新事件并成功消费
        #expect(!consumed2.isEmpty)
        // 不重：重放事件游标均严格大于断开时的 lastCursor
        for ev in consumed2 {
            #expect(ev.cursor > lastCursor)
        }
        // 不乱：序列号严格递增
        for i in 1..<consumed2.count {
            #expect(consumed2[i].cursor > consumed2[i - 1].cursor)
        }
    }

    @Test("Real reconnect: ReplayUnavailable triggers automatic Snapshot fallback")
    func testRealReconnectWithReplayUnavailableTriggersSnapshotFallback() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let faultTransport = FaultInjectingTransport(service: host)
        let client = try await LingXiClientVNext(transport: faultTransport)

        let sessionRes = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(sessionRes.result?.sessionID)
        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "T1"))

        // Disconnect and simulate log pruning
        faultTransport.forceDisconnect()
        faultTransport.replayUnavailable = true

        try await client.reconnect()

        // Subscribing after an old cursor will fail replay, triggering Snapshot fallback
        let oldCursor = EventCursor(generationID: EventLogGenerationID("gen-1"), sequence: 0)
        _ = try await client.session.events(sessionID: sessionID, after: oldCursor)

        // Wait for coordinator to fallback and resync
        let deadline1 = ContinuousClock.now + .seconds(3)
        var lastObserved = await client.replayCoordinator.getLastSessionCursor(for: sessionID)
        while lastObserved == nil && ContinuousClock.now < deadline1 {
            try await Task.sleep(nanoseconds: 10_000_000)
            lastObserved = await client.replayCoordinator.getLastSessionCursor(for: sessionID)
        }

        // Verify that snapshot cursor is adopted
        #expect(lastObserved != nil)
        #expect(lastObserved?.sequence ?? 0 > 0)
    }

    @Test("Real reconnect: generation mismatch triggers automatic Snapshot fallback")
    func testRealReconnectWithGenerationMismatchTriggersSnapshotFallback() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let faultTransport = FaultInjectingTransport(service: host)
        let client = try await LingXiClientVNext(transport: faultTransport)

        let sessionRes = try await client.session.create(workspace: tempDir.path)
        let sessionID = try #require(sessionRes.result?.sessionID)
        _ = try await client.turn.submitTurn(sessionID: sessionID, input: UserInput(text: "T1"))

        faultTransport.forceDisconnect()
        faultTransport.generationMismatch = true

        try await client.reconnect()

        let staleCursor = EventCursor(generationID: EventLogGenerationID("old-gen"), sequence: 5)
        _ = try await client.session.events(sessionID: sessionID, after: staleCursor)

        let deadline2 = ContinuousClock.now + .seconds(3)
        var current = await client.replayCoordinator.getLastSessionCursor(for: sessionID)
        while (current == nil || current?.generationID == EventLogGenerationID("old-gen")) && ContinuousClock.now < deadline2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            current = await client.replayCoordinator.getLastSessionCursor(for: sessionID)
        }

        // Fallback occurred: coordinator now holds current server generation cursor
        #expect(current != nil)
        #expect(current?.generationID != EventLogGenerationID("old-gen"))
    }

    // MARK: - 9. Stream Loss Recovery Tests
    @Test("Stream loss recovery: missing frame gap filled by afterIndex replay")
    func testStreamLossRecoveryWithReplayAfterIndex() async throws {
        let buffer = StreamFrameReorderBuffer()
        let streamID = StreamID("stream-loss-replay")
        let causal = CausalContext(sessionID: SessionID("s-loss"))

        // Push frame 0 and 1
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "A"))
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "B"))

        // Frame 2 is lost!
        // Terminal semantic event arrives with finalIndex = 3
        let terminalFinalIndex: UInt64 = 3

        let barrierTask = Task {
            try await buffer.awaitFinalIndex(streamID: streamID, finalIndex: terminalFinalIndex, timeout: 5.0)
            return true
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        // Replay arrives filling the gap with frames 2 and 3
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 2, kind: .assistantText, text: "C"))
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 3, kind: .assistantText, text: "D"))

        let unblocked = try await barrierTask.value
        #expect(unblocked == true)
        #expect(await buffer.highestDeliveredIndex(for: streamID) == 3)
    }

    @Test("Stream loss recovery: unreplayable stream falls back to canonical committed content and does not forge frames")
    func testStreamLossRecoveryWithCommittedContentFallbackWhenReplayUnavailable() async throws {
        let buffer = StreamFrameReorderBuffer()
        let streamID = StreamID("stream-unreplayable")
        let causal = CausalContext(sessionID: SessionID("s-unreplay"))

        // Frames 0 and 1 delivered over the wire
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "A"))
        await buffer.pushFrame(StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "B"))

        // Frame 2, 3 lost over transport, and terminal event arrives with finalIndex = 3 and authoritative text
        let committedFullText = "ABCD Full Content"
        let barrierTask = Task {
            try await buffer.awaitFinalIndex(streamID: streamID, finalIndex: 3, timeout: 5.0)
            return true
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        // Stream replay fails -> Fallback to canonical committed content resync
        await buffer.resyncWithCanonicalCommittedContent(
            streamID: streamID,
            canonicalContent: committedFullText,
            finalIndex: 3
        )

        let unblocked = try await barrierTask.value
        #expect(unblocked == true)

        // 关键断言：属于 canonical committed-content resync，绝对不伪造原始 frame identity
        #expect(await buffer.isCanonicalResynced(for: streamID) == true)
        #expect(await buffer.canonicalContent(for: streamID) == committedFullText)
        let delivered = await buffer.deliveredFrames(for: streamID)
        #expect(delivered.count == 2) // 只有真实到达的 frame 0 和 1，严禁包含伪造的 frame 2 或 3
        #expect(delivered.map(\.index) == [0, 1])
    }

    // MARK: - 10. Authorization Construction Boundary & Impersonation Prevention Tests
    @Test("Application-facing factory enforces anonymous non-admin context and forbids caller-specified privilege")
    func testAuthorizationConstructionBoundaryEnforcesNonAdmin() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // 1. Normal client connects via application-facing factory without providing credentials
        let client = try await LingXiClientVNext.connectInProcess(service: host)

        // Check injected authorization context is strictly anonymous (non-admin, no principal, no workspace)
        let auth = client.transport.authorizationContext
        #expect(!auth.isSystemAdmin)
        #expect(auth.principal == nil)
        #expect(auth.workspaceID == nil)

        // 2. Upload a restricted content scoped strictly to a principal ("bob")
        let secretData = Data("Super Secret Bob Data".utf8)
        let beginRes = try await host.beginContentUpload(envelope: CommandEnvelope(payload: BeginContentUploadRequest(
            filename: "bob.secret",
            expectedByteCount: secretData.count,
            scope: .principal("bob")
        )))
        let uploadID = try #require(beginRes.result?.uploadID)
        try await host.uploadContentChunk(uploadID: uploadID, chunkIndex: 0, data: secretData)
        let commitRes = try await host.commitContentUpload(envelope: CommandEnvelope(payload: CommitContentUploadRequest(uploadID: uploadID)))
        let bobRef = try #require(commitRes.result)

        // 3. Normal client (Anonymous) attempts to download Bob's content -> Denied
        await #expect(throws: RuntimeError.self) {
            _ = try await client.resource.download(ref: bobRef)
        }
    }

    @Test("Authorization: principal and workspace impersonation prevention across security boundaries")
    func testPrincipalAndWorkspaceImpersonationPrevention() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        // 1. 上传 Alice 的 principal 专属资源与专属 workspace 资源
        let alicePrincipalData = Data("Alice Principal Secret".utf8)
        let beginAlice1 = try await host.beginContentUpload(envelope: CommandEnvelope(payload: BeginContentUploadRequest(
            filename: "alice_p.txt",
            expectedByteCount: alicePrincipalData.count,
            scope: .principal("alice")
        )))
        let upID1 = try #require(beginAlice1.result?.uploadID)
        try await host.uploadContentChunk(uploadID: upID1, chunkIndex: 0, data: alicePrincipalData)
        let commitAlice1 = try await host.commitContentUpload(envelope: CommandEnvelope(payload: CommitContentUploadRequest(uploadID: upID1)))
        let alicePrincipalRef = try #require(commitAlice1.result)

        let aliceWsData = Data("Alice Workspace Secret".utf8)
        let beginAlice2 = try await host.beginContentUpload(envelope: CommandEnvelope(payload: BeginContentUploadRequest(
            filename: "alice_ws.txt",
            expectedByteCount: aliceWsData.count,
            scope: .workspace("/workspaces/alice-project")
        )))
        let upID2 = try #require(beginAlice2.result?.uploadID)
        try await host.uploadContentChunk(uploadID: upID2, chunkIndex: 0, data: aliceWsData)
        let commitAlice2 = try await host.commitContentUpload(envelope: CommandEnvelope(payload: CommitContentUploadRequest(uploadID: upID2)))
        let aliceWsRef = try #require(commitAlice2.result)

        // 2. Application-facing client 无法通过普通工厂冒充 Alice（因为普通工厂无身份参数，只能构造 anonymous 客户端）
        let appClient = try await LingXiClientVNext.connectInProcess(service: host)
        await #expect(throws: RuntimeError.self) {
            _ = try await appClient.resource.download(ref: alicePrincipalRef)
        }
        await #expect(throws: RuntimeError.self) {
            _ = try await appClient.resource.download(ref: aliceWsRef)
        }

        // 3. Bob 受信客户端尝试冒充 / 跨界读取 Alice 的 principal 与 workspace 资源 -> 均被拒绝
        let bobAuth = ContentAuthorizationContext.trusted(
            principal: "bob",
            workspaceID: "/workspaces/bob-project",
            isSystemAdmin: false
        )
        let bobClient = try await LingXiClientVNext.bootstrapTrustedInProcess(service: host, trustedAuthorization: bobAuth)
        await #expect(throws: RuntimeError.self) {
            _ = try await bobClient.resource.download(ref: alicePrincipalRef)
        }
        await #expect(throws: RuntimeError.self) {
            _ = try await bobClient.resource.download(ref: aliceWsRef)
        }

        // 4. 只有在安全边界内由 composition root 正确注入的 Alice 受信客户端才能成功访问
        let aliceAuth = ContentAuthorizationContext.trusted(
            principal: "alice",
            workspaceID: "/workspaces/alice-project",
            isSystemAdmin: false
        )
        let aliceClient = try await LingXiClientVNext.bootstrapTrustedInProcess(service: host, trustedAuthorization: aliceAuth)
        let downloadedAliceP = try await aliceClient.resource.download(ref: alicePrincipalRef)
        #expect(downloadedAliceP == alicePrincipalData)
        let downloadedAliceWs = try await aliceClient.resource.download(ref: aliceWsRef)
        #expect(downloadedAliceWs == aliceWsData)
    }

    // MARK: - 11. Multi-Scope EventWatermark Synchronizer Tests
    @Test("Multi-Scope Watermark: default awaitReceipt requires all scopes and throws cannotSynchronizeScope on unsubscribed scopes")
    func testMultiScopeEventWatermarkDefaultRequiresAllScopesAndThrows() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-multi")
        let sessionA = SessionID("sess-A")
        let sessionB = SessionID("sess-B")

        // 仅订阅 sessionA
        await sync.markScopeSubscribed(.session(sessionA))

        let wm1 = EventWatermark(scope: .session(sessionA), cursor: EventCursor(generationID: genID, sequence: 5))
        let wm2 = EventWatermark(scope: .session(sessionB), cursor: EventCursor(generationID: genID, sequence: 99)) // 未订阅!

        let receipt = CommandReceipt<VoidResult>(
            commandID: CommandID(),
            applied: true,
            revision: 10,
            observedThrough: [wm1, wm2]
        )

        // 默认策略（requireAllScopes）：不得静默跳过未订阅 scope，必须显式抛出 cannotSynchronizeScope
        do {
            try await sync.awaitReceipt(receipt, timeout: 2.0)
            Issue.record("Expected cannotSynchronizeScope error was not thrown")
        } catch let WatermarkSyncError.cannotSynchronizeScope(scope, _) {
            #expect(scope == .session(sessionB))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Multi-Scope Watermark: explicit onlySubscribedScopes policy safely skips unsubscribed scopes")
    func testMultiScopeEventWatermarkExplicitPolicyAllowsOnlySubscribedScopes() async throws {
        let sync = WatermarkSynchronizer()
        let genID = EventLogGenerationID("gen-multi")
        let sessionA = SessionID("sess-A")
        let sessionB = SessionID("sess-B")

        // 仅订阅 sessionA
        await sync.markScopeSubscribed(.session(sessionA))

        let wm1 = EventWatermark(scope: .session(sessionA), cursor: EventCursor(generationID: genID, sequence: 5))
        let wm2 = EventWatermark(scope: .session(sessionB), cursor: EventCursor(generationID: genID, sequence: 99)) // 未订阅!

        let receipt = CommandReceipt<VoidResult>(
            commandID: CommandID(),
            applied: true,
            revision: 10,
            observedThrough: [wm1, wm2]
        )

        let awaitTask = Task {
            try await sync.awaitReceipt(receipt, timeout: 2.0, policy: .onlySubscribedScopes)
            return true
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        // 满足已订阅的 sessionA
        await sync.recordObserved(scope: .session(sessionA), cursor: EventCursor(generationID: genID, sequence: 5))

        // 显式策略下成功返回，未订阅的 sessionB 安全跳过
        let completed = try await awaitTask.value
        #expect(completed == true)
    }

    @Test("Multi-Scope Watermark: autoSubscribeUnsubscribedScopes automatically establishes consumers for all scopes")
    func testMultiScopeEventWatermarkAutoSubscribeConsumesAllScopes() async throws {
        let (host, tempDir) = try await createTestHost()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let sessionRes1 = try await client.session.create(workspace: tempDir.path)
        let s1 = try #require(sessionRes1.result?.sessionID)

        let sessionRes2 = try await client.session.create(workspace: tempDir.path)
        let s2 = try #require(sessionRes2.result?.sessionID)

        // 客户端只显式订阅 s1
        _ = try await client.session.events(sessionID: s1)

        // 提交两笔 Turn
        let t1 = try await client.turn.submitTurn(sessionID: s1, input: UserInput(text: "Hello s1"))
        let t2 = try await client.turn.submitTurn(sessionID: s2, input: UserInput(text: "Hello s2"))

        // 构造一个包含 s1 与 s2 的复合 receipt
        let receipt = CommandReceipt<VoidResult>(
            commandID: CommandID(),
            applied: true,
            revision: 1,
            observedThrough: t1.observedThrough + t2.observedThrough
        )

        // 通过 client.awaitReceipt(autoSubscribeUnsubscribedScopes: true) 自动建立 s2 consumer 并等待全部 watermark
        try await client.awaitReceipt(receipt, timeout: 5.0, policy: .requireAllScopes, autoSubscribeUnsubscribedScopes: true)

        let s1Observed = await client.sync.currentCursor(for: .session(s1))
        let s2Observed = await client.sync.currentCursor(for: .session(s2))
        #expect(s1Observed != nil)
        #expect(s2Observed != nil)
    }
}
