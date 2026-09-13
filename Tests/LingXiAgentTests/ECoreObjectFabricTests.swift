import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct ECoreObjectFabricTests {

    @Test func contextObjectIDValidationAndSecurity() {
        // Legal identifiers
        #expect(throws: Never.self) {
            _ = try ContextObjectID("obj_read_file_call123_abc12345")
            _ = try ContextObjectID("valid-id-123_test")
        }

        // Path traversal attempts must be rejected
        #expect(throws: CoreError.self) {
            _ = try ContextObjectID("../secret")
        }
        #expect(throws: CoreError.self) {
            _ = try ContextObjectID("foo/bar")
        }
        #expect(throws: CoreError.self) {
            _ = try ContextObjectID("foo\\bar")
        }
        #expect(throws: CoreError.self) {
            _ = try ContextObjectID("")
        }
    }

    @Test func ecoreObjectStorageOnlyWhenThresholdExceeded() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10_240 // 10KB
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-test-threshold")

        // 1. 小于 10KB 的小输出 -> 默认不存入 E-Core
        let smallContent = String(repeating: "Hello Small World\n", count: 100) // ~1.8KB
        let metaSmall = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_small"),
            toolName: "read_file",
            content: smallContent
        )
        #expect(metaSmall == nil)

        // 2. 大于 10KB 的大输出 -> 旁路存入 E-Core
        let largeLine = "1234567890 1234567890 1234567890 1234567890 1234567890\n" // 51 bytes
        let largeContent = String(repeating: largeLine, count: 300) // ~15.3KB
        let metaLarge = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_large"),
            toolName: "read_file",
            content: largeContent
        )
        #expect(metaLarge != nil)
        #expect(metaLarge?.totalBytes == largeContent.utf8.count)
        #expect(metaLarge?.totalLines == 300)
        #expect(metaLarge?.toolName == "read_file")

        guard let objectID = metaLarge?.objectID else {
            Issue.record("Expected objectID to exist")
            return
        }

        // 验证文件实际存在
        let exists = await store.hasObject(sessionID: sID, objectID: objectID)
        #expect(exists == true)

        // 验证读取内容与原始内容一致
        let fetched = try await store.fetch(sessionID: sID, objectID: objectID)
        #expect(fetched == largeContent)

        // 验证元数据获取
        let metaFetched = await store.metadata(sessionID: sID, objectID: objectID)
        #expect(metaFetched?.contentHash == metaLarge?.contentHash)
    }

    @Test func ecoreRecallSlicing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 1024,
            recallMaxBytes: 4096,
            recallMaxLines: 100
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-recall")

        // 构造 200 行有固定行首标记的内容
        var lines: [String] = []
        for i in 1...200 {
            lines.append("Line \(i): The quick brown fox jumps over the lazy dog.")
        }
        let fullContent = lines.joined(separator: "\n") + "\n"

        let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_recall"),
            toolName: "shell_exec",
            content: fullContent,
            force: true
        )
        guard let objectID = meta?.objectID else {
            Issue.record("Failed to store object")
            return
        }

        // 召回第 1 块：从 0 开始，最多 50 行（每行约 52 字节，4000 字节足够容纳 50 行）
        let chunk1 = try await store.recall(sessionID: sID, objectID: objectID, offsetBytes: 0, limitBytes: 4000, limitLines: 50)
        #expect(chunk1 != nil)
        #expect(chunk1?.startLine == 1)
        #expect(chunk1?.endLine == 50)
        #expect(chunk1?.hasMore == true)
        #expect(chunk1?.content.contains("Line 1:") == true)
        #expect(chunk1?.content.contains("Line 50:") == true)
        #expect(chunk1?.content.contains("Line 51:") == false)

        // 召回第 2 块：从 chunk1 结束的 offset 开始
        guard let nextOffset = chunk1.map({ $0.offsetBytes + $0.lengthBytes }) else { return }
        let chunk2 = try await store.recall(sessionID: sID, objectID: objectID, offsetBytes: nextOffset, limitBytes: 4000, limitLines: 50)
        #expect(chunk2 != nil)
        #expect(chunk2?.startLine == 51)
        #expect(chunk2?.content.contains("Line 51:") == true)
    }

    @Test func ecoreFeatureFlagDisabled() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(ecoreStorageEnabled: false)
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-disabled")

        let largeContent = String(repeating: "Some long content\n", count: 1000)
        let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_disabled"),
            toolName: "read_file",
            content: largeContent
        )
        #expect(meta == nil)
    }
}
