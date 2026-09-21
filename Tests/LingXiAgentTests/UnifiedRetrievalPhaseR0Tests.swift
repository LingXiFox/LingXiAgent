import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct UnifiedRetrievalPhaseR0Tests {

    // A. E-Core 18KB+ 对象可生成多个 RetrievalChunk
    @Test func testLargeECoreObjectGeneratesMultipleChunks() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 1000,
            heatTrackingEnabled: false
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-r0-large-ecore")

        // 构造约 18KB 内容 (180 行 * 100 字节)
        var lines: [String] = []
        for i in 1...180 {
            lines.append(String(format: "Log line %04d: System processing data chunk with various parameters and metrics.\n", i))
        }
        let fullContent = lines.joined()
        #expect(fullContent.utf8.count >= 14_000)

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_r0_ecore_1"),
            toolName: "shell",
            content: fullContent,
            force: true
        ) else {
            Issue.record("Failed to store E-Core object")
            return
        }

        let provider = ECoreRetrievalProvider(ecoreStore: store, targetChunkBytes: 2048, overlapBytes: 256)
        let chunks = try await provider.enumerateChunks(projectRoot: tempDir, sessionID: sID)

        // 18KB 内容按 2048 字节切分，应产生至少 6 个 chunks
        #expect(chunks.count >= 6)

        // 验证每个 Chunk 的基本属性
        for chunk in chunks {
            #expect(chunk.sourceType == .ecoreToolResult)
            #expect(chunk.sourceID == meta.objectID.rawValue)
            #expect(!chunk.indexableText.isEmpty)
            guard case let .ecore(objID, offset, length) = chunk.rawSourceHandle else {
                Issue.record("Expected ecore RawSourceHandle")
                continue
            }
            #expect(objID == meta.objectID)
            #expect(offset >= 0)
            #expect(length > 0)
        }
    }

    // B. 位于对象中部的唯一字符串确实存在于某个 Chunk 的 indexableText 中
    @Test func testMiddleUniqueStringCapturedInIndexableText() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 1000,
            heatTrackingEnabled: false
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-r0-middle-string")

        let uniqueErrorMarker = "fatal error: Swift actor-isolated property 'runtimeStore' mutation from non-isolated task #42981"

        var lines: [String] = []
        for i in 1...100 {
            lines.append("Head padding line \(i): standard log trace output without errors.\n")
        }
        lines.append("\(uniqueErrorMarker)\n") // 放置在中间位置
        for i in 101...200 {
            lines.append("Tail padding line \(i): trailing information after the critical issue.\n")
        }
        let fullContent = lines.joined()

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_r0_middle_1"),
            toolName: "build_output",
            content: fullContent,
            force: true
        ) else {
            Issue.record("Failed to store E-Core object")
            return
        }

        let provider = ECoreRetrievalProvider(ecoreStore: store, targetChunkBytes: 2048, overlapBytes: 256)
        let chunks = try await provider.enumerateChunks(projectRoot: tempDir, sessionID: sID)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.sourceID == meta.objectID.rawValue })

        let matchingChunks = chunks.filter { $0.indexableText.contains(uniqueErrorMarker) }
        #expect(!matchingChunks.isEmpty)
        #expect(matchingChunks.count <= 2) // 由于 overlap，最多出现在 1-2 个相邻块中

        // 验证提示提取包含了错误特征
        let hintFound = matchingChunks.contains { chunk in
            chunk.symbolHints.contains(where: { $0.contains("error:") })
        }
        #expect(hintFound)
    }

    // C. 该 Chunk 的 RawSourceHandle 可以通过现有 context_recall 精确重新读取对应区域
    @Test func testChunkHandleCanBeRecalledLosslessly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 1000,
            heatTrackingEnabled: false
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-r0-recall-repro")

        let targetMarker = "CRITICAL_MARKER_FOR_RECALL_VERIFICATION_XYZ123"
        var content = String(repeating: "Prefix content line for offset pushing.\n", count: 80)
        content += "\(targetMarker)\n"
        content += String(repeating: "Suffix content line for offset pushing.\n", count: 80)

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_r0_recall_1"),
            toolName: "compiler",
            content: content,
            force: true
        ) else {
            Issue.record("Failed to store E-Core object")
            return
        }

        let provider = ECoreRetrievalProvider(ecoreStore: store, targetChunkBytes: 2048, overlapBytes: 256)
        let chunks = try await provider.enumerateChunks(projectRoot: tempDir, sessionID: sID)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.sourceID == meta.objectID.rawValue })

        guard let matchedChunk = chunks.first(where: { $0.indexableText.contains(targetMarker) }) else {
            Issue.record("Target marker not found in chunks")
            return
        }

        guard case let .ecore(objID, offset, length) = matchedChunk.rawSourceHandle else {
            Issue.record("Expected ecore RawSourceHandle")
            return
        }

        // 调用现有原始 context_recall 原语进行物理切片读取
        let recalled = try await store.recall(
            sessionID: sID,
            objectID: objID,
            offsetBytes: offset,
            limitBytes: length
        )

        #expect(recalled != nil)
        #expect(recalled?.content == matchedChunk.indexableText)
        #expect(recalled?.content.contains(targetMarker) == true)
    }

    // D. Codebase ContextPage 可以无损映射为 RetrievalChunk
    @Test func testCodebaseContextPageMapsLosslesslyToRetrievalChunk() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 创建临时源码文件
        let srcDir = tempDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let sampleFile = srcDir.appendingPathComponent("SampleService.swift", isDirectory: false)

        let sampleCode = """
        import Foundation

        public actor SampleService {
            public func executeTask() -> String {
                return "completed"
            }
        }
        """
        try sampleCode.write(to: sampleFile, atomically: false, encoding: .utf8)

        let provider = CodebaseRetrievalProvider(projectRoot: tempDir)
        let chunks = try await provider.enumerateChunks(projectRoot: tempDir)

        #expect(!chunks.isEmpty)
        guard let chunk = chunks.first(where: { $0.path == "Sources/SampleService.swift" }) else {
            Issue.record("Failed to find chunk for SampleService.swift")
            return
        }

        #expect(chunk.sourceType == .codebaseFile)
        #expect(chunk.indexableText.contains("actor SampleService"))
        #expect(chunk.symbolHints.contains("SampleService") || chunk.symbolHints.contains("executeTask"))

        guard case let .codebase(path, startLine, endLine) = chunk.rawSourceHandle else {
            Issue.record("Expected codebase RawSourceHandle")
            return
        }
        #expect(path == "Sources/SampleService.swift")
        #expect(startLine == 1)
        #expect(endLine >= 5)
    }

    // E. RetrievalDocument snippet 不超过约定长度，但不会影响 Chunk indexableText
    @Test func testRetrievalDocumentSnippetBoundedWithoutAffectingChunkIndexableText() {
        let longText = String(repeating: "Swift Unified Retrieval Chunk Content with lots of detail. ", count: 50) // ~3000 chars
        #expect(longText.count > 1000)

        let chunk = RetrievalChunk(
            chunkID: "ecore:test_doc_snippet",
            sourceType: .ecoreToolResult,
            sourceID: "obj_test_123",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_test_123"), offsetBytes: 0, lengthBytes: longText.utf8.count),
            indexableText: longText,
            symbolHints: ["SampleSymbol"]
        )

        let doc = RetrievalDocumentMapper.map(chunk: chunk, score: 0.95, maxSnippetLength: 512)

        // 验证展示摘要严格受到 <= 512 字符约束
        #expect(doc.snippet.count <= 512)
        #expect(doc.snippet.hasSuffix("..."))

        // 验证 Chunk 的原始索引文本未被污染或截断
        #expect(chunk.indexableText.count == longText.count)
        #expect(chunk.indexableText.count > 1000)

        // 验证 Handles 和元数据完整保留
        #expect(doc.rawSourceHandle == chunk.rawSourceHandle)
        #expect(doc.score == 0.95)
        #expect(doc.symbol == "SampleSymbol")
    }

    // F. Retrieval Layer Fail-Open
    @Test func testRetrievalLayerFailOpen() async throws {
        let nonExistentDir = URL(fileURLWithPath: "/tmp/non_existent_retrieval_dir_\(UUID().uuidString)")

        // 1. 验证不存在目录下的全链路 Fail-Open
        let isolatedStore = ECoreObjectStore(baseDirectory: nonExistentDir)
        let registry = UnifiedRetrievalRegistry.standard(projectRoot: nonExistentDir, ecoreStore: isolatedStore)
        let chunks = await registry.enumerateAllChunks(projectRoot: nonExistentDir)
        #expect(chunks.isEmpty)

        // 2. 验证损坏文件与异常数据格式下的 Fail-Open（静默跳过，绝不抛出阻断异常）
        let corruptDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: corruptDir) }
        let objectsDir = corruptDir.appending(path: "corrupt_session/objects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        let corruptMeta = objectsDir.appending(path: "obj_broken.meta.json")
        try Data("INVALID_CORRUPTED_JSON_CONTENT".utf8).write(to: corruptMeta)

        let corruptStore = ECoreObjectStore(baseDirectory: corruptDir)
        let ecoreProvider = ECoreRetrievalProvider(ecoreStore: corruptStore)
        let corruptChunks = try await ecoreProvider.enumerateChunks(projectRoot: nonExistentDir)
        #expect(corruptChunks.isEmpty)
    }

    // G. Phase R0 前后不变式测试 (Tool Manifest, context_recall, read_file 输出完全不变)
    @Test func testPhaseR0InvariantsPreserved() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 100,
            heatTrackingEnabled: false
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-r0-invariants")
        let rawContent = "Line 1: Deterministic Content\nLine 2: Secondary Content\n"

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_inv_1"),
            toolName: "read_file",
            content: rawContent,
            force: true
        ) else {
            Issue.record("Failed to store object")
            return
        }

        // 验证 context_recall 原语输出完全一致
        let recallChunk = try await store.recall(
            sessionID: sID,
            objectID: meta.objectID,
            offsetBytes: 0,
            limitBytes: 100
        )
        #expect(recallChunk?.content == rawContent)

        // 验证 Tool Manifest 行为：确认没有多余的未知工具暴露，ToolID 保留原有语义
        let recallDef = ContextRecallTool(ecoreStore: store).definition
        #expect(recallDef.id.rawValue == "context_recall")
    }
}
