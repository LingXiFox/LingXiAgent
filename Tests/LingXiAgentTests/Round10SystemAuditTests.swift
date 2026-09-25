import Foundation
import Testing
@testable import LingXiPlatform
@testable import LingXiCore
@testable import LingXiClient
@testable import LingXiProtocol
#if canImport(SwiftUI)
@testable import LingXiFrontendKit
#endif

@Suite("Round 10 System Audit & Hard Gate Integration Tests")
struct Round10SystemAuditTests {

    // MARK: - Phase A: Workspace & Context Authority / E-Core Hook Lifetime

    @Test("Phase A: Workspace transition preserves E-Core storage layout and effective context policy")
    func testWorkspaceTransitionContextAuthorityPreservation() async throws {
        let validTempA = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r10-wsA-\(UUID().uuidString)")
        let validTempB = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r10-wsB-\(UUID().uuidString)")
        let customDataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r10-data-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: validTempA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validTempB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDataRoot, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: validTempA)
            try? FileManager.default.removeItem(at: validTempB)
            try? FileManager.default.removeItem(at: customDataRoot)
        }

        let customLayout = CoreStorageLayout(root: customDataRoot)
        try customLayout.ensureDirectoriesExist()

        try await withTestCoreHost(workspaceRoot: validTempA, storageLayout: customLayout) { host in
            let initialPolicy = await host.effectiveContextPolicy
            let initialECoreDir = await host.ecoreStoreRef.baseDirectory.standardizedFileURL.path

            #expect(initialECoreDir.contains(customDataRoot.standardizedFileURL.path))
            #expect(!initialECoreDir.contains(".lingxiagent/sessions"))

            // 执行 Workspace A -> B 切换
            try await host.applyWorkspaceTransition(to: validTempB)

            let afterPolicy = await host.effectiveContextPolicy
            let afterECoreDir = await host.ecoreStoreRef.baseDirectory.standardizedFileURL.path

            // 核心验收 1: E-Core 存储根目录依然归属于该 Host 的 storageLayout，绝不漂移回全局 ~/.lingxiagent
            #expect(afterECoreDir == initialECoreDir)
            #expect(afterECoreDir.contains(customDataRoot.standardizedFileURL.path))

            // 核心验收 2: EffectiveContextPolicy 完全继承原配置，不被默认构造值静默覆盖
            #expect(afterPolicy == initialPolicy)
        }
    }

    // MARK: - Phase B: ContentStore Production Disk Staging & Robustness

    @Test("Phase B: ContentStore disk staging detects duplicate chunk conflict reliably")
    func testDiskStagingDuplicateChunkConflictDetection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r10-disk-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 使用真实磁盘暂存目录 (production mode)
        let store = ContentStore(storageDirectory: tempDir)

        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "conflict_disk_test.txt",
            proposedMediaType: "text/plain",
            expectedByteCount: 100,
            scope: .global
        ))

        let chunk0A = Data("Chunk 0 original deterministic content payload".utf8)
        try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: chunk0A)

        // 1. 相同分片重传 -> 幂等成功
        try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: chunk0A)

        // 2. 冲突分片重传 -> 真实磁盘模式下必须严格抛出 chunkConflict，消灭假绿灯！
        let chunk0Conflict = Data("Chunk 0 conflicting different content payload".utf8)
        do {
            try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: chunk0Conflict)
            Issue.record("Expected chunkConflict error on conflicting chunk payload in disk staging mode")
        } catch let err as RuntimeError {
            #expect(err.code == "chunkConflict")
        }
    }

    @Test("Phase B: readRange handles potential integer overflow safely without trap")
    func testReadRangeIntegerOverflowSafe() async throws {
        let store = ContentStore()
        let testData = Data("Small payload for overflow testing".utf8)
        let ref = try await store.store(data: testData, scope: .global)

        // offset = 1, length = Int.max -> 绝不允许 Swift trap crash
        let slice = try await store.readRange(id: ref.id, offset: 1, length: Int.max, authorization: .system)
        #expect(slice.count == testData.count - 1)
        #expect(slice == testData.subdata(in: 1..<testData.count))
    }

    @Test("Phase B: ContentStore detects corrupted/truncated content body file")
    func testContentLengthMismatchDetection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r10-len-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)
        let originalData = Data(repeating: 0x42, count: 1024)
        let ref = try await store.store(data: originalData, scope: .global)

        // 人工破坏磁盘正文文件，截断为 256 字节
        let bodyURL = tempDir.appendingPathComponent(ref.id.rawValue)
        let truncatedData = originalData.prefix(256)
        try truncatedData.write(to: bodyURL, options: .atomic)

        // 创建新 store 绕过内存缓存
        let coldStore = ContentStore(storageDirectory: tempDir)
        do {
            _ = try await coldStore.metadata(id: ref.id, authorization: .system)
            Issue.record("Expected contentLengthMismatch error")
        } catch let err as RuntimeError {
            #expect(err.code == "contentLengthMismatch")
        }
    }

    @Test("Phase B: ContentBinaryPayload rejects invalid Base64 string upon decoding")
    func testInvalidBase64ContentPayloadRejected() throws {
        let invalidJSON = "{\"base64Data\": \"This is definitely not valid base64!@#%^&*\"}".data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(ContentBinaryPayload.self, from: invalidJSON)
            Issue.record("Expected decoding failure for corrupted base64 data")
        } catch {
            // Expected DecodingError
        }
    }

    // MARK: - Phase C: VNext IPC Framing & Protocol Constants

    @Test("Phase C: ProtocolConstants defines unified maxFrameBytes")
    func testProtocolConstantsUnifiedFrameBudget() {
        #expect(ProtocolConstants.maxFrameBytes == 32 * 1024 * 1024)
    }

    // MARK: - Phase F: macOS GUI Phase 0 Determinism & Auto-Flush

    #if canImport(SwiftUI)
    @Test("Phase F: RuntimeFrontend produces 100% deterministic state on session and task switching")
    @MainActor
    func testGUIFixtureScenarioDeterminism() {
        let runtime = RuntimeFrontend.preview()

        // 初始状态断言
        #expect(runtime.sidebarModel.selectedSessionID == "sess-1")
        #expect(runtime.conversationModel.sessionID == "sess-1")
        #expect(runtime.conversationModel.activeTask?.state == "running")

        // 切换新会话
        runtime.newSession()
        let newSessionID = runtime.sidebarModel.selectedSessionID
        #expect(newSessionID != "sess-1")
        #expect(runtime.conversationModel.sessionID == newSessionID)

        // 切回初始会话
        runtime.switchSession(id: "sess-1")
        #expect(runtime.sidebarModel.selectedSessionID == "sess-1")
        #expect(runtime.conversationModel.sessionID == "sess-1")
        #expect(runtime.conversationModel.activeTask?.taskID == "task-init")
    }


    @Test("Phase F: ConversationPresentationModel auto-flushes buffered streaming chunks on pause")
    @MainActor
    func testStreamingAutoFlushOnPause() async throws {
        let conversation = ConversationPresentationModel(sessionID: "sess-auto-flush")
        #expect(conversation.items.isEmpty)

        // 写入单个 chunk (进入 buffer，尚未达到 40ms)
        conversation.appendOrUpdateStreamingChunk(chunk: "Hello ")

        // 等待 80ms 让后台定时器自动触发 flush
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(conversation.items.count == 1)
        if case .assistant(let text, let isStreaming) = conversation.items.first?.kind {
            #expect(isStreaming)
            #expect(text == "Hello ")
        } else {
            Issue.record("Expected assistant timeline item with auto-flushed text")
        }

        conversation.finalizeStreaming()
    }
    #endif
}
