import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiClient
@testable import LingXiApplication

@Suite("Round 6 System Audit & Architecture Hardening Tests")
struct Round6SystemAuditTests {

    @Test("Phase 1: Concurrent YOLO vs Ask sessions have 1000-interleaving deterministic permission isolation")
    func testConcurrentSessionsPermissionIsolationDeterministic() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let testFile = tempRoot.appendingPathComponent("test.txt")
        try "hello round 6".write(to: testFile, atomically: true, encoding: .utf8)

        let permissionEngine = PermissionEngine(configuration: .strict)
        let workspace = try WorkspaceRoot(path: tempRoot.path)
        let toolRuntime = ToolRuntime(
            registry: .builtin(workspace: workspace),
            permissions: permissionEngine
        )

        let sessionA = SessionID("session-yolo-A")
        let sessionB = SessionID("session-ask-B")

        let contextA = RunExecutionContext(
            runID: "run-yolo-1",
            sessionID: sessionA,
            permissionConfiguration: .yoloFullAccess
        )

        let contextB = RunExecutionContext(
            runID: "run-ask-2",
            sessionID: sessionB,
            permissionConfiguration: .askWorkspace
        )

        // Run 1000 concurrent interleaved tool executions between YOLO and Ask
        let iterations = 1000
        actor Counter {
            var yoloSuccess = 0
            var askPrompted = 0

            func recordYolo() { yoloSuccess += 1 }
            func recordAsk() { askPrompted += 1 }
        }
        let counter = Counter()

        // Background noise: concurrently change global permission configuration on the engine
        // to verify that per-run execution context is completely immune to global mutation
        let noiseTask = Task {
            for i in 0..<iterations {
                await permissionEngine.setConfiguration(i % 2 == 0 ? .strict : .yoloFullAccess)
                await Task.yield()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                let callA = ToolCall(
                    callID: ToolCallID("call-a-\(i)"),
                    toolID: ToolID("read_file"),
                    arguments: #"{"path":"test.txt"}"#
                )
                let callB = ToolCall(
                    callID: ToolCallID("call-b-\(i)"),
                    toolID: ToolID("read_file"),
                    arguments: #"{"path":"test.txt"}"#
                )

                // Session A task: YOLO should NEVER ask and always succeed
                group.addTask {
                    let outcome = await toolRuntime.executeWithMetrics(
                        callA,
                        sessionID: sessionA,
                        runExecutionContext: contextA,
                        onPermissionAsked: { _ in
                            Issue.record("Session A with YOLO should never prompt for permission!")
                        }
                    )
                    #expect(outcome.result.success)
                    #expect(!outcome.permissionAsked)
                    await counter.recordYolo()
                }

                // Session B task: Ask should ALWAYS ask
                group.addTask {
                    let outcome = await toolRuntime.executeWithMetrics(
                        callB,
                        sessionID: sessionB,
                        runExecutionContext: contextB,
                        onPermissionAsked: { request in
                            // Auto-reply to let it proceed once asked
                            Task {
                                try? await permissionEngine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
                            }
                        }
                    )
                    #expect(outcome.result.success)
                    #expect(outcome.permissionAsked)
                    await counter.recordAsk()
                }
            }
        }
        noiseTask.cancel()

        let finalYolo = await counter.yoloSuccess
        let finalAsk = await counter.askPrompted
        #expect(finalYolo == iterations)
        #expect(finalAsk == iterations)
    }

    @Test("Phase 1: HITL pending requests are strictly bound to owning RunID and cancelled selectively")
    func testHITLPendingContinuationBoundToRunID() async throws {
        let engine = PermissionEngine(configuration: .strict)

        let req1 = PermissionRequest(
            permissionID: PermissionID("perm-run1"),
            sessionID: SessionID("session-test"),
            runID: "run-1",
            toolCallID: ToolCallID("call-1"),
            toolID: ToolID("bash"),
            resource: "rm -rf /",
            description: "test danger"
        )

        let req2 = PermissionRequest(
            permissionID: PermissionID("perm-run2"),
            sessionID: SessionID("session-test"),
            runID: "run-2",
            toolCallID: ToolCallID("call-2"),
            toolID: ToolID("bash"),
            resource: "ls",
            description: "test normal"
        )

        let resolution1Task = Task {
            await engine.resolve(req1) {}
        }
        let resolution2Task = Task {
            await engine.resolve(req2) {}
        }

        // Give continuations a brief moment to register
        try await Task.sleep(for: .milliseconds(50))

        // Cancel pending for run-1 only
        await engine.cancelPending(runID: "run-1")

        // req1 must resolve to deny
        let res1 = await resolution1Task.value
        #expect(res1.decision == .deny)

        // req2 must still be pending! Now reply allow to req2
        try await engine.reply(PermissionReply(permissionID: req2.permissionID, decision: .allow))
        let res2 = await resolution2Task.value
        #expect(res2.decision == .allow)
    }

    @Test("Phase 2: Workspace transition atomically updates AgentRuntime and real Tool execution (A->B real file read)")
    func testWorkspaceTransitionUpdatesAgentRuntimeAndRealToolExecution() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-ws-\(UUID().uuidString)")
        let wsA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let wsB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileA = wsA.appendingPathComponent("A_ONLY.txt")
        let fileB = wsB.appendingPathComponent("B_ONLY.txt")
        try "Content A".write(to: fileA, atomically: true, encoding: .utf8)
        try "Content B".write(to: fileB, atomically: true, encoding: .utf8)

        let sandbox = CoreStorageLayout.temporarySandbox()
        try sandbox.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let host = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: wsA.path),
            storageLayout: sandbox
        )
        await host.start()
        defer {
            Task {
                await host.shutdown()
            }
        }

        guard let agent = await host.agent else {
            Issue.record("AgentRuntime should be initialized")
            return
        }

        // Before transition: AgentRuntime's ToolRuntime must read A_ONLY.txt successfully
        let agentToolRuntimeBefore = await agent.currentToolRuntime
        let callA = ToolCall(callID: ToolCallID("call-a"), toolID: ToolID("read_file"), arguments: #"{"path":"A_ONLY.txt"}"#)
        let callB = ToolCall(callID: ToolCallID("call-b"), toolID: ToolID("read_file"), arguments: #"{"path":"B_ONLY.txt"}"#)

        let context = RunExecutionContext(
            runID: "test-run",
            sessionID: SessionID("test-sess"),
            permissionConfiguration: .yoloFullAccess
        )

        let outcomeA1 = await agentToolRuntimeBefore.executeWithMetrics(callA, sessionID: SessionID("test-sess"), runExecutionContext: context, onPermissionAsked: { _ in })
        #expect(outcomeA1.result.success)
        #expect(outcomeA1.result.content.contains("Content A"))

        let outcomeB1 = await agentToolRuntimeBefore.executeWithMetrics(callB, sessionID: SessionID("test-sess"), runExecutionContext: context, onPermissionAsked: { _ in })
        #expect(!outcomeB1.result.success) // B_ONLY doesn't exist in wsA

        // Apply Workspace transition to ProjectB
        try await host.applyWorkspaceTransition(to: wsB)

        // After transition: AgentRuntime's ToolRuntime must have been updated to ProjectB
        let agentToolRuntimeAfter = await agent.currentToolRuntime
        let outcomeB2 = await agentToolRuntimeAfter.executeWithMetrics(callB, sessionID: SessionID("test-sess"), runExecutionContext: context, onPermissionAsked: { _ in })
        #expect(outcomeB2.result.success)
        #expect(outcomeB2.result.content.contains("Content B"))

        let outcomeA2 = await agentToolRuntimeAfter.executeWithMetrics(callA, sessionID: SessionID("test-sess"), runExecutionContext: context, onPermissionAsked: { _ in })
        #expect(!outcomeA2.result.success) // A_ONLY doesn't exist in wsB
    }

    @Test("Phase 3: ContentStore fails closed on missing or corrupted metadata (no global fallback leak)")
    func testContentStoreFailClosedOnCorruptedMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)
        let sampleData = Data("sensitive session content".utf8)
        let ref = await store.store(
            data: sampleData,
            mediaType: "text/plain",
            filename: "secret.txt",
            scope: .session(SessionID("private-session"))
        )

        // 1. Authorized session reads successfully
        let authSession = ContentAuthorizationContext(sessionID: SessionID("private-session"))
        let readData = try await store.read(id: ref.id, authorization: authSession)
        #expect(readData == sampleData)

        // 2. Unauthorized session is denied
        let unauthorized = ContentAuthorizationContext(sessionID: SessionID("attacker-session"))
        await #expect(throws: RuntimeError.self) {
            _ = try await store.read(id: ref.id, authorization: unauthorized)
        }

        // 3. Delete metadata file from disk and simulate clean cache reload
        let metaURL = tempDir.appendingPathComponent("\(ref.id.rawValue).meta.json")
        try FileManager.default.removeItem(at: metaURL)

        // Create a new store instance pointing to same directory so in-memory cache is empty
        let freshStore = ContentStore(storageDirectory: tempDir)
        // Must fail closed with corruptedContentMetadata, NEVER fallback to .global!
        do {
            _ = try await freshStore.read(id: ref.id, authorization: .anonymous)
            Issue.record("Should have failed closed when metadata was missing")
        } catch let err as RuntimeError {
            #expect(err.code == "corruptedContentMetadata")
        }

        // 4. Corrupt metadata file
        try Data("corrupted json syntax".utf8).write(to: metaURL)
        let freshStore2 = ContentStore(storageDirectory: tempDir)
        do {
            _ = try await freshStore2.read(id: ref.id, authorization: .anonymous)
            Issue.record("Should have failed closed when metadata was corrupted")
        } catch let err as RuntimeError {
            #expect(err.code == "corruptedContentMetadata")
        }
    }

    @Test("Phase 3: ContentStore readRange streams via FileHandle without full payload in-memory buffering")
    func testContentStoreReadRangeFileHandleStreaming() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)
        let fullString = (0..<1000).map { "LINE_\(String(format: "%04d", $0))\n" }.joined()
        let fullData = Data(fullString.utf8)
        let ref = await store.store(data: fullData, scope: .global)

        // Read arbitrary byte range
        let offset = 450
        let length = 120
        let expectedRange = fullData.subdata(in: offset..<(offset + length))

        let rangeData = try await store.readRange(id: ref.id, offset: offset, length: length)
        #expect(rangeData == expectedRange)
    }

    @Test("Phase 3: Chunk continuity and expectedByteCount integrity checks")
    func testChunkContinuityAndByteCountVerification() async throws {
        let store = ContentStore()
        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "file.bin",
            proposedMediaType: "application/octet-stream",
            expectedByteCount: 15,
            scope: .global
        ))
        let uploadID = beginResp.uploadID

        // Upload chunk 0 and chunk 2, skipping chunk 1
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 0, data: Data("chunk0_".utf8)) // 7 bytes
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 2, data: Data("chunk2".utf8)) // 6 bytes

        // Commit should fail because chunk 1 is missing
        do {
            _ = try await store.commitUpload(request: CommitContentUploadRequest(uploadID: uploadID))
            Issue.record("Should fail because chunk 1 is missing")
        } catch let err as RuntimeError {
            #expect(err.code == "incompleteChunks")
        }

        // Upload chunk 1 now
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 1, data: Data("chunk1_".utf8)) // 7 bytes
        // Total bytes = 7 + 7 + 6 = 20, but expected was 15 -> should fail byteCountMismatch
        do {
            _ = try await store.commitUpload(request: CommitContentUploadRequest(uploadID: uploadID))
            Issue.record("Should fail on byteCountMismatch")
        } catch let err as RuntimeError {
            #expect(err.code == "byteCountMismatch")
        }
    }

    @Test("Phase 3: Stdio transport end-to-end chunked content upload data plane")
    func testStdioChunkedContentUploadDataPlane() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-stdio-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let layout = CoreStorageLayout(root: tempDir)
        try layout.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let host = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: tempDir.path),
            storageLayout: layout
        )
        await host.start()
        defer {
            Task {
                await host.shutdown()
            }
        }

        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let server = VNextStdioCoreServer(
            service: host,
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let serverTask = Task.detached { try await server.run() }
        defer {
            serverTask.cancel()
            try? clientToServer.fileHandleForReading.close()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForReading.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        let transport = VNextStdioTransport(inputHandle: clientToServer.fileHandleForWriting, outputPipe: serverToClient)
        let client = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)
        defer { Task { await client.disconnect() } }

        // Test chunked upload over Stdio
        let chunk0 = Data("Hello, Stdio Data Plane! ".utf8)
        let chunk1 = Data("Chunk 1 uploaded smoothly.".utf8)
        let totalBytes = chunk0.count + chunk1.count

        let beginReceipt = try await client.resource.beginUpload(
            filename: "stdio_upload.txt",
            expectedByteCount: totalBytes,
            mediaType: "text/plain"
        )
        let uploadID = try #require(beginReceipt.result?.uploadID)

        // Upload chunk 0
        try await client.resource.uploadChunk(uploadID: uploadID, chunkIndex: 0, data: chunk0)
        // Upload chunk 1
        try await client.resource.uploadChunk(uploadID: uploadID, chunkIndex: 1, data: chunk1)

        // Commit upload
        let commitReceipt = try await client.resource.commitUpload(uploadID: uploadID)
        let contentRef = try #require(commitReceipt.result)
        #expect(contentRef.byteCount == totalBytes)

        // Retrieve full content over Stdio
        let retrievedData = try await client.resource.download(ref: contentRef)
        let expectedData = chunk0 + chunk1
        #expect(retrievedData == expectedData)

        // Retrieve range over Stdio
        let rangeData = try await client.resource.range(ref: contentRef, offset: 7, length: 5)
        let expectedSubdata = expectedData.subdata(in: 7..<12)
        #expect(rangeData == expectedSubdata)
    }

    @Test("Phase 4: Graceful shutdown cleans up server event subscriptions and terminates boundedly")
    func testGracefulShutdownAndSubscriptionTeardown() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-graceful-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let layout = CoreStorageLayout(root: tempDir)
        try layout.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let host = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: tempDir.path),
            storageLayout: layout
        )
        await host.start()

        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let server = VNextStdioCoreServer(
            service: host,
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let serverTask = Task.detached { try await server.run() }

        let transport = VNextStdioTransport(inputHandle: clientToServer.fileHandleForWriting, outputPipe: serverToClient)
        let client = try await LingXiClientVNext(transport: transport, handshakeImmediately: true)

        // 1. Subscribe to runtime events via transport
        let stream = await transport.subscribeRuntimeEvents(after: nil)
        let consumeTask = Task {
            for await _ in stream {}
        }

        // 2. Disconnect gracefully: closes stdin, triggers server loop exit and cancelAll()
        let start = Date()
        await client.disconnect()
        let elapsed = Date().timeIntervalSince(start)

        // Graceful disconnect must complete boundedly (well within 2 seconds)
        #expect(elapsed < 2.0)

        // Server task must finish when stdin is closed
        _ = try? await serverTask.value
        await host.shutdown()
        consumeTask.cancel()
    }

    @Test("Phase 5 & G: Graph Cache V4 sidecar metadata enables zero-decode prune and diagnostics")
    func testGraphCacheV4SidecarZeroDecodePruneAndDiagnostics() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r6-graph-\(UUID().uuidString)")
        let cacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        let workspaceDir = tempDir.appendingPathComponent("fake_project", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a dummy file in workspace
        let dummySwift = workspaceDir.appendingPathComponent("App.swift")
        try "func startApp() { print(\"running\") }".write(to: dummySwift, atomically: true, encoding: .utf8)

        let engine = CodebaseGraphEngine(
            cachePolicy: .persistent(cacheDir),
            cacheBudget: GraphCacheBudget(maxTotalBytes: 10 * 1024 * 1024, maxWorkspaceEntries: 2, maxEntryAgeSeconds: 3600)
        )

        // Build index and persist
        _ = await engine.indexWorkspace(workspaceURL: workspaceDir)
        let isIndexed = await engine.isIndexed
        #expect(isIndexed)

        // Verify that BOTH .json and .meta.json exist
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        let bodyFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".meta.json") }
        let metaFiles = files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }

        #expect(bodyFiles.count == 1)
        #expect(metaFiles.count == 1)

        // Verify diagnostics reads from sidecar without decoding full body
        let diag = await engine.cacheDiagnostics()
        #expect(diag.entryCount == 1)
        #expect(diag.totalBytes > 0)
        #expect(diag.orphanCount == 0)

        // Test orphan detection: delete the workspace directory
        try FileManager.default.removeItem(at: workspaceDir)
        let diagAfterDelete = await engine.cacheDiagnostics()
        #expect(diagAfterDelete.orphanCount == 1)

        // Prune: orphan must be purged automatically
        await engine.pruneDiskCache()
        let filesAfterPrune = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        #expect(filesAfterPrune.isEmpty)
    }
}


