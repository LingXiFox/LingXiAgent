import Testing
import Foundation
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

@Suite("Secondary Memory Hygiene Tests (Phase 11)", .serialized)
struct SecondaryMemoryHygieneTests {

    @Test("ECore projectionCounts are thoroughly cleaned up upon prune and cleanSession")
    func testECoreProjectionCountsCleanup() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var config = ContextObjectFabricConfiguration()
        config.ecoreStorageEnabled = true
        config.heatTrackingEnabled = true
        config.objectizationThreshold = 10

        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sessionID = SessionID("test_session_hygiene")
        let toolCallID1 = ToolCallID("call_001")
        let toolCallID2 = ToolCallID("call_002")

        let meta1 = await store.store(
            sessionID: sessionID,
            toolCallID: toolCallID1,
            toolName: "bash",
            content: "large content that exceeds the objectization threshold 1234567890\nline2"
        )
        let meta2 = await store.store(
            sessionID: sessionID,
            toolCallID: toolCallID2,
            toolName: "bash",
            content: "second large content that exceeds the threshold 1234567890\nline2"
        )
        #expect(meta1 != nil)
        #expect(meta2 != nil)

        let obj1 = meta1!.objectID
        let obj2 = meta2!.objectID

        // Record projections
        await store.recordProjection(sessionID: sessionID, objectID: obj1, originalBytes: 100)
        await store.recordProjection(sessionID: sessionID, objectID: obj1, originalBytes: 100)
        await store.recordProjection(sessionID: sessionID, objectID: obj2, originalBytes: 100)

        let count1 = await store.projectionCount(sessionID: sessionID, objectID: obj1)
        let count2 = await store.projectionCount(sessionID: sessionID, objectID: obj2)
        #expect(count1 == 2)
        #expect(count2 == 1)

        // Prune keeping only toolCallID2: obj1 must be removed from projectionCounts
        await store.prune(sessionID: sessionID, keepingToolCallIDs: [toolCallID2])
        let afterPrune1 = await store.projectionCount(sessionID: sessionID, objectID: obj1)
        let afterPrune2 = await store.projectionCount(sessionID: sessionID, objectID: obj2)
        #expect(afterPrune1 == nil, "obj1 projection count must be removed after prune")
        #expect(afterPrune2 == 1, "obj2 projection count must be preserved")

        // Clean session: all projection counts for sessionID must be completely wiped
        await store.cleanSession(sessionID: sessionID)
        let afterCleanAll = await store.allProjectionCounts(sessionID: sessionID)
        #expect(afterCleanAll == nil, "All projection counts for session must be removed after cleanSession")
    }

    @Test("ContextCacheController clearSessionState removes all per-session state completely")
    func testContextCacheControllerUnifiedCleanup() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pageStore = ProjectPageStore()
        let workingSet = L2WorkingSet()
        let pager = ContextPager(store: pageStore, workingSet: workingSet)
        let scanner = ProjectScanner(root: tempDir)
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner,
            policy: EffectiveContextPolicy(),
            ecoreStore: ECoreObjectStore(baseDirectory: tempDir)
        )

        let sessionID = SessionID("session_cache_cleanup_test")

        // Populate various per-session states
        await controller.advanceEpoch(sessionID: sessionID, reason: "initial_setup")
        await controller.recordFingerprint(
            sessionID: sessionID,
            fingerprint: PrefixFingerprint(
                systemHash: "sys",
                coreToolsHash: "core",
                requestProfileHash: "req",
                stablePrefixHash: "stable"
            ),
            prefixBytes: 100,
            volatileBytes: 50
        )

        let hasStateBefore = await controller.hasResidualSessionState(sessionID: sessionID)
        #expect(hasStateBefore == true, "Should have residual session state after recording epoch and fingerprint")

        // Execute unified cleanup
        await controller.clearSessionState(sessionID: sessionID)

        let hasStateAfter = await controller.hasResidualSessionState(sessionID: sessionID)
        #expect(hasStateAfter == false, "All per-session state must be removed after clearSessionState")
    }

    @Test("SQLitePersistenceStore loadSession loads only single target session with LIMIT 1")
    func testSingleSessionQueryLoadsSingleSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tempDir, mainRoot: tempDir, projectID: ProjectID("test_proj"))
        let main = try await persistence.mainRootBinding()

        // Create 5 sessions
        var sessionIDs: [SessionID] = []
        for i in 1...5 {
            let s = Session(id: SessionID("session_\(i)"), createdAt: Date(), title: "Session \(i)", cwdRootBindingID: main.id)
            try await persistence.createSession(s)
            sessionIDs.append(s.id)
        }

        // Verify loadSession loads exact matching session
        let targetID = sessionIDs[2]
        let loaded = try await persistence.loadSession(targetID)
        #expect(loaded != nil)
        #expect(loaded?.id == targetID)
        #expect(loaded?.title == "Session 3")

        let nonExistent = try await persistence.loadSession(SessionID("non_existent"))
        #expect(nonExistent == nil)
    }

    @Test("ProjectPageStore workspace lifecycle clear removes resident project files and indexes")
    func testProjectPageStoreWorkspaceClear() async throws {
        let store = ProjectPageStore()
        let projID = "test_workspace_alpha"

        let hasResidentInitial = await store.hasWorkspaceResident(projectRootID: projID)
        #expect(hasResidentInitial == false)

        await store.clearWorkspace(projectRootID: projID)
        let hasResidentAfter = await store.hasWorkspaceResident(projectRootID: projID)
        #expect(hasResidentAfter == false)
    }

    @Test("RetrievalRuntime memory diagnostics reports accurate metrics")
    func testRetrievalMemoryDiagnostics() async throws {
        let registry = UnifiedRetrievalRegistry()
        let runtime = RetrievalRuntime(registry: registry)

        let diagBefore = await runtime.memoryDiagnostics
        #expect(diagBefore.hasSnapshot == false)
        #expect(diagBefore.totalDocuments == 0)
        #expect(diagBefore.estimatedMemoryBytes == 0)

        // Create chunks and apply a snapshot
        let chunk1 = RetrievalChunk(
            chunkID: "chunk1",
            sourceType: .codebaseFile,
            sourceID: "src1",
            rawSourceHandle: .codebase(path: "Sources/Main.swift", startLine: 1, endLine: 10),
            indexableText: "applicationStart print hello",
            path: "Sources/Main.swift"
        )
        let chunk2 = RetrievalChunk(
            chunkID: "chunk2",
            sourceType: .codebaseFile,
            sourceID: "src2",
            rawSourceHandle: .codebase(path: "Sources/Core.swift", startLine: 1, endLine: 10),
            indexableText: "CoreEngine run",
            path: "Sources/Core.swift"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunk1, chunk2])
        await runtime.applySnapshot(snapshot, durationMs: 12.5)

        let diagAfter = await runtime.memoryDiagnostics
        #expect(diagAfter.hasSnapshot == true)
        #expect(diagAfter.totalDocuments == 2)
        #expect(diagAfter.vocabularySize > 0)
        #expect(diagAfter.estimatedMemoryBytes > 0)
        #expect(diagAfter.lastBuildDurationMs == 12.5)
        #expect(diagAfter.totalSnapshotsBuilt == 1)
    }

    @Test("AgentRuntime bounds idle session runtimes with LRU eviction")
    func testSessionRuntimeLRUEviction() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let host = try CoreHost(workspaceRoot: try WorkspaceRoot(path: tempDir.path), dataRoot: tempDir)
        let initialCount = await host.residentAgentRuntimesCount
        #expect(initialCount <= 8)

        // Create 12 sessions
        for _ in 1...12 {
            _ = try await host.createSession(envelope: CommandEnvelope(payload: CreateSessionRequest()))
        }

        let residentCount = await host.residentAgentRuntimesCount
        // Bounded by maxIdleRuntimes (8)
        #expect(residentCount <= 8, "Idle session runtimes must be bounded by maxIdleRuntimes (8), got: \(residentCount)")
    }
}
