import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Round 8 System Audit & Architecture Hardening Tests")
struct Round8SystemAuditTests {

    // MARK: - Phase A: Multi-Host Consumer-Level Isolation

    @Test("Phase A: Multi-Host TodoStore isolation at consumer level (no split-brain via TodoStore.shared)")
    func testMultiHostTodoStoreIsolation() async throws {
        let tempA = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-hostA-\(UUID().uuidString)")
        let tempB = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-hostB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempA)
            try? FileManager.default.removeItem(at: tempB)
        }

        try await withTestCoreHost(workspaceRoot: tempA) { hostA in
            try await withTestCoreHost(workspaceRoot: tempB) { hostB in
                let receiptA = try await hostA.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempA.path)))
                let receiptB = try await hostB.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest(workspace: tempB.path)))
                guard let sessionA = receiptA.result?.sessionID,
                      let sessionB = receiptB.result?.sessionID else {
                    Issue.record("Failed to create sessions on hosts")
                    return
                }

                // Host A's per-host todoStore receives an item
                let todoA = TodoItemData(id: "todo-1", title: "Host A Private Work", status: "open")
                let storeA = await hostA.todoStore
                storeA.addTodo(todoA, for: sessionA.rawValue)

                // Verify Host A snapshot contains todo-1 through consumer SessionCoordinator
                let coordA = try await hostA.coordinator(for: sessionA)
                let snapA = await coordA.todoSnapshot()
                #expect(snapA.count == 1)
                #expect(snapA.first?.title == "Host A Private Work")

                // Verify Host B snapshot is completely empty (zero shared singleton leakage)
                let coordB = try await hostB.coordinator(for: sessionB)
                let snapB = await coordB.todoSnapshot()
                #expect(snapB.isEmpty)
            }
        }
    }

    @Test("Phase A: Multi-Host ProviderActivityRegistry and BrowserSessionManager isolation")
    func testMultiHostActivityAndBrowserIsolation() async throws {
        let tempA = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-actA-\(UUID().uuidString)")
        let tempB = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-actB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempA)
            try? FileManager.default.removeItem(at: tempB)
        }

        try await withTestCoreHost(workspaceRoot: tempA) { hostA in
            try await withTestCoreHost(workspaceRoot: tempB) { hostB in
                let sessionA = SessionID("session-act-a")

                let regA = await hostA.providerActivityRegistry
                let regB = await hostB.providerActivityRegistry

                // Record activity on Host A
                await regA.record(
                    sessionID: sessionA,
                    runID: nil,
                    providerRequestID: "req-host-a-1",
                    state: .requesting,
                    model: "claude-3-opus"
                )

                let activeA = await regA.activeActivities(for: sessionA)
                #expect(activeA.count == 1)
                #expect(activeA.first?.providerRequestID == "req-host-a-1")

                // Host B must have zero activities for sessionA
                let activeB = await regB.activeActivities(for: sessionA)
                #expect(activeB.isEmpty)

                // Verify BrowserSessionManager instance separation
                let bmA = await hostA.browserSessionManager
                let bmB = await hostB.browserSessionManager
                #expect(bmA !== bmB)
            }
        }
    }

    // MARK: - Phase B: Workspace Identity & Stale Context Rejection (A -> B -> A)

    @Test("Phase B: A -> B -> A workspace transition invalidates stale execution context via workspaceRevision barrier")
    func testWorkspaceTransitionABAStaleContextRejection() async throws {
        let tempDirA = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-wsA-\(UUID().uuidString)")
        let tempDirB = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-wsB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirA)
            try? FileManager.default.removeItem(at: tempDirB)
        }

        // Create marker files in A and B
        let fileA = tempDirA.appendingPathComponent("markerA.txt")
        let fileB = tempDirB.appendingPathComponent("markerB.txt")
        try "Content A".write(to: fileA, atomically: true, encoding: .utf8)
        try "Content B".write(to: fileB, atomically: true, encoding: .utf8)

        try await withTestCoreHost(workspaceRoot: tempDirA) { host in
            let initialRevision = await host.currentWorkspaceRevision
            #expect(initialRevision == 1)

            // Step 1: Capture execution context at Revision 1 (Workspace A)
            let staleContextRev1 = RunExecutionContext(
                runID: "run-stale-rev1",
                sessionID: SessionID("session-rev1"),
                permissionConfiguration: .yoloFullAccess,
                workspacePath: tempDirA.path,
                workspaceID: tempDirA.path,
                workspaceRevision: initialRevision
            )

            let toolRuntime = await host.toolRuntimeRef

            // Verify tool execution at Revision 1 works
            let readCall = ToolCall(
                callID: ToolCallID("call-read-a"),
                toolID: ToolID("read_file"),
                arguments: #"{"path":"markerA.txt"}"#
            )
            let outcome1 = await toolRuntime.executeWithMetrics(
                readCall,
                sessionID: SessionID("session-rev1"),
                runExecutionContext: staleContextRev1,
                onPermissionAsked: { _ in }
            )
            #expect(outcome1.result.success)
            #expect(outcome1.result.content.contains("Content A"))

            // Step 2: Transition A -> B (Advances revision to 2)
            try await host.applyWorkspaceTransition(to: tempDirB)
            let rev2 = await host.currentWorkspaceRevision
            #expect(rev2 == 2)

            // Step 3: Transition B -> A (Path is back to tempDirA, but revision advances to 3)
            try await host.applyWorkspaceTransition(to: tempDirA)
            let rev3 = await host.currentWorkspaceRevision
            #expect(rev3 == 3)

            // Step 4: Stale execution context with Revision 1 tries to execute against Workspace A
            // Even though paths match (tempDirA == tempDirA), the revision is stale (1 != 3).
            let currentToolRuntime = await host.toolRuntimeRef
            let outcomeStale = await currentToolRuntime.executeWithMetrics(
                readCall,
                sessionID: SessionID("session-rev1"),
                runExecutionContext: staleContextRev1,
                onPermissionAsked: { _ in }
            )

            #expect(!outcomeStale.result.success)
            let errorMessage = outcomeStale.result.error?.message ?? ""
            #expect(
                errorMessage.contains("staleWorkspaceRevision") || errorMessage.contains("staleWorkspaceContext") || errorMessage.contains("workspaceRevisionMismatch"),
                "Expected stale workspace rejection, got: \(errorMessage)"
            )

            // Step 5: Fresh execution context with Revision 3 succeeds
            let freshContextRev3 = RunExecutionContext(
                runID: "run-fresh-rev3",
                sessionID: SessionID("session-rev3"),
                permissionConfiguration: .yoloFullAccess,
                workspacePath: tempDirA.path,
                workspaceID: tempDirA.path,
                workspaceRevision: rev3
            )
            let outcomeFresh = await currentToolRuntime.executeWithMetrics(
                readCall,
                sessionID: SessionID("session-rev3"),
                runExecutionContext: freshContextRev3,
                onPermissionAsked: { _ in }
            )
            #expect(outcomeFresh.result.success)
            #expect(outcomeFresh.result.content.contains("Content A"))
        }
    }

    // MARK: - Phase B2: Active Subagent / Child Session Blocks Workspace Transition

    @Test("Phase B2: Workspace transition is rejected when active agent run or child session exists")
    func testActiveSubagentBlocksWorkspaceTransition() async throws {
        let tempDirA = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-sub-wsA-\(UUID().uuidString)")
        let tempDirB = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-sub-wsB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirA)
            try? FileManager.default.removeItem(at: tempDirB)
        }

        try await withTestCoreHost(workspaceRoot: tempDirA) { host in
            guard let agent = await host.agent else {
                Issue.record("AgentRuntime must be initialized")
                return
            }

            // Initially no active runs
            let initialActive = await agent.hasActiveRuns
            #expect(!initialActive)

            // Simulate active child run/session
            let childSessionID = SessionID("active-child-subagent")
            await agent.markSessionActiveForTesting(childSessionID)

            // hasActiveRuns must be true
            let hasActive = await agent.hasActiveRuns
            #expect(hasActive)

            // Workspace transition must be rejected
            var rejected = false
            do {
                try await host.applyWorkspaceTransition(to: tempDirB)
            } catch let error as CoreError {
                if error.code == .commandFailed && error.message.contains("Workspace transition rejected: active agent runs in progress") {
                    rejected = true
                }
            }
            #expect(rejected, "Workspace transition must throw rejection error when runs/subagents are active")

            // Finish active child session
            await agent.markSessionInactiveForTesting(childSessionID)
            let hasActiveAfter = await agent.hasActiveRuns
            #expect(!hasActiveAfter)

            // Workspace transition must now succeed
            try await host.applyWorkspaceTransition(to: tempDirB)
            let currentPath = await host.workspaceURL.path
            #expect(currentPath == tempDirB.path)
        }
    }

    // MARK: - Phase C: Retrieval Runtime Stale Generation Barrier

    @Test("Phase C: Stale generation build completion does not clear newer generation build status")
    func testRetrievalStaleGenerationBarrier() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reg = UnifiedRetrievalRegistry.standard(projectRoot: tempDir, ecoreStore: nil)
        let runtime = RetrievalRuntime(registry: reg)

        // Invalidate advances generation
        await runtime.invalidate()
        let gen1 = await runtime.buildGeneration

        // Another invalidate advances generation to gen2
        await runtime.invalidate()
        let gen2 = await runtime.buildGeneration
        #expect(gen2 > gen1)

        // Simulate an old build task from gen1 finishing late:
        let staleSnapshot = BM25IndexSnapshot(chunks: [], config: .standard)
        await runtime.finishSingleFlightBuildForTesting(snapshot: staleSnapshot, generation: gen1, revision: 1)

        // Ensure current generation is intact and stale snapshot is discarded
        let currentGen = await runtime.buildGeneration
        #expect(currentGen == gen2)
        let currentSnap = await runtime.activeSnapshot
        #expect(currentSnap == nil)
    }

    // MARK: - Phase D: ContentStore Strict Sequential Chunk and Data Integrity

    @Test("Phase D: ContentStore rejects out-of-order chunk immediately and handles idempotent retries")
    func testContentStoreSequentialChunkIntegrity() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r8-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)
        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "verified.bin",
            proposedMediaType: "application/octet-stream",
            expectedByteCount: 15,
            scope: .global
        ))
        let uploadID = beginResp.uploadID

        // 1. Chunk 0 arrives: success
        let chunk0 = Data("ABCDE".utf8) // 5 bytes
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 0, data: chunk0)

        // 2. Chunk 2 arrives without Chunk 1: rejected immediately
        let chunk2 = Data("KLMNO".utf8) // 5 bytes
        do {
            try await store.writeChunk(uploadID: uploadID, chunkIndex: 2, data: chunk2)
            Issue.record("Should have rejected chunk 2 because chunk 1 was skipped")
        } catch let err as RuntimeError {
            #expect(err.code == "outOfOrderChunk")
        }

        // 3. Duplicate Chunk 0 arrives (network retry): should be accepted idempotently
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 0, data: chunk0)

        // 4. Chunk 1 arrives in sequence
        let chunk1 = Data("FGHIJ".utf8) // 5 bytes
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 1, data: chunk1)

        // 5. Chunk 2 arrives in sequence
        try await store.writeChunk(uploadID: uploadID, chunkIndex: 2, data: chunk2)

        // 6. Commit upload
        let commitRef = try await store.commitUpload(request: CommitContentUploadRequest(uploadID: uploadID))
        #expect(commitRef.byteCount == 15)

        // 7. Verify persisted content on disk is exact: ABCDEFGHIJKLMNO
        let readData = try await store.read(id: commitRef.id, authorization: ContentAuthorizationContext(sessionID: SessionID("any")))
        let expectedData = Data("ABCDEFGHIJKLMNO".utf8) // 15 bytes
        #expect(readData == expectedData)
    }
}
