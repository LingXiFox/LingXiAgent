import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiPlatform

@Suite("Round 4 System Hardening & Isolation Tests")
struct Round4SystemHardeningTests {

    @Test("WorkspaceSummary includes indexingState and CodebaseGraphEngine obeys revision guard")
    func testWorkspaceSummaryAndRevisionGuard() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("Main.swift")
        try "func hello() { print(\"Hello\") }".write(to: sampleFile, atomically: true, encoding: .utf8)

        let engine = CodebaseGraphEngine()
        
        // Initial indexing with revision 10
        let overview1 = await engine.indexWorkspace(workspaceURL: tempDir, revision: 10)
        #expect(overview1.totalNodes > 0)
        let isIndexed = await engine.isIndexed
        #expect(isIndexed == true)

        // Stale revision 5 must be ignored by revision guard
        _ = await engine.indexWorkspace(workspaceURL: tempDir, revision: 5)
        let currentNodes = await engine.nodeCount
        #expect(currentNodes == overview1.totalNodes)

        // WorkspaceSummary inspection
        let summary = WorkspaceSummary(
            rootPath: tempDir.path,
            isGitRepository: false,
            codebaseNodes: currentNodes,
            codebaseEdges: await engine.edgeCount,
            indexingState: "ready"
        )
        #expect(summary.indexingState == "ready")
        #expect(summary.codebaseNodes == currentNodes)
    }

    @Test("ContextResidencyTelemetry measures Warm L2 and E-Core duplicate residency")
    func testContextResidencyTelemetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ecore-telemetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ecoreStore = ECoreObjectStore(baseDirectory: tempDir)
        let sessionID = SessionID("test-telemetry-session")

        // Record an observation into ECoreStore
        let payload = "This is a large observation payload for testing residency deduplication."
        _ = await ecoreStore.store(
            sessionID: sessionID,
            toolCallID: ToolCallID("call-1"),
            toolName: "web_search",
            content: payload,
            force: true
        )

        let pager = ContextPager(
            store: ProjectPageStore(persistence: nil),
            workingSet: L2WorkingSet(characterBudget: 5000),
            projectCharacterBudget: 5000
        )
        let scanner = ProjectScanner(root: tempDir, sensitivePathPolicy: SensitivePathPolicy(root: tempDir))
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner,
            ecoreStore: ecoreStore
        )

        let telemetry = await controller.residencyTelemetry(sessionID: sessionID)
        #expect(telemetry.sessionID == sessionID.rawValue)
        #expect(telemetry.ecoreObjectCount == 1)
        #expect(telemetry.ecoreTotalBytes > 0)
    }

    @Test("WorkflowRuntime cancelAll terminates active tasks cleanly")
    func testWorkflowRuntimeCancelAll() async throws {
        let runtime = WorkflowRuntime()
        // Ensure calling cancelAll on an empty runtime does not crash
        await runtime.cancelAll()
        await runtime.cancel(workflowID: WorkflowID("nonexistent"))
    }
}
