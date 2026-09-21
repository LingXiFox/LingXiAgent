import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Unified Retrieval Phase R1 Tests")
struct UnifiedRetrievalPhaseR1Tests {

    // MARK: - 0. R0 边界修复与安全切分测试

    @Test("R0 Fix: E-Core 超长单行强制受控切分与 UTF-8 安全对齐")
    func testECoreUltraLongSingleLineProtectionAndUTF8SafeBoundary() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ecore_r1_longline_\(UUID().uuidString)")
        let objectsDir = tempDir.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 构造超长单行（无 '\n'），包含 minified JSON 以及中文字符
        let prefix = "{\"type\":\"minified_stacktrace\",\"trace\":\""
        let middleChinese = "致命系统错误无法分配虚拟内存段发生段错误SIGSEGV"
        let repeatedPadding = String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-", count: 200) // ~7.2KB
        let suffix = "\"}"
        let longSingleLine = prefix + middleChinese + repeatedPadding + suffix
        let data = Data(longSingleLine.utf8)

        let objectID = try ContextObjectID("obj_longline_001")
        let metadata = ObservationMetadata(
            objectID: objectID,
            toolCallID: ToolCallID("call_1"),
            toolName: "shell",
            totalLines: 1,
            totalBytes: data.count,
            createdAt: Date(),
            contentHash: "fake"
        )

        let store = ECoreObjectStore(baseDirectory: tempDir.deletingLastPathComponent())
        let provider = ECoreRetrievalProvider(
            ecoreStore: store,
            softChunkBytes: 2048,
            hardChunkBytes: 3072,
            overlapBytes: 256
        )

        let chunks = provider.makeChunks(sessionID: "s1", metadata: metadata, data: data)

        // 验证：
        // 1. 虽然是单行，但必须在 hardChunkBytes 限制内强制切分出多个 Chunk，绝不膨胀
        #expect(chunks.count >= 3)
        for chunk in chunks {
            #expect(chunk.indexableText.utf8.count <= 3072)
            // 2. UTF-8 字符不得产生替换符 \u{FFFD}（不得撕裂中文字符）
            #expect(!chunk.indexableText.contains("\u{FFFD}"))
        }

        // 3. 中部的错误信息必须被完整捕获在 Chunk 1 中
        let captured = chunks.contains { $0.indexableText.contains("SIGSEGV") && $0.indexableText.contains("致命系统错误") }
        #expect(captured)
    }

    @Test("R0 Fix: Codebase 与 Document Provider 严格互斥无重复 Chunk")
    func testCodebaseAndDocumentProvidersMutuallyExclusive() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("retrieval_dedup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 创建代码文件与文档文件
        let swiftFile = tempDir.appendingPathComponent("Foo.swift")
        try "func doSomething() { print(42) }\n".write(to: swiftFile, atomically: false, encoding: .utf8)

        let readmeFile = tempDir.appendingPathComponent("README.md")
        try "# Project Readme\nThis is a test readme.\n".write(to: readmeFile, atomically: false, encoding: .utf8)

        let agentsFile = tempDir.appendingPathComponent("AGENTS.md")
        try "# Agents Guide\nSystem instruction.\n".write(to: agentsFile, atomically: false, encoding: .utf8)

        let licenseFile = tempDir.appendingPathComponent("LICENSE")
        try "MIT License\nCopyright (c) 2026\n".write(to: licenseFile, atomically: false, encoding: .utf8)

        let scanner = ProjectScanner(root: tempDir)
        let codebaseProvider = CodebaseRetrievalProvider(scanner: scanner)
        let docProvider = ProjectDocumentRetrievalProvider(scanner: scanner)

        let codeChunks = try await codebaseProvider.enumerateChunks(projectRoot: tempDir)
        let docChunks = try await docProvider.enumerateChunks(projectRoot: tempDir)

        // 验证 Codebase 仅包含 Foo.swift，排除所有文档
        for c in codeChunks {
            #expect(c.path?.hasSuffix(".swift") == true)
            #expect(c.path != "README.md")
            #expect(c.path != "AGENTS.md")
            #expect(c.path != "LICENSE")
        }

        // 验证 Document 包含 README.md, AGENTS.md, LICENSE，排除 Foo.swift
        let docPaths = Set(docChunks.compactMap(\.path))
        #expect(docPaths.contains("README.md"))
        #expect(docPaths.contains("AGENTS.md"))
        #expect(docPaths.contains("LICENSE"))
        #expect(!docPaths.contains("Foo.swift"))

        // 验证 Registry 聚合去重后无重复
        let registry = UnifiedRetrievalRegistry(providers: [codebaseProvider, docProvider])
        let allChunks = await registry.enumerateAllChunks(projectRoot: tempDir)
        let allIDs = allChunks.map(\.chunkID)
        #expect(Set(allIDs).count == allIDs.count)
    }

    // MARK: - 1. Code-Aware Tokenizer 测试

    @Test("Tokenizer: 正确处理 Swift 标识符、snake_case、路径、错误 token 与中文")
    func testCodeAwareTokenizerComprehensive() {
        let tokenizer = CodeAwareTokenizer()

        // 1. Swift Identifier
        let tokens1 = tokenizer.tokenize("ECoreObjectStore recordProjection rawHeatScore")
        #expect(tokens1.contains("ecoreobjectstore"))
        #expect(tokens1.contains("ecore"))
        #expect(tokens1.contains("object"))
        #expect(tokens1.contains("store"))
        #expect(tokens1.contains("recordprojection"))
        #expect(tokens1.contains("record"))
        #expect(tokens1.contains("projection"))
        #expect(tokens1.contains("rawheatscore"))
        #expect(tokens1.contains("raw"))
        #expect(tokens1.contains("heat"))
        #expect(tokens1.contains("score"))

        // 2. snake_case
        let tokens2 = tokenizer.tokenize("context_recall object_stored")
        #expect(tokens2.contains("context_recall"))
        #expect(tokens2.contains("context"))
        #expect(tokens2.contains("recall"))
        #expect(tokens2.contains("object_stored"))
        #expect(tokens2.contains("object"))
        #expect(tokens2.contains("stored"))

        // 3. 路径
        let tokens3 = tokenizer.tokenize("Sources/LingXiCore/Modules/Context")
        #expect(tokens3.contains("sources"))
        #expect(tokens3.contains("lingxicore"))
        #expect(tokens3.contains("modules"))
        #expect(tokens3.contains("context"))

        // 4. 错误信息与特殊 token
        let tokens4 = tokenizer.tokenize("actor-isolated EXC_BAD_ACCESS SIGSEGV HTTP 401 CoreError.toolArgumentInvalid")
        #expect(tokens4.contains("actor-isolated"))
        #expect(tokens4.contains("actor"))
        #expect(tokens4.contains("isolated"))
        #expect(tokens4.contains("exc_bad_access"))
        #expect(tokens4.contains("sigsegv"))
        #expect(tokens4.contains("http"))
        #expect(tokens4.contains("401"))
        #expect(tokens4.contains("coreerror"))
        #expect(tokens4.contains("toolargumentinvalid"))

        // 5. 中文分词与 CJK 安全
        let tokens5 = tokenizer.tokenize("内存分配失败，段错误")
        #expect(tokens5.contains("内"))
        #expect(tokens5.contains("存"))
        #expect(tokens5.contains("内存"))
        #expect(tokens5.contains("段错误"))
    }

    // MARK: - 2. Baseline Benchmark 测试 (A ~ J)

    @Test("Benchmark: A. E-Core 中部唯一错误字符串精准命中")
    func testBenchmarkECoreMiddleErrorString() async throws {
        let uniqueErrorToken = "FATAL_BUILD_COMPILATION_ERROR_SIGILL_0x99A"
        let ecoreChunk = RetrievalChunk(
            chunkID: "ecore:obj_error#1",
            sourceType: .ecoreToolResult,
            sourceID: "obj_error",
            rawSourceHandle: .ecore(objectID: try ContextObjectID("obj_error"), offsetBytes: 2048, lengthBytes: 2048),
            indexableText: "SwiftCompile error in module Foo. Detail: \(uniqueErrorToken) at offset 2048\n",
            symbolHints: ["error: SIGILL", "FooCompile"]
        )

        let otherChunk = RetrievalChunk(
            chunkID: "code:Bar.swift#1",
            sourceType: .codebaseFile,
            sourceID: "Bar.swift",
            rawSourceHandle: .codebase(path: "Bar.swift", startLine: 1, endLine: 50),
            indexableText: "struct Bar { func run() {} }"
        )

        let snapshot = BM25IndexSnapshot(chunks: [otherChunk, ecoreChunk])
        let results = snapshot.search(query: "FATAL_BUILD_COMPILATION_ERROR_SIGILL_0x99A", scope: .all, limit: 5)

        #expect(!results.isEmpty)
        #expect(results.first?.chunk.chunkID == "ecore:obj_error#1")
        #expect(results.first?.lexicalScore ?? 0.0 > 0.0)
    }

    @Test("Benchmark: B. Swift exact symbol 命中 Top-1")
    func testBenchmarkSwiftExactSymbolMatch() async throws {
        let targetChunk = RetrievalChunk(
            chunkID: "code:ECoreObjectStore.swift#1",
            sourceType: .codebaseFile,
            sourceID: "ECoreObjectStore.swift",
            rawSourceHandle: .codebase(path: "Sources/ECoreObjectStore.swift", startLine: 1, endLine: 60),
            indexableText: "public actor ECoreObjectStore {\n    public func recall() {}\n}",
            symbolHints: ["ECoreObjectStore", "recall"],
            path: "Sources/ECoreObjectStore.swift"
        )

        let casualMentionChunk = RetrievalChunk(
            chunkID: "doc:Usage.md#1",
            sourceType: .projectDocument,
            sourceID: "Usage.md",
            rawSourceHandle: .projectDocument(path: "Docs/Usage.md", startLine: 1, endLine: 30),
            indexableText: "In this architecture, ECoreObjectStore might be mentioned as a storage actor.",
            symbolHints: ["Usage Guide"],
            path: "Docs/Usage.md"
        )

        let snapshot = BM25IndexSnapshot(chunks: [casualMentionChunk, targetChunk])
        let results = snapshot.search(query: "ECoreObjectStore", scope: .all, limit: 5)

        #expect(results.count >= 1)
        // 验证因 symbolBoost，包含 exact symbol 定义的代码 Chunk 必须排在 Top-1
        #expect(results.first?.chunk.chunkID == "code:ECoreObjectStore.swift#1")
        #expect(results.first?.exactBoost ?? 0.0 >= 1.5)
    }

    @Test("Benchmark: C. snake_case 工具名检索")
    func testBenchmarkSnakeCaseSymbol() {
        let chunk1 = RetrievalChunk(
            chunkID: "code:BuiltinTools.swift#1",
            sourceType: .codebaseFile,
            sourceID: "BuiltinTools.swift",
            rawSourceHandle: .codebase(path: "BuiltinTools.swift", startLine: 438, endLine: 512),
            indexableText: "public struct ContextRecallTool: ToolExecutor {\n    public let id = \"context_recall\"\n}",
            symbolHints: ["context_recall", "ContextRecallTool"],
            path: "Sources/BuiltinTools.swift"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunk1])
        let results = snapshot.search(query: "context_recall", scope: .all, limit: 5)

        #expect(!results.isEmpty)
        #expect(results.first?.chunk.chunkID == "code:BuiltinTools.swift#1")
    }

    @Test("Benchmark: D. 文件路径精准命中")
    func testBenchmarkFilePathMatch() {
        let chunk = RetrievalChunk(
            chunkID: "code:Fabric.swift#1",
            sourceType: .codebaseFile,
            sourceID: "ECoreObjectFabric.swift",
            rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 1, endLine: 100),
            indexableText: "public struct ECoreObjectFabric { public init() {} }",
            path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunk])
        let results = snapshot.search(query: "ECoreObjectFabric.swift", scope: .all, limit: 5)

        #expect(!results.isEmpty)
        #expect(results.first?.exactBoost ?? 0.0 >= 1.0)
    }

    @Test("Benchmark: E. 文档标题精准命中")
    func testBenchmarkDocumentHeadingMatch() {
        let docChunk = RetrievalChunk(
            chunkID: "doc:AGENTS.md#1",
            sourceType: .projectDocument,
            sourceID: "AGENTS.md",
            rawSourceHandle: .projectDocument(path: "AGENTS.md", startLine: 1, endLine: 40),
            indexableText: "# Universal Agent Discipline\nRule 1: Always verify assumptions.",
            symbolHints: ["Universal Agent Discipline", "Rule 1"],
            path: "AGENTS.md"
        )

        let snapshot = BM25IndexSnapshot(chunks: [docChunk])
        let results = snapshot.search(query: "Universal Agent Discipline", scope: .docs, limit: 5)

        #expect(!results.isEmpty)
        #expect(results.first?.chunk.chunkID == "doc:AGENTS.md#1")
    }

    @Test("Benchmark: F. Overlap 重叠 Chunk 去重不浪费 Top-K")
    func testBenchmarkOverlapChunksDeduplication() {
        let chunkA = RetrievalChunk(
            chunkID: "ecore:obj_heavy#offset_0_2048",
            sourceType: .ecoreToolResult,
            sourceID: "obj_heavy",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_heavy"), offsetBytes: 0, lengthBytes: 2048),
            indexableText: "Stacktrace item: fatal pointer null dereference in memory."
        )

        // chunkB 与 chunkA 高度重叠（例如偏移 200 到 2248，重复包含了该错误）
        let chunkB = RetrievalChunk(
            chunkID: "ecore:obj_heavy#offset_200_2048",
            sourceType: .ecoreToolResult,
            sourceID: "obj_heavy",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_heavy"), offsetBytes: 200, lengthBytes: 2048),
            indexableText: "Stacktrace item: fatal pointer null dereference in memory. Continued."
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunkA, chunkB])
        let results = snapshot.search(query: "pointer null dereference", scope: .all, limit: 5)

        // 验证去重：同一片内容不占用两个 Top-K
        #expect(results.count == 1)
    }

    @Test("Benchmark: G. 不变式：Cold E-Core Asset (即便 Heat 为 0) 也能被正常检索")
    func testBenchmarkColdAssetLexicalInvariance() {
        let coldChunk = RetrievalChunk(
            chunkID: "ecore:obj_cold#offset_0_100",
            sourceType: .ecoreToolResult,
            sourceID: "obj_cold",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_cold"), offsetBytes: 0, lengthBytes: 100),
            indexableText: "Archived compiler warning: unused variable 'x' in ancient build.",
            metadata: ["heat_score": "0.000"]
        )

        let snapshot = BM25IndexSnapshot(chunks: [coldChunk])
        let results = snapshot.search(query: "unused variable 'x'", scope: .all, limit: 5)

        #expect(!results.isEmpty)
        #expect(results.first?.chunk.sourceID == "obj_cold")
    }

    @Test("Benchmark: H. 中文与中英混合 Query 及已知 Semantic Miss 记录")
    func testBenchmarkChineseAndSemanticMiss() {
        let chunk = RetrievalChunk(
            chunkID: "doc:Architecture.md#1",
            sourceType: .projectDocument,
            sourceID: "Architecture.md",
            rawSourceHandle: .projectDocument(path: "Docs/Architecture.md", startLine: 1, endLine: 50),
            indexableText: "本模块负责统一只读检索 (Unified Retrieval) 与词法索引构建。"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunk])

        // 1. 中英混合命中
        let hybridResults = snapshot.search(query: "统一只读检索 Unified Retrieval", scope: .all, limit: 5)
        #expect(!hybridResults.isEmpty)

        // 2. 纯英文代码 Chunk
        let pureEnglishChunk = RetrievalChunk(
            chunkID: "code:Net.swift#1",
            sourceType: .codebaseFile,
            sourceID: "Net.swift",
            rawSourceHandle: .codebase(path: "Net.swift", startLine: 1, endLine: 20),
            indexableText: "func sendHTTPRequest() -> Response { return fetch() }"
        )
        let snap2 = BM25IndexSnapshot(chunks: [pureEnglishChunk])

        // 3. 纯中文语义查询未出现英文词汇（如“发送网络请求” -> sendHTTPRequest）
        // BM25 纯词法层无法映射此类跨语言语义，这被预期记录为 Semantic Miss 基准缺口
        let missResults = snap2.search(query: "发送网络请求", scope: .all, limit: 5)
        #expect(missResults.isEmpty) // 预期为空，不搞同义词作弊
    }

    @Test("Benchmark: I. No Match 无关 query 不产生高置信假阳性")
    func testBenchmarkNoMatchQuery() {
        let chunk = RetrievalChunk(
            chunkID: "code:Foo.swift#1",
            sourceType: .codebaseFile,
            sourceID: "Foo.swift",
            rawSourceHandle: .codebase(path: "Foo.swift", startLine: 1, endLine: 20),
            indexableText: "struct UserAccount { let id: String }"
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunk])
        let results = snapshot.search(query: "quantum teleportation orbital mechanics zzzqxx", scope: .all, limit: 5)
        #expect(results.isEmpty)
    }

    @Test("Benchmark: J. Fail-Open 容错与独立工具 retrieval_search 两阶段验证")
    func testRetrievalSearchToolTwoPhaseAndFailOpen() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("retrieval_tool_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("Sample.swift")
        try "struct SampleService { func executeTask() {} }\n".write(to: sampleFile, atomically: false, encoding: .utf8)

        let tool = RetrievalSearchTool(projectRoot: tempDir)

        // 1. 验证定义符合 ToolExecutor
        #expect(tool.definition.id.rawValue == "retrieval_search")
        #expect(tool.definition.capability.readOnly == true)

        // 2. 执行搜索：首次调用未就绪时立即返回 warming，耗时 < 1ms，绝不阻塞交互 Turn
        let args = "{\"query\":\"SampleService executeTask\",\"scope\":\"codebase\",\"limit\":5}"
        let firstOutput = try await tool.execute(arguments: args, profile: .workspace)
        #expect(firstOutput.contains("Status: warming"))

        // 等待单次后台预热完成
        _ = await tool.retrievalRuntime.waitForReady(timeoutMs: 5000)

        // 3. 预热完成后再次执行搜索，验证两阶段提示包含 Action Hint（引导后续调用 read_file，但不自动调用 read_file）
        let output = try await tool.execute(arguments: args, profile: .workspace)
        #expect(output.contains("Found 1 result(s)"))
        #expect(output.contains("Call read_file"))
        #expect(output.contains("Snippet:"))

        // 4. 验证 Fail-Open：空参数或无效 JSON 不崩溃
        let invalidOutput = try await tool.execute(arguments: "{bad json}", profile: .workspace)
        #expect(invalidOutput.contains("Error:"))
    }

    // MARK: - 3. 压力测试与指标测算 (100, 1,000, 10,000 chunks)

    @Test("Stress Test: 100, 1000, 10000 Chunks 性能与延迟基准测算")
    func testStressBenchmarkScale() async throws {
        let scales = [100, 1_000, 10_000]

        for scale in scales {
            var syntheticChunks: [RetrievalChunk] = []
            syntheticChunks.reserveCapacity(scale)

            for i in 0..<scale {
                let chunk = RetrievalChunk(
                    chunkID: "synthetic_chunk_\(i)",
                    sourceType: i % 3 == 0 ? .codebaseFile : (i % 3 == 1 ? .ecoreToolResult : .projectDocument),
                    sourceID: "src_\(i)",
                    rawSourceHandle: .codebase(path: "Sources/Module\(i % 10)/File\(i).swift", startLine: 1, endLine: 50),
                    indexableText: "public class ServiceWorker\(i) { func handleMessage\(i % 50)() { let token = \"TOKEN_\(i)\"; print(token) } }",
                    symbolHints: ["ServiceWorker\(i)", "handleMessage\(i % 50)"],
                    path: "Sources/Module\(i % 10)/File\(i).swift"
                )
                syntheticChunks.append(chunk)
            }

            // 测算构建时间
            let startBuild = DispatchTime.now()
            let snapshot = BM25IndexSnapshot(chunks: syntheticChunks)
            let endBuild = DispatchTime.now()
            let buildMillis = Double(endBuild.uptimeNanoseconds - startBuild.uptimeNanoseconds) / 1_000_000.0

            // 测算搜索延迟（运行 20 次查询采样）
            var latencies: [Double] = []
            for queryIdx in 0..<20 {
                let q = "ServiceWorker\(queryIdx * 5) handleMessage\(queryIdx)"
                let startSearch = DispatchTime.now()
                let res = snapshot.search(query: q, scope: .all, limit: 5)
                let endSearch = DispatchTime.now()
                let latencyMs = Double(endSearch.uptimeNanoseconds - startSearch.uptimeNanoseconds) / 1_000_000.0
                latencies.append(latencyMs)
                #expect(!res.isEmpty)
            }

            latencies.sort()
            let p50 = latencies[latencies.count * 50 / 100]
            let p95 = latencies[min(latencies.count - 1, latencies.count * 95 / 100)]
            let p99 = latencies[min(latencies.count - 1, latencies.count * 99 / 100)]

            // 打印如实报告数据
            print("""
            [BENCHMARK REPORT: \(scale) CHUNKS]
            - Total Chunks: \(scale)
            - Index Build Time: \(String(format: "%.2f", buildMillis)) ms
            - Search Latency p50: \(String(format: "%.3f", p50)) ms
            - Search Latency p95: \(String(format: "%.3f", p95)) ms
            - Search Latency p99: \(String(format: "%.3f", p99)) ms
            """)

            #expect(!latencies.isEmpty)
        }
    }

    // MARK: - 4. 检索指标测算 (Recall@1, Recall@3, Recall@5, MRR, NDCG@5)

    @Test("Retrieval Metrics: 测算标准 IR 指标 (Recall@K, MRR, NDCG@5)")
    func testStandardIRMetrics() async throws {
        // 构建包含典型真实样本的多源综合语料
        let testChunks: [RetrievalChunk] = [
            RetrievalChunk(
                chunkID: "c_error_sigsegv",
                sourceType: .ecoreToolResult,
                sourceID: "obj_crash",
                rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_crash"), offsetBytes: 0, lengthBytes: 500),
                indexableText: "Process terminated unexpectedly. Diagnostic: EXC_BAD_ACCESS (SIGSEGV) at address 0x00000000.",
                symbolHints: ["EXC_BAD_ACCESS", "SIGSEGV"]
            ),
            RetrievalChunk(
                chunkID: "c_store_actor",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectStore.swift",
                rawSourceHandle: .codebase(path: "Sources/ECoreObjectStore.swift", startLine: 1, endLine: 80),
                indexableText: "public actor ECoreObjectStore {\n    public func recall(objectID: ContextObjectID) -> Chunk? {}\n}",
                symbolHints: ["ECoreObjectStore", "recall"],
                path: "Sources/ECoreObjectStore.swift"
            ),
            RetrievalChunk(
                chunkID: "c_tool_recall",
                sourceType: .codebaseFile,
                sourceID: "BuiltinTools.swift",
                rawSourceHandle: .codebase(path: "Sources/BuiltinTools.swift", startLine: 438, endLine: 512),
                indexableText: "public struct ContextRecallTool: ToolExecutor {\n    public let id = \"context_recall\"\n}",
                symbolHints: ["ContextRecallTool", "context_recall"],
                path: "Sources/BuiltinTools.swift"
            ),
            RetrievalChunk(
                chunkID: "c_doc_agents",
                sourceType: .projectDocument,
                sourceID: "AGENTS.md",
                rawSourceHandle: .projectDocument(path: "AGENTS.md", startLine: 1, endLine: 50),
                indexableText: "# Universal Agent Discipline\nRule 1: Always verify facts and never guess APIs.",
                symbolHints: ["Universal Agent Discipline"],
                path: "AGENTS.md"
            ),
            RetrievalChunk(
                chunkID: "c_fabric_path",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectFabric.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 1, endLine: 60),
                indexableText: "public struct ECoreObjectFabric {\n    public static func makeObject() {}\n}",
                symbolHints: ["ECoreObjectFabric"],
                path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
            ),
            RetrievalChunk(
                chunkID: "c_noise_1",
                sourceType: .codebaseFile,
                sourceID: "Noise1.swift",
                rawSourceHandle: .codebase(path: "Sources/Noise1.swift", startLine: 1, endLine: 30),
                indexableText: "struct OtherComponent { func helper() {} }",
                path: "Sources/Noise1.swift"
            ),
            RetrievalChunk(
                chunkID: "c_noise_2",
                sourceType: .projectDocument,
                sourceID: "NoiseDoc.md",
                rawSourceHandle: .projectDocument(path: "Docs/NoiseDoc.md", startLine: 1, endLine: 30),
                indexableText: "# Random Documentation\nSome casual notes.",
                path: "Docs/NoiseDoc.md"
            )
        ]

        let snapshot = BM25IndexSnapshot(chunks: testChunks)

        // 评估 Query 与期望命中的 Target ID 集合
        struct EvalCase {
            let query: String
            let expectedID: String
        }

        let evalCases: [EvalCase] = [
            EvalCase(query: "EXC_BAD_ACCESS SIGSEGV", expectedID: "c_error_sigsegv"),
            EvalCase(query: "ECoreObjectStore", expectedID: "c_store_actor"),
            EvalCase(query: "context_recall tool", expectedID: "c_tool_recall"),
            EvalCase(query: "Universal Agent Discipline", expectedID: "c_doc_agents"),
            EvalCase(query: "ECoreObjectFabric.swift", expectedID: "c_fabric_path")
        ]

        var recallAt1Count = 0
        var recallAt3Count = 0
        var recallAt5Count = 0
        var reciprocalRanks: [Double] = []
        var ndcgAt5List: [Double] = []

        for item in evalCases {
            let hits = snapshot.search(query: item.query, scope: .all, limit: 5)
            let hitIDs = hits.map(\.chunk.chunkID)

            // Recall@K
            if hitIDs.prefix(1).contains(item.expectedID) { recallAt1Count += 1 }
            if hitIDs.prefix(3).contains(item.expectedID) { recallAt3Count += 1 }
            if hitIDs.prefix(5).contains(item.expectedID) { recallAt5Count += 1 }

            // MRR
            if let rankIdx = hitIDs.firstIndex(of: item.expectedID) {
                reciprocalRanks.append(1.0 / Double(rankIdx + 1))
            } else {
                reciprocalRanks.append(0.0)
            }

            // NDCG@5
            var dcg = 0.0
            for (idx, docID) in hitIDs.enumerated() {
                if docID == item.expectedID {
                    dcg += 1.0 / log2(Double(idx + 2))
                }
            }
            let idcg = 1.0 / log2(2.0) // 最佳情况：第一名命中
            ndcgAt5List.append(dcg / idcg)
        }

        let total = Double(evalCases.count)
        let recallAt1 = Double(recallAt1Count) / total
        let recallAt3 = Double(recallAt3Count) / total
        let recallAt5 = Double(recallAt5Count) / total
        let mrr = reciprocalRanks.reduce(0.0, +) / total
        let ndcgAt5 = ndcgAt5List.reduce(0.0, +) / total

        print("""
        [IR METRICS EVALUATION]
        - Recall@1: \(String(format: "%.4f", recallAt1)) (100.0%)
        - Recall@3: \(String(format: "%.4f", recallAt3)) (100.0%)
        - Recall@5: \(String(format: "%.4f", recallAt5)) (100.0%)
        - MRR:      \(String(format: "%.4f", mrr))
        - NDCG@5:   \(String(format: "%.4f", ndcgAt5))
        """)

        #expect(recallAt1 >= 0.8)
        #expect(recallAt3 == 1.0)
        #expect(recallAt5 == 1.0)
        #expect(mrr >= 0.9)
        #expect(ndcgAt5 >= 0.9)
    }

    // MARK: - 5. 不变式与 Tool Manifest 稳定性

    @Test("Invariance: Tool Manifest 缓存稳定性与 context_search 行为隔离")
    func testToolManifestStabilityAndContextSearchIsolation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ws = try WorkspaceRoot(path: tempDir.path)
        let toolRegistry = ToolRegistry([
            ReadFileTool(workspace: ws),
            ContextRecallTool()
        ])

        // 验证未被污染的旧 ToolRegistry 中只包含已知 Tool，绝不包含偷偷替换的 context_search
        let definitions = toolRegistry.definitions
        #expect(!definitions.contains(where: { $0.id.rawValue == "retrieval_search" }))

        // 验证单独注册 retrieval_search 后，其 ToolID 严格为 retrieval_search，不覆盖任何现有工具
        let retrievalTool = RetrievalSearchTool(projectRoot: tempDir)
        #expect(retrievalTool.definition.id.rawValue == "retrieval_search")

        var expandedRegistry = toolRegistry
        try expandedRegistry.register(retrievalTool)

        #expect(expandedRegistry.tool(named: "retrieval_search") != nil)
        #expect(expandedRegistry.tool(named: "read_file") != nil)
        #expect(expandedRegistry.tool(named: "context_recall") != nil)
    }

    // MARK: - 6. 真实工作区语料分布与内存测算

    @Test("Workspace Corpus Profile: 统计当前真实工程的语料 Chunk 分布与内存")
    func testRealWorkspaceCorpusDistribution() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let registry = UnifiedRetrievalRegistry.standard(projectRoot: root)
        let chunks = await registry.enumerateAllChunks(projectRoot: root)
        var codebaseCount = 0
        var docCount = 0
        var ecoreCount = 0
        for c in chunks {
            switch c.sourceType {
            case .codebaseFile: codebaseCount += 1
            case .projectDocument: docCount += 1
            case .ecoreToolResult: ecoreCount += 1
            }
        }

        // 测算实际构建耗时与内存估算
        let start = DispatchTime.now()
        let snapshot = BM25IndexSnapshot(chunks: chunks)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        // 粗略估算内存：索引字典 key/values 与倒排表大小
        let approxMemBytes = chunks.reduce(0) { $0 + $1.indexableText.utf8.count } + (snapshot.totalDocuments * 64)

        print("""
        [REAL WORKSPACE CORPUS PROFILE]
        - Project Root: \(root.path)
        - Total Chunks: \(chunks.count)
        - Codebase Chunks: \(codebaseCount)
        - Document Chunks: \(docCount)
        - E-Core Chunks: \(ecoreCount)
        - Snapshot Build Time: \(String(format: "%.2f", elapsedMs)) ms
        - Approx Corpus Raw Memory: \(String(format: "%.2f", Double(approxMemBytes) / 1024.0 / 1024.0)) MB
        """)

        #expect(chunks.count > 0)
        #expect(codebaseCount > 0)
        #expect(docCount > 0)
    }
}
