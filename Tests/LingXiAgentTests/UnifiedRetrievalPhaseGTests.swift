import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Unified Retrieval Phase G Decision & Hardening Tests")
struct UnifiedRetrievalPhaseGTests {

    // MARK: - 1. 三维 Revision 与系统级观测指标审计 (Audit #46 & #54)

    @Test("Revision: 验证 Workspace / ECore / Index 三维版本流转、Staleness 与 Diagnostics 观测指标")
    func testRevisionTrackingAndStalenessDiagnostics() async throws {
        let registry = UnifiedRetrievalRegistry(providers: [])
        let runtime = RetrievalRuntime(registry: registry)

        // 初始状态验证
        let initialDiag = await runtime.memoryDiagnostics
        #expect(initialDiag.workspaceRevision == 1)
        #expect(initialDiag.ecoreRevision == 1)
        #expect(initialDiag.indexRevision == 0)
        #expect(initialDiag.isStale == true)
        #expect(initialDiag.staleness == 2)
        #expect(initialDiag.status == "uninitialized")

        // 模拟第一次构建并原子生效
        let dummyChunk = RetrievalChunk(
            chunkID: "dummy_1",
            sourceType: .codebaseFile,
            sourceID: "dummy.swift",
            rawSourceHandle: .codebase(path: "dummy.swift", startLine: 1, endLine: 10),
            indexableText: "struct DummyService {}"
        )
        let snapshot1 = BM25IndexSnapshot(chunks: [dummyChunk])
        await runtime.applySnapshot(snapshot1, durationMs: 12.5, revision: 2)

        let freshDiag = await runtime.memoryDiagnostics
        #expect(freshDiag.indexRevision == 2)
        #expect(freshDiag.isStale == false)
        #expect(freshDiag.staleness == 0)
        #expect(freshDiag.hasSnapshot == true)
        #expect(freshDiag.totalSnapshotsBuilt == 1)
        #expect(freshDiag.lastBuildDurationMs == 12.5)

        // 触发 Workspace 变更
        await runtime.markDirty(source: .workspace, autoRebuild: false)
        let wsDirtyDiag = await runtime.memoryDiagnostics
        #expect(wsDirtyDiag.workspaceRevision == 2)
        #expect(wsDirtyDiag.ecoreRevision == 1)
        #expect(wsDirtyDiag.indexRevision == 2)
        #expect(wsDirtyDiag.isStale == true)
        #expect(wsDirtyDiag.staleness == 1)

        // 触发 E-Core 变更
        await runtime.markDirty(source: .ecore, autoRebuild: false)
        let bothDirtyDiag = await runtime.memoryDiagnostics
        #expect(bothDirtyDiag.workspaceRevision == 2)
        #expect(bothDirtyDiag.ecoreRevision == 2)
        #expect(bothDirtyDiag.indexRevision == 2)
        #expect(bothDirtyDiag.isStale == true)
        #expect(bothDirtyDiag.staleness == 2)

        // 模拟第二次构建生效
        let snapshot2 = BM25IndexSnapshot(chunks: [dummyChunk])
        await runtime.applySnapshot(snapshot2, durationMs: 8.0, revision: 4)
        let updatedDiag = await runtime.memoryDiagnostics
        #expect(updatedDiag.indexRevision == 4)
        #expect(updatedDiag.isStale == false)
        #expect(updatedDiag.staleness == 0)
        #expect(updatedDiag.totalSnapshotsBuilt == 2)
    }

    // MARK: - 2. Session Scope 隔离性与跨 Session 检索防泄漏测试 (Audit #47)

    @Test("Session Scope: 严格隔离不同 Session 的 E-Core 输出，杜绝跨会话数据泄漏")
    func testSessionScopeIsolationForECoreChunks() async throws {
        let sessionA = SessionID("session_alpha_123")
        let sessionB = SessionID("session_beta_456")

        let objIDA = try ContextObjectID("obj_secret_A")
        let objIDB = try ContextObjectID("obj_secret_B")

        // 两个会话分别产生包含独有敏感数据的 E-Core 对象切片
        let chunkA = RetrievalChunk(
            chunkID: "ecore:obj_secret_A#0_100",
            sourceType: .ecoreToolResult,
            sourceID: "obj_secret_A",
            rawSourceHandle: .ecore(objectID: objIDA, offsetBytes: 0, lengthBytes: 100),
            indexableText: "CONFIDENTIAL_TOKEN_FOR_ALPHA database password exposed here",
            metadata: ["session_id": sessionA.rawValue]
        )

        let chunkB = RetrievalChunk(
            chunkID: "ecore:obj_secret_B#0_100",
            sourceType: .ecoreToolResult,
            sourceID: "obj_secret_B",
            rawSourceHandle: .ecore(objectID: objIDB, offsetBytes: 0, lengthBytes: 100),
            indexableText: "TOP_SECRET_CREDENTIAL_FOR_BETA private key exposed here",
            metadata: ["session_id": sessionB.rawValue]
        )

        // 公共代码库切片
        let publicCodeChunk = RetrievalChunk(
            chunkID: "code:SharedConfig.swift#L1-L20",
            sourceType: .codebaseFile,
            sourceID: "SharedConfig.swift",
            rawSourceHandle: .codebase(path: "SharedConfig.swift", startLine: 1, endLine: 20),
            indexableText: "struct SharedConfig { static let defaultPort = 8080 }"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunkA, chunkB, publicCodeChunk])

        // 1. Session A 检索：能搜到自己的 Token，绝对搜不到 Session B 的 Token
        let resultsA = snapshot.search(query: "exposed password key", scope: .all, sessionID: sessionA)
        let chunkIDsA = resultsA.map(\.chunk.chunkID)
        #expect(chunkIDsA.contains("ecore:obj_secret_A#0_100"))
        #expect(!chunkIDsA.contains("ecore:obj_secret_B#0_100"))

        // 2. Session B 检索：能搜到自己的 Key，绝对搜不到 Session A 的 Token
        let resultsB = snapshot.search(query: "exposed password key", scope: .all, sessionID: sessionB)
        let chunkIDsB = resultsB.map(\.chunk.chunkID)
        #expect(chunkIDsB.contains("ecore:obj_secret_B#0_100"))
        #expect(!chunkIDsB.contains("ecore:obj_secret_A#0_100"))

        // 3. 不带 sessionID 搜索全局：仅匹配无 session 绑定的公共代码，E-Core 敏感对象全部隐藏
        let publicResults = snapshot.search(query: "exposed password key", scope: .all, sessionID: nil)
        let publicChunkIDs = publicResults.map(\.chunk.chunkID)
        #expect(publicChunkIDs.isEmpty)

        // 4. 公共代码切片对所有 Session 可见
        let codeResultsA = snapshot.search(query: "SharedConfig defaultPort", scope: .all, sessionID: sessionA)
        #expect(codeResultsA.contains(where: { $0.chunk.chunkID == "code:SharedConfig.swift#L1-L20" }))
        let codeResultsB = snapshot.search(query: "SharedConfig defaultPort", scope: .all, sessionID: sessionB)
        #expect(codeResultsB.contains(where: { $0.chunk.chunkID == "code:SharedConfig.swift#L1-L20" }))
    }

    // MARK: - 3. 生产 Tool 注册表与 ToolRuntime 端到端闭环验证 (Audit Phase G)

    @Test("Tool Surface: retrieval_search 在 BuiltInToolProvider 正式注册并在 ToolRuntime 可端到端执行")
    func testRetrievalSearchToolRegistrationAndExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("phase_g_tool_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("Greeter.swift")
        try "class ProductionGreeter { func greet(name: String) -> String { \"Hello, \\(name)\" } }".write(to: sampleFile, atomically: true, encoding: .utf8)

        let workspace = try WorkspaceRoot(path: tempDir.path)
        let toolRegistry = ToolRegistry.builtin(workspace: workspace)

        // 1. 验证 retrieval_search 已在静态 ToolRegistry 中注册
        let tool = toolRegistry.tool(for: RetrievalSearchTool.toolID)
        #expect(tool != nil)
        #expect(tool?.definition.id.rawValue == "retrieval_search")
        #expect(tool?.definition.capability.readOnly == true)

        // 2. 验证 retrieval_search 属于按需租借的 Specialized 工具（保持 15 个 Always-on 核心工具集合精炼）
        #expect(!ToolRuntime.coreToolIDs.contains(RetrievalSearchTool.toolID))
        #expect(toolRegistry.definitions.contains(where: { $0.id == RetrievalSearchTool.toolID }))

        // 3. 构造 ToolRuntime 并执行端到端检索调用
        let permissionEngine = PermissionEngine(defaultDecision: .allow)
        let mutationCoordinator = ToolMutationCoordinator()
        let toolRuntime = ToolRuntime(
            registry: toolRegistry,
            permissions: permissionEngine,
            mutations: mutationCoordinator
        )

        let sessionID = SessionID("session_phase_g_test")
        let callID = ToolCallID("call_retrieval_1")

        // 首次调用：触发预热，返回 warming 状态
        let call = ToolCall(
            callID: callID,
            toolID: ToolID("retrieval_search"),
            arguments: "{\"query\":\"ProductionGreeter greet\"}"
        )

        let firstOutcome = await toolRuntime.execute(call, sessionID: sessionID, projectID: ProjectID("proj"))
        #expect(firstOutcome.success == true)
        #expect(firstOutcome.content.contains("Status: warming"))

        // 等待预热就绪
        if let retrievalTool = tool as? RetrievalSearchTool {
            _ = await retrievalTool.retrievalRuntime.waitForReady(timeoutMs: 5000)
        }

        // 二次调用：就绪后执行，返回命中与 Action Hint 指引
        let secondOutcome = await toolRuntime.execute(call, sessionID: sessionID, projectID: ProjectID("proj"))
        #expect(secondOutcome.success == true)
        #expect(secondOutcome.content.contains("Status: ready"))
        #expect(secondOutcome.content.contains("Found 1 result(s)"))
        #expect(secondOutcome.content.contains("Call read_file"))
        #expect(secondOutcome.content.contains("Greeter.swift"))
    }

    // MARK: - 4. 变更监听钩子连通性测试 (MutationCoordinator & ECoreStore)

    @Test("Hooks: 验证 ToolMutationCoordinator 与 ECoreObjectStore 触发 Invalidation 连通")
    func testMutationCoordinatorAndECoreStoreHooks() async throws {
        let registry = UnifiedRetrievalRegistry(providers: [])
        let runtime = RetrievalRuntime(registry: registry)

        let mutationCoordinator = ToolMutationCoordinator()
        let ecoreStore = ECoreObjectStore()

        // 注册钩子
        await mutationCoordinator.addMutationHook {
            await runtime.markDirty(source: .workspace, autoRebuild: false)
        }
        await ecoreStore.addMutationHook {
            await runtime.markDirty(source: .ecore, autoRebuild: false)
        }

        // 初始 revision
        let initialDiag = await runtime.memoryDiagnostics
        #expect(initialDiag.workspaceRevision == 1)
        #expect(initialDiag.ecoreRevision == 1)

        // 触发 mutation coordinator reconcile
        try await mutationCoordinator.reconcile()
        let afterWsDiag = await runtime.memoryDiagnostics
        #expect(afterWsDiag.workspaceRevision == 2)
        #expect(afterWsDiag.ecoreRevision == 1)

        // 触发 ecore cleanSession
        await ecoreStore.cleanSession(sessionID: SessionID("dummy"))
        // 给轻微异步任务排空时间
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterEcoreDiag = await runtime.memoryDiagnostics
        #expect(afterEcoreDiag.workspaceRevision == 2)
        #expect(afterEcoreDiag.ecoreRevision == 2)
        #expect(afterEcoreDiag.isStale == true)
    }
}
