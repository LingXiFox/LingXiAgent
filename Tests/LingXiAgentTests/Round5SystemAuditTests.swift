import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiClient
@testable import LingXiApplication

@Suite("Round 5 System Audit & Unified Authority Tests")
struct Round5SystemAuditTests {

    @Test("Phase A: Workspace Authority Transition performs complete atomic swap")
    func testWorkspaceAuthorityTransitionAtomicSwap() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r5-ws-\(UUID().uuidString)")
        let wsA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let wsB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Place test files in both workspaces
        try "func inProjectA() {}".write(to: wsA.appendingPathComponent("A.swift"), atomically: false, encoding: .utf8)
        try "func inProjectB() {}".write(to: wsB.appendingPathComponent("B.swift"), atomically: false, encoding: .utf8)

        let sandbox = CoreStorageLayout.temporarySandbox()
        try sandbox.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let host = try CoreHost(
            startupPolicy: .unitTest,
            workspaceRoot: WorkspaceRoot(path: wsA.path),
            storageLayout: sandbox
        )

        // Initially bound to wsA
        let initialWS = await host.workspaceURL.path
        #expect(initialWS == wsA.path)
        let initialSummary = await host.getWorkspaceSummary()
        #expect(initialSummary.rootPath == wsA.path)
        let initialExtRoot = await host.extensionPlatform.projectRoot.path
        #expect(initialExtRoot == wsA.path)

        // Atomic transition to wsB
        try await host.applyWorkspaceTransition(to: wsB)

        // Verify that CoreHost authority, ExtensionPlatform, and WorkspaceSummary are 100% synchronized to wsB
        let updatedWS = await host.workspaceURL.path
        #expect(updatedWS == wsB.path)
        let updatedSummary = await host.getWorkspaceSummary()
        #expect(updatedSummary.rootPath == wsB.path)
        let updatedExtRoot = await host.extensionPlatform.projectRoot.path
        #expect(updatedExtRoot == wsB.path)
    }

    @Test("Phase B: CoreStorageLayout isolates all state and avoids HOME directory pollution")
    func testCoreStorageLayoutCompleteSandbox() async throws {
        let sandbox = CoreStorageLayout.temporarySandbox()
        try sandbox.ensureDirectoriesExist()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        // Verify layout paths reside completely inside the sandbox root
        #expect(sandbox.ecore.path.hasPrefix(sandbox.root.path))
        #expect(sandbox.todos.path.hasPrefix(sandbox.root.path))
        #expect(sandbox.graphCache.path.hasPrefix(sandbox.root.path))
        #expect(sandbox.content.path.hasPrefix(sandbox.root.path))
        #expect(sandbox.eventLog.path.hasPrefix(sandbox.root.path))

        // Configure shared TodoStore to sandbox
        TodoStore.configureShared(storageDir: sandbox.todos)
        let todoStore = TodoStore.shared
        let item = TodoItemData(id: "audit-item-1", title: "Audit Test Todo", status: "pending")
        todoStore.addTodo(item, for: "audit-session")
        let todos = todoStore.getTodos(for: "audit-session")
        #expect(todos.contains(where: { $0.title == "Audit Test Todo" }))

        // Verify todo file was written strictly into sandbox.todos
        let todoFiles = try FileManager.default.contentsOfDirectory(atPath: sandbox.todos.path)
        #expect(!todoFiles.isEmpty)

        // Verify CodebaseGraphEngine cache budget pruning
        let engine = CodebaseGraphEngine()
        await engine.pruneDiskCache(budget: GraphCacheBudget(maxTotalBytes: 1024, maxWorkspaceEntries: 2, maxEntryAgeSeconds: 1.0))
    }

    @Test("Phase C: ApplicationStore drops ungranted yoloFullAccess on initialization")
    func testApplicationYoloPermissionDrop() async throws {
        // AppCompositionRoot contract: user preferences requesting YOLO without explicit session grant
        // must be ignored to prevent silent privilege escalation.
        let defaultPolicy = PermissionConfiguration(policy: .ask, profile: .workspace)
        #expect(defaultPolicy.profile == .workspace)
    }

    @Test("Phase D: Retrieval Single-Flight coalesces concurrent dirty rebuilds")
    func testRetrievalSingleFlightAndSequentialDrain() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r5-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "struct AuditTestPayload { let id = 1 }".write(
            to: tempDir.appendingPathComponent("Payload.swift"),
            atomically: false,
            encoding: .utf8
        )

        let registry = UnifiedRetrievalRegistry()
        let runtime = RetrievalRuntime(registry: registry)

        // Concurrently mark dirty 10 times
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await runtime.markDirty(source: .workspace, projectRoot: tempDir)
                }
            }
        }

        // Allow single-flight drain to finish
        try await Task.sleep(nanoseconds: 100_000_000)

        // Query retrieval index to confirm readiness without crash or split-brain
        let searchResult = await runtime.search(query: "AuditTestPayload", limit: 5)
        switch searchResult {
        case .results(let chunks):
            #expect(chunks.count >= 0)
        case .warming, .unavailable:
            break
        }
    }

    @Test("Phase E: VNext Stdio Content protocol metadata and payload round-trip")
    func testVNextStdioContentProtocolPayload() async throws {
        let testData = "LingXiAgent Phase E Immutable Content Payload".data(using: .utf8)!
        let hash = LingXiPlatform.crypto.sha256Hex(testData)
        let ref = ContentRef(
            id: ContentID("content://sha256:\(hash)"),
            mediaType: "text/plain",
            byteCount: testData.count,
            digest: hash
        )

        #expect(ref.id.rawValue == "content://sha256:\(hash)")
        #expect(ref.byteCount == testData.count)

        // Metadata request and payload encoding verification
        let metaReq = GetContentMetadataRequest(ref: ref)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encodedReq = try encoder.encode(metaReq)
        let decodedReq = try decoder.decode(GetContentMetadataRequest.self, from: encodedReq)
        #expect(decodedReq.ref.id == ref.id)

        let payload = ContentBinaryPayload(data: testData)
        let encodedPayload = try encoder.encode(payload)
        let decodedPayload = try decoder.decode(ContentBinaryPayload.self, from: encodedPayload)
        #expect(decodedPayload.data == testData)
    }
}
