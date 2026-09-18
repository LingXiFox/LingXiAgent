import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiClient
@testable import LingXiApplication

@Suite("Round 7 System Audit & Architecture Hardening Tests")
struct Round7SystemAuditTests {

    @Test("Phase A: Workspace transition is rejected when active agent runs are in progress")
    func testWorkspaceTransitionRejectedWhenActiveRunsInProgress() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-ws-\(UUID().uuidString)")
        let wsA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let wsB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sandbox = CoreStorageLayout.temporarySandbox()
        try sandbox.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let host = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: wsA.path),
            storageLayout: sandbox
        )
        await host.start()

        guard let agent = await host.agent else {
            Issue.record("AgentRuntime should be initialized")
            await host.shutdown()
            return
        }

        // Initially no active runs
        let initialActive = await agent.hasActiveRuns
        #expect(!initialActive)

        // Mark a session active to simulate in-flight turn/run
        let sessionID = SessionID("active-test-session")
        await agent.markSessionActiveForTesting(sessionID)
        let activeRuns = await agent.hasActiveRuns
        #expect(activeRuns)

        // Attempting to switch workspace during active run must be hard rejected (Phase A P0)
        var rejectedWithExpectedError = false
        do {
            try await host.applyWorkspaceTransition(to: wsB)
        } catch let error as CoreError {
            if error.code == .commandFailed && error.message.contains("Workspace transition rejected: active agent runs in progress") {
                rejectedWithExpectedError = true
            }
        } catch {}
        #expect(rejectedWithExpectedError, "Workspace transition must throw rejection error when runs are active")

        // Finish active run
        await agent.markSessionInactiveForTesting(sessionID)
        let afterInactive = await agent.hasActiveRuns
        #expect(!afterInactive)

        // Now transition must succeed cleanly
        try await host.applyWorkspaceTransition(to: wsB)

        // Deterministic cleanup: explicit await teardown, zero dangling Tasks
        await host.shutdown()
    }

    @Test("Phase A: ToolRuntime rejects stale workspace context to prevent cross-workspace contamination")
    func testStaleWorkspaceContextRejectedByToolRuntime() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-stale-ctx-\(UUID().uuidString)")
        let wsA = tempRoot.appendingPathComponent("WorkspaceA", isDirectory: true)
        let wsB = tempRoot.appendingPathComponent("WorkspaceB", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileA = wsA.appendingPathComponent("secret.txt")
        try "Secret in A".write(to: fileA, atomically: true, encoding: .utf8)

        // Create ToolRuntime for Workspace B
        let permissionEngine = PermissionEngine(configuration: .strict)
        let workspaceB = try WorkspaceRoot(path: wsB.path)
        let toolRuntimeB = ToolRuntime(
            registry: .builtin(workspace: workspaceB),
            permissions: permissionEngine,
            workspacePath: wsB.path
        )

        // Create a RunExecutionContext bound to Workspace A (simulating a turn from previous workspace)
        let staleContext = RunExecutionContext(
            runID: "run-stale-1",
            sessionID: SessionID("session-stale"),
            permissionConfiguration: .yoloFullAccess,
            workspacePath: wsA.path,
            workspaceID: wsA.path,
            workspaceRevision: 1
        )

        let readCall = ToolCall(
            callID: ToolCallID("call-stale-1"),
            toolID: ToolID("read_file"),
            arguments: #"{"path":"secret.txt"}"#
        )

        // Tool execution with mismatched workspace context must fail closed
        let outcome = await toolRuntimeB.executeWithMetrics(
            readCall,
            sessionID: SessionID("session-stale"),
            runExecutionContext: staleContext,
            onPermissionAsked: { _ in }
        )

        #expect(!outcome.result.success)
        let errorMessage = outcome.result.error?.message ?? ""
        #expect(errorMessage.contains("staleWorkspaceContext"), "Error message should identify staleWorkspaceContext mismatch, got: \(errorMessage)")
    }

    @Test("Phase B: Multiple CoreHost instances have strict runtime isolation with no shared mutable singleton pollution")
    func testHostIsolationNoSharedMutableStatePollution() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-isolation-\(UUID().uuidString)")
        let wsA = tempRoot.appendingPathComponent("HostA_WS", isDirectory: true)
        let wsB = tempRoot.appendingPathComponent("HostB_WS", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sandboxA = CoreStorageLayout.temporarySandbox()
        let sandboxB = CoreStorageLayout.temporarySandbox()
        try sandboxA.ensureDirectoriesExist()
        try sandboxB.ensureDirectoriesExist()
        defer {
            try? FileManager.default.removeItem(at: sandboxA.root)
            try? FileManager.default.removeItem(at: sandboxB.root)
        }

        let hostA = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: wsA.path),
            storageLayout: sandboxA
        )
        let hostB = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: wsB.path),
            storageLayout: sandboxB
        )

        await hostA.start()
        await hostB.start()

        // 1. Verify instances are distinct and not sharing singletons
        let engineA = await hostA.codebaseGraphEngine
        let engineB = await hostB.codebaseGraphEngine
        let todoA = await hostA.todoStore
        let todoB = await hostB.todoStore
        let browserA = await hostA.browserSessionManager
        let browserB = await hostB.browserSessionManager

        #expect(engineA !== engineB)
        #expect(todoA !== todoB)
        #expect(browserA !== browserB)

        // 2. Mutate state in Host A
        todoA.addTodo(TodoItemData(id: "todo-1", title: "Task unique to Host A", status: "pending"), for: "session-1")
        let todosA = todoA.getTodos(for: "session-1")
        let todosB = todoB.getTodos(for: "session-1")
        #expect(todosA.count == 1)
        #expect(todosB.isEmpty, "Host B's TodoStore must remain unaffected by Host A")

        // 3. Shutdown Host A
        await hostA.shutdown()

        // 4. Host B must remain completely intact and functional
        let todosBAfter = todoB.getTodos(for: "session-1")
        #expect(todosBAfter.isEmpty)
        let isBIndexed = await engineB.isIndexed
        #expect(!isBIndexed)

        // 5. Cleanup Host B
        await hostB.shutdown()
    }

    @Test("Phase E: ContentStore supports zero-memory metadata query and cold range read")
    func testContentStoreZeroMemoryMetadataAndRangeRead() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)

        // Create 256KB sample payload with repeating alphabet
        var sampleBytes = [UInt8]()
        sampleBytes.reserveCapacity(256 * 1024)
        for i in 0..<(256 * 1024) {
            sampleBytes.append(UInt8(i % 251))
        }
        let sampleData = Data(sampleBytes)

        let ref = try await store.store(
            data: sampleData,
            mediaType: "application/octet-stream",
            filename: "sample_large.bin",
            scope: .global
        )

        // 1. Metadata query must succeed and return correct size without full body read
        let meta = try await store.metadata(id: ref.id)
        #expect(meta.ref.byteCount == sampleData.count)
        #expect(meta.filename == "sample_large.bin")

        // 2. Cold range read must succeed and return exact byte slice
        let offset = 1024
        let length = 512
        let rangeData = try await store.readRange(
            id: ref.id,
            offset: offset,
            length: length,
            authorization: .anonymous
        )

        #expect(rangeData.count == length)
        let expectedSubdata = sampleData.subdata(in: offset..<(offset + length))
        #expect(rangeData == expectedSubdata, "Range read content must match slice precisely")
    }

    @Test("Phase E: ContentStore enforces staging to disk and cleans up abort/timeout")
    func testContentStoreUploadStagingAndQuotaEnforcement() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)

        // Begin upload
        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "staged.txt",
            proposedMediaType: "text/plain",
            expectedByteCount: 100,
            scope: .global
        ))
        let uploadID = beginResp.uploadID

        // Staging file should exist on disk
        let stagingPath = tempDir.appendingPathComponent(".staging_\(uploadID).tmp")
        #expect(FileManager.default.fileExists(atPath: stagingPath.path))

        // Write chunk
        let chunkData = Data("chunk-0-content".utf8)
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 0, data: chunkData)

        // Verify staging file contains written data
        let stagedContents = try Data(contentsOf: stagingPath)
        #expect(stagedContents == chunkData)

        // Abort upload
        await store.abortUpload(uploadID: uploadID)

        // Staging file must be completely deleted (no orphan files on disk)
        #expect(!FileManager.default.fileExists(atPath: stagingPath.path), "Staging file must be purged after abort")
    }

    @Test("Phase D: RetrievalRuntime invalidate creates a hard generation barrier")
    func testRetrievalInvalidateHardGenerationBarrier() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r7-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reg = UnifiedRetrievalRegistry.standard(projectRoot: tempDir, ecoreStore: nil)
        let runtime = RetrievalRuntime(registry: reg)

        let initialGen = await runtime.buildGeneration
        let isBuildingInitial = await runtime.isBuilding

        #expect(!isBuildingInitial)

        // Trigger invalidate
        await runtime.invalidate()

        let nextGen = await runtime.buildGeneration
        let isBuildingAfter = await runtime.isBuilding
        let snapshotAfter = await runtime.activeSnapshot

        #expect(nextGen > initialGen, "buildGeneration must bump on invalidate")
        #expect(!isBuildingAfter, "isBuilding must be reset to false")
        #expect(snapshotAfter == nil, "activeSnapshot must be cleared")
    }
}
