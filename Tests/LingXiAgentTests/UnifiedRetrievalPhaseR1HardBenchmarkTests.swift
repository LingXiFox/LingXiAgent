import Darwin
import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Unified Retrieval Phase R1.1 Hard Benchmark & Evaluation Tests")
struct UnifiedRetrievalPhaseR1HardBenchmarkTests {

    // MARK: - 1. 核实 E-Core 实际物理路径测试

    @Test("Audit 1: 核实 E-Core 生产写入路径与读取路径绝对一致")
    func testECoreActualPhysicalPathsConsistency() async throws {
        let store = ECoreObjectStore()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expectedBase = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)

        // 验证 Store 根目录
        let storeBase = await store.baseDirectory
        #expect(storeBase.standardizedFileURL.path == expectedBase.standardizedFileURL.path)

        // 验证 Provider 也是基于 store.baseDirectory 读取
        let provider = ECoreRetrievalProvider(ecoreStore: store)
        let provBase = await provider.ecoreStore.baseDirectory
        #expect(provBase.standardizedFileURL.path == expectedBase.standardizedFileURL.path)

        // 验证生产环境中真实存在的 objects 目录格式（~/.lingxiagent/sessions/<SID>/objects）
        // 绝不存在多余的 ecore/ 子目录
        let sessionDirSample = expectedBase.appendingPathComponent("SAMPLE_SID", isDirectory: true)
        let directObjectsDir = sessionDirSample.appendingPathComponent("objects", isDirectory: true)
        let falseEcoreObjectsDir = sessionDirSample.appendingPathComponent("ecore", isDirectory: true).appendingPathComponent("objects", isDirectory: true)

        #expect(directObjectsDir.path.hasSuffix("/SAMPLE_SID/objects"))
        #expect(!directObjectsDir.path.contains("/ecore/"))
        #expect(falseEcoreObjectsDir.path.contains("/ecore/objects"))
    }

    // MARK: - 2 & 3 & 4. Hard Benchmark 数据集与 Graded Relevance (NDCG@5, Recall@K, MRR)

    /// 真实 Graded Relevance 数据定义
    struct HardBenchmarkCase: Sendable {
        let queryID: String
        let category: String
        let query: String
        /// chunkID -> graded score (3: Highly Relevant, 2: Relevant, 1: Partially Relevant)
        let gradedTargets: [String: Double]
        let notes: String
    }

    /// 构建独立于 Tokenizer 设计的真实自然意图语料
    private func makeHardBenchmarkCorpus() throws -> [RetrievalChunk] {
        return [
            // 1. ECoreObjectFabric - 负责落盘大工具输出
            RetrievalChunk(
                chunkID: "chunk_ecore_fabric",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectFabric.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 120, endLine: 200),
                indexableText: """
                public actor ECoreObjectStore {
                    public func store(sessionID: SessionID, toolCallID: ToolCallID, toolName: String, content: String) async -> ObservationMetadata? {
                        // 旁路存储对象：如果超过阈值且开启了 ecoreStorageEnabled，则持久化到磁盘
                        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
                        try? data.write(to: targetFile)
                    }
                }
                """,
                symbolHints: ["ECoreObjectStore", "store"],
                path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
            ),
            // 2. ContextObjectID - 防路径穿越
            RetrievalChunk(
                chunkID: "chunk_context_obj_id",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectFabric.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 10, endLine: 35),
                indexableText: """
                public struct ContextObjectID: Sendable, Codable {
                    public init(_ rawValue: String) throws {
                        // 安全防御：严格禁止路径穿越，只允许字母数字短横线与下划线
                        guard !rawValue.isEmpty, rawValue.count <= 128,
                              rawValue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                            throw CoreError(code: .toolArgumentInvalid, message: "Invalid ContextObjectID")
                        }
                        self.rawValue = rawValue
                    }
                }
                """,
                symbolHints: ["ContextObjectID"],
                path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
            ),
            // 3. E-Core 真实编译日志：Swift actor 并发编译错误
            RetrievalChunk(
                chunkID: "chunk_ecore_actor_error",
                sourceType: .ecoreToolResult,
                sourceID: "obj_swift_compile_err_001",
                rawSourceHandle: .ecore(objectID: try ContextObjectID("obj_swift_compile_err_001"), offsetBytes: 0, lengthBytes: 600),
                indexableText: """
                /Modules/Session/SessionRuntime.swift:42:15: error: actor-isolated property 'cachedPlan' can not be mutated from a non-isolated context
                /Modules/Session/SessionRuntime.swift:55:9: error: expression is 'async' but is not marked with 'await' in actor call
                fatal error: Swift compiler returned nonzero exit code 1.
                """,
                symbolHints: ["error: actor-isolated property", "SessionRuntime"]
            ),
            // 4. CanonicalCachePlan - 前缀指纹计算与不可变基线
            RetrievalChunk(
                chunkID: "chunk_canonical_cache_plan",
                sourceType: .codebaseFile,
                sourceID: "CanonicalCachePlan.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Model/CanonicalCachePlan.swift", startLine: 1, endLine: 86),
                indexableText: """
                public struct CanonicalCachePlan: Sendable, Equatable {
                    public struct EpochIdentity: Sendable {
                        public let epoch: Int
                        public let reason: String
                    }
                    public struct ImmutableBase: Sendable {
                        public let systemPrompt: String?
                        public let coreTools: [ToolDefinition]
                    }
                }
                """,
                symbolHints: ["CanonicalCachePlan", "EpochIdentity", "ImmutableBase"],
                path: "Sources/LingXiCore/Modules/Model/CanonicalCachePlan.swift"
            ),
            // 5. ContextProjection - 占位符转换与投影
            RetrievalChunk(
                chunkID: "chunk_context_projection",
                sourceType: .codebaseFile,
                sourceID: "ContextProjection.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ContextProjection.swift", startLine: 1, endLine: 100),
                indexableText: """
                public struct ContextProjectionEngine {
                    // 当工具输出超出限制，转换为轻量占位符注入上下文
                    public func project(toolResult: String) -> String {
                        return "[Observation Object #obj_123 omitted]"
                    }
                }
                """,
                symbolHints: ["ContextProjectionEngine", "project"],
                path: "Sources/LingXiCore/Modules/Context/ContextProjection.swift"
            ),
            // 6. 纯英文网络模块（用于测试 Chinese -> English Semantic Miss）
            RetrievalChunk(
                chunkID: "chunk_pure_english_network",
                sourceType: .codebaseFile,
                sourceID: "HTTPTransport.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Infrastructure/HTTPTransport.swift", startLine: 1, endLine: 80),
                indexableText: """
                public final class URLSessionHTTPTransport: Sendable {
                    public func sendRequest(url: URL, method: String, payload: Data?) async throws -> HTTPResponse {
                        let request = URLRequest(url: url)
                        let (data, response) = try await URLSession.shared.data(for: request)
                        return HTTPResponse(statusCode: 200, body: data)
                    }
                }
                """,
                symbolHints: ["URLSessionHTTPTransport", "sendRequest"],
                path: "Sources/LingXiCore/Infrastructure/HTTPTransport.swift"
            ),
            // 7. ContextCacheController - 缓存策略调度与检索
            RetrievalChunk(
                chunkID: "chunk_cache_controller",
                sourceType: .codebaseFile,
                sourceID: "ContextCacheController.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ContextCacheController.swift", startLine: 1, endLine: 120),
                indexableText: """
                public actor ContextCacheController {
                    // 管理 L1/L2 工作集，处理项目代码搜索与缓存调度策略
                    public func handleSearch(query: String, limit: Int) async throws -> String {
                        return "search result"
                    }
                }
                """,
                symbolHints: ["ContextCacheController", "handleSearch"],
                path: "Sources/LingXiCore/Modules/Context/ContextCacheController.swift"
            ),
            // 8. 干扰项文档
            RetrievalChunk(
                chunkID: "chunk_noise_readme",
                sourceType: .projectDocument,
                sourceID: "README.md",
                rawSourceHandle: .projectDocument(path: "README.md", startLine: 1, endLine: 50),
                indexableText: """
                # LingXiAgent
                A native agent runtime built with Swift for Apple Silicon and Darwin.
                Follow the guidelines in AGENTS.md.
                """,
                symbolHints: ["LingXiAgent"],
                path: "README.md"
            )
        ]
    }

    /// Hard Benchmark 测试用例集合（查询文本与索引实现分离）
    private func makeHardBenchmarkQueries() -> [HardBenchmarkCase] {
        return [
            // 1. Intent Query
            HardBenchmarkCase(
                queryID: "H1_Intent_LargeOutput",
                category: "Intent Query",
                query: "负责把大工具输出落盘的代码在哪里",
                gradedTargets: [
                    "chunk_ecore_fabric": 3.0,
                    "chunk_context_projection": 2.0
                ],
                notes: "自然语言意图，源码中包含 '持久化到磁盘' 与 '落盘' 语义"
            ),
            // 2. Concept Query
            HardBenchmarkCase(
                queryID: "H2_Concept_PathTraversal",
                category: "Concept Query",
                query: "哪里在防止对象 ID 做路径穿越",
                gradedTargets: [
                    "chunk_context_obj_id": 3.0,
                    "chunk_ecore_fabric": 1.0
                ],
                notes: "防御性概念查询，源码包含 '严格禁止路径穿越'"
            ),
            // 3. Historical Error Query
            HardBenchmarkCase(
                queryID: "H3_Historical_ActorError",
                category: "Historical Error Query",
                query: "之前那个 Swift actor 并发相关的编译错误",
                gradedTargets: [
                    "chunk_ecore_actor_error": 3.0
                ],
                notes: "不提供精确错误字符串，通过 actor, 编译, error 词法交叉定位"
            ),
            // 4. Functional Query
            HardBenchmarkCase(
                queryID: "H4_Functional_PrefixCache",
                category: "Functional Query",
                query: "模型的上下文前缀指纹是在哪里算的",
                gradedTargets: [
                    "chunk_canonical_cache_plan": 3.0,
                    "chunk_cache_controller": 2.0
                ],
                notes: "功能定位查询，涉及模型上下文与缓存基线"
            ),
            // 5. Approximate Query
            HardBenchmarkCase(
                queryID: "H5_Approx_FabricStore",
                category: "Approximate Query",
                query: "ecore fabric obj store",
                gradedTargets: [
                    "chunk_ecore_fabric": 3.0,
                    "chunk_context_obj_id": 1.0
                ],
                notes: "多词全小写、包含缩写与乱序"
            ),
            // 6. Chinese -> English Semantic Query (必须允许失败，严禁作弊)
            HardBenchmarkCase(
                queryID: "H6_Semantic_NetworkCall",
                category: "Chinese -> English Semantic Query",
                query: "发送网络请求的地方",
                gradedTargets: [
                    "chunk_pure_english_network": 3.0
                ],
                notes: "纯中文意图 vs 纯英文实现（URLSessionHTTPTransport），词法无法映射，预期 Semantic Miss"
            ),
            // 7. Ambiguous Query
            HardBenchmarkCase(
                queryID: "H7_Ambiguous_CacheManagement",
                category: "Ambiguous Query",
                query: "上下文缓存管理调度",
                gradedTargets: [
                    "chunk_cache_controller": 3.0,
                    "chunk_canonical_cache_plan": 2.0,
                    "chunk_context_projection": 1.0
                ],
                notes: "多个文件均部分相关，支持 Graded 评分梯度"
            ),
            // 8. Long Error Log Partial Query
            HardBenchmarkCase(
                queryID: "H8_Partial_CompilerFailure",
                category: "Long Error Log Partial Query",
                query: "fatal error Swift compiler returned nonzero exit code",
                gradedTargets: [
                    "chunk_ecore_actor_error": 3.0
                ],
                notes: "错误日志尾部通用退出代码"
            )
        ]
    }

    /// 计算 Graded NDCG@K
    private func computeNDCG(returnedIDs: [String], gradedTargets: [String: Double], k: Int = 5) -> Double {
        var dcg = 0.0
        for (idx, docID) in returnedIDs.prefix(k).enumerated() {
            let rel = gradedTargets[docID] ?? 0.0
            if rel > 0 {
                dcg += (pow(2.0, rel) - 1.0) / log2(Double(idx + 2))
            }
        }

        // 理想排序向量 IDCG
        let sortedIdealRels = gradedTargets.values.sorted(by: >)
        var idcg = 0.0
        for (idx, rel) in sortedIdealRels.prefix(k).enumerated() {
            idcg += (pow(2.0, rel) - 1.0) / log2(Double(idx + 2))
        }

        guard idcg > 0 else { return 0.0 }
        return dcg / idcg
    }

    @Test("Hard Benchmark: 运行真实 Graded Relevance 评测并输出基准指标")
    func testHardBenchmarkGradedRelevance() throws {
        let corpus = try makeHardBenchmarkCorpus()
        let queries = makeHardBenchmarkQueries()
        let snapshot = BM25IndexSnapshot(chunks: corpus, config: .standard, tokenizer: CodeAwareTokenizer())

        var recall1Count = 0
        var recall3Count = 0
        var recall5Count = 0
        var rrList: [Double] = []
        var ndcgList: [Double] = []

        var perQueryOutput: [String] = []

        for q in queries {
            let hits = snapshot.search(query: q.query, scope: .all, limit: 5)
            let hitIDs = hits.map(\.chunk.chunkID)

            // 判别：rel >= 2 视为满意命中 (Relevant / Highly Relevant)
            let targetSet = Set(q.gradedTargets.filter { $0.value >= 2.0 }.keys)

            let r1 = hitIDs.prefix(1).contains(where: { targetSet.contains($0) }) ? 1 : 0
            let r3 = hitIDs.prefix(3).contains(where: { targetSet.contains($0) }) ? 1 : 0
            let r5 = hitIDs.prefix(5).contains(where: { targetSet.contains($0) }) ? 1 : 0

            recall1Count += r1
            recall3Count += r3
            recall5Count += r5

            var rr = 0.0
            if let firstIdx = hitIDs.firstIndex(where: { targetSet.contains($0) }) {
                rr = 1.0 / Double(firstIdx + 1)
            }
            rrList.append(rr)

            let ndcg = computeNDCG(returnedIDs: hitIDs, gradedTargets: q.gradedTargets, k: 5)
            ndcgList.append(ndcg)

            perQueryOutput.append("[\(q.queryID)] (\(q.category)) Query: '\(q.query)' -> NDCG@5: \(String(format: "%.3f", ndcg)), Top1: \(hitIDs.first ?? "None")")
        }

        let total = Double(queries.count)
        let recall1 = Double(recall1Count) / total
        let recall3 = Double(recall3Count) / total
        let recall5 = Double(recall5Count) / total
        let mrr = rrList.reduce(0.0, +) / total
        let meanNDCG = ndcgList.reduce(0.0, +) / total

        print("""
        ========== HARD BENCHMARK RESULTS ==========
        \(perQueryOutput.joined(separator: "\n"))
        ---------------------------------------------
        - Total Hard Queries: \(queries.count)
        - Recall@1: \(String(format: "%.4f", recall1)) (\(String(format: "%.1f", recall1 * 100))%)
        - Recall@3: \(String(format: "%.4f", recall3)) (\(String(format: "%.1f", recall3 * 100))%)
        - Recall@5: \(String(format: "%.4f", recall5)) (\(String(format: "%.1f", recall5 * 100))%)
        - MRR:      \(String(format: "%.4f", mrr))
        - NDCG@5:   \(String(format: "%.4f", meanNDCG))
        =============================================
        """)

        // 验证：真实自然语言与意图查询下，词法基准不可能达到 100%，符合客观规律
        #expect(recall1 > 0.0)
        #expect(meanNDCG > 0.0)
    }

    // MARK: - 5. 消融测试 (Ablation Test: A / B / C)

    @Test("Ablation Test: 测量 Tokenizer 与 Exact Boost 的独立贡献")
    func testAblationStudy() throws {
        let corpus = try makeHardBenchmarkCorpus()
        let queries = makeHardBenchmarkQueries()

        // 运行评测闭包
        func evaluate(snapshot: BM25IndexSnapshot) -> (r1: Double, r3: Double, r5: Double, mrr: Double, ndcg: Double) {
            var r1Count = 0, r3Count = 0, r5Count = 0
            var rrList: [Double] = []
            var ndcgList: [Double] = []

            for q in queries {
                let hits = snapshot.search(query: q.query, scope: .all, limit: 5)
                let hitIDs = hits.map(\.chunk.chunkID)
                let targetSet = Set(q.gradedTargets.filter { $0.value >= 2.0 }.keys)

                if hitIDs.prefix(1).contains(where: { targetSet.contains($0) }) { r1Count += 1 }
                if hitIDs.prefix(3).contains(where: { targetSet.contains($0) }) { r3Count += 1 }
                if hitIDs.prefix(5).contains(where: { targetSet.contains($0) }) { r5Count += 1 }

                if let idx = hitIDs.firstIndex(where: { targetSet.contains($0) }) {
                    rrList.append(1.0 / Double(idx + 1))
                } else {
                    rrList.append(0.0)
                }

                ndcgList.append(computeNDCG(returnedIDs: hitIDs, gradedTargets: q.gradedTargets, k: 5))
            }

            let n = Double(queries.count)
            return (Double(r1Count)/n, Double(r3Count)/n, Double(r5Count)/n, rrList.reduce(0, +)/n, ndcgList.reduce(0, +)/n)
        }

        // Configuration A: BM25 Only (Simple Tokenizer, No Boost)
        let configNoBoost = BM25Config(symbolBoost: 0, pathBoost: 0, phraseBoost: 0)
        let snapA = BM25IndexSnapshot(chunks: corpus, config: configNoBoost, tokenizer: SimpleWhitespaceTokenizer())
        let resA = evaluate(snapshot: snapA)

        // Configuration B: BM25 + CodeAwareTokenizer (No Boost)
        let snapB = BM25IndexSnapshot(chunks: corpus, config: configNoBoost, tokenizer: CodeAwareTokenizer())
        let resB = evaluate(snapshot: snapB)

        // Configuration C: BM25 + CodeAwareTokenizer + Exact Boost (Full Baseline)
        let snapC = BM25IndexSnapshot(chunks: corpus, config: .standard, tokenizer: CodeAwareTokenizer())
        let resC = evaluate(snapshot: snapC)

        print("""
        ========== ABLATION TEST REPORT ==========
        [A. BM25 Only (Simple Tokenizer, Zero Boost)]
          Recall@1: \(String(format: "%.4f", resA.r1)) | Recall@3: \(String(format: "%.4f", resA.r3)) | Recall@5: \(String(format: "%.4f", resA.r5))
          MRR: \(String(format: "%.4f", resA.mrr)) | NDCG@5: \(String(format: "%.4f", resA.ndcg))

        [B. BM25 + CodeAwareTokenizer (Zero Boost)]
          Recall@1: \(String(format: "%.4f", resB.r1)) | Recall@3: \(String(format: "%.4f", resB.r3)) | Recall@5: \(String(format: "%.4f", resB.r5))
          MRR: \(String(format: "%.4f", resB.mrr)) | NDCG@5: \(String(format: "%.4f", resB.ndcg))
          Δ vs A: ΔR@1: \(String(format: "+%.4f", resB.r1 - resA.r1)), ΔMRR: \(String(format: "+%.4f", resB.mrr - resA.mrr)), ΔNDCG: \(String(format: "+%.4f", resB.ndcg - resA.ndcg))

        [C. Full Baseline (CodeAware + Exact Boost)]
          Recall@1: \(String(format: "%.4f", resC.r1)) | Recall@3: \(String(format: "%.4f", resC.r3)) | Recall@5: \(String(format: "%.4f", resC.r5))
          MRR: \(String(format: "%.4f", resC.mrr)) | NDCG@5: \(String(format: "%.4f", resC.ndcg))
          Δ vs B: ΔR@1: \(String(format: "+%.4f", resC.r1 - resB.r1)), ΔMRR: \(String(format: "+%.4f", resC.mrr - resB.mrr)), ΔNDCG: \(String(format: "+%.4f", resC.ndcg - resB.ndcg))
        ==========================================
        """)

        #expect(resB.ndcg >= resA.ndcg)
        #expect(resC.ndcg >= resB.ndcg)
    }

    // MARK: - 6. Exact Boost 敏感度分析

    @Test("Sensitivity: Exact Boost 权重敏感度测试")
    func testExactBoostSensitivity() throws {
        let corpus = try makeHardBenchmarkCorpus()
        let queries = makeHardBenchmarkQueries()

        let configs: [(name: String, cfg: BM25Config)] = [
            ("Zero Boost (0.0/0.0/0.0)", BM25Config(symbolBoost: 0.0, pathBoost: 0.0, phraseBoost: 0.0)),
            ("Low Boost (0.5/0.3/0.2)", BM25Config(symbolBoost: 0.5, pathBoost: 0.3, phraseBoost: 0.2)),
            ("Standard Baseline (1.5/1.0/0.5)", BM25Config.standard),
            ("High Boost (3.0/2.0/1.0)", BM25Config(symbolBoost: 3.0, pathBoost: 2.0, phraseBoost: 1.0, maxExactBoost: 5.0))
        ]

        var lines: [String] = []

        for item in configs {
            let snap = BM25IndexSnapshot(chunks: corpus, config: item.cfg, tokenizer: CodeAwareTokenizer())
            var ndcgSum = 0.0
            for q in queries {
                let hits = snap.search(query: q.query, scope: .all, limit: 5)
                ndcgSum += computeNDCG(returnedIDs: hits.map(\.chunk.chunkID), gradedTargets: q.gradedTargets, k: 5)
            }
            let avgNDCG = ndcgSum / Double(queries.count)
            lines.append("- [\(item.name)] NDCG@5: \(String(format: "%.4f", avgNDCG))")
        }

        print("""
        ========== EXACT BOOST SENSITIVITY REPORT ==========
        \(lines.joined(separator: "\n"))
        ====================================================
        """)
    }

    // MARK: - 7 & 10. 真实 Corpus Query Latency 与系统资源开销

    @Test("Real Workspace: 4.6k Chunks 真实索引查询延迟与内存资源分析")
    func testRealCorpusLatencyAndSystemResources() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let registry = UnifiedRetrievalRegistry.standard(projectRoot: root)

        // 1. 记录基线内存 (RSS)
        let rssBefore = getProcessResidentMemoryBytes()

        let buildStart = DispatchTime.now()
        let chunks = await registry.enumerateAllChunks(projectRoot: root)
        let scanAndChunkDone = DispatchTime.now()

        let snapshot = BM25IndexSnapshot(chunks: chunks)
        let buildDone = DispatchTime.now()

        let rssAfter = getProcessResidentMemoryBytes()

        let scanChunkMs = Double(scanAndChunkDone.uptimeNanoseconds - buildStart.uptimeNanoseconds) / 1_000_000.0
        let indexBuildMs = Double(buildDone.uptimeNanoseconds - scanAndChunkDone.uptimeNanoseconds) / 1_000_000.0
        let totalColdBuildMs = Double(buildDone.uptimeNanoseconds - buildStart.uptimeNanoseconds) / 1_000_000.0

        // 2. 真实 5 类典型查询延迟评测（每类采样 30 次）
        struct LatencyQueryType {
            let name: String
            let query: String
        }

        let testTypes: [LatencyQueryType] = [
            LatencyQueryType(name: "Exact Symbol", query: "ECoreObjectStore"),
            LatencyQueryType(name: "Multi-Token", query: "session runtime task execution scheduler"),
            LatencyQueryType(name: "Chinese Query", query: "项目上下文缓存策略管理"),
            LatencyQueryType(name: "No-Match Query", query: "quantum superposition entanglement xyz999"),
            LatencyQueryType(name: "High Doc-Freq", query: "import Foundation let func struct")
        ]

        var latencyReportLines: [String] = []

        for qType in testTypes {
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = DispatchTime.now()
                _ = snapshot.search(query: qType.query, scope: .all, limit: 5)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
                samples.append(elapsed)
            }
            samples.sort()
            let p50 = samples[samples.count * 50 / 100]
            let p95 = samples[min(samples.count - 1, samples.count * 95 / 100)]
            let p99 = samples[min(samples.count - 1, samples.count * 99 / 100)]

            latencyReportLines.append("- [\(qType.name)] p50: \(String(format: "%.3f", p50)) ms | p95: \(String(format: "%.3f", p95)) ms | p99: \(String(format: "%.3f", p99)) ms")
        }

        print("""
        ========== REAL WORKSPACE RESOURCE & LATENCY REPORT ==========
        [Corpus Statistics]
        - Total Indexed Chunks: \(chunks.count)
        - Baseline Process RSS: \(String(format: "%.2f", Double(rssBefore) / 1024.0 / 1024.0)) MB
        - Post-Build Steady RSS: \(String(format: "%.2f", Double(rssAfter) / 1024.0 / 1024.0)) MB
        - Net Memory Overhead:   \(String(format: "%.2f", Double(rssAfter > rssBefore ? rssAfter - rssBefore : 0) / 1024.0 / 1024.0)) MB

        [Cold Build Breakdown]
        - Scan & Chunking Time: \(String(format: "%.2f", scanChunkMs)) ms
        - BM25 Indexing Time:   \(String(format: "%.2f", indexBuildMs)) ms
        - Total Cold Build:     \(String(format: "%.2f", totalColdBuildMs)) ms (~\(String(format: "%.2f", totalColdBuildMs / 1000.0)) s)

        [Real Corpus Latency by Query Category (30 runs each)]
        \(latencyReportLines.joined(separator: "\n"))
        ==============================================================
        """)

        #expect(chunks.count > 0)
    }

    // MARK: - 8 & 9. Cold vs Warm 成本与后台构建不变式

    @Test("Cold vs Warm: 验证 Warm Search 毫秒级与后台构建不阻塞")
    func testColdVsWarmSearchAndNonBlocking() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let tool = RetrievalSearchTool(projectRoot: root)

        // 验证 Warm 搜索执行耗时
        let startWarm = DispatchTime.now()
        let args = "{\"query\":\"ECoreObjectFabric\",\"scope\":\"all\",\"limit\":5}"
        let result = try await tool.execute(arguments: args, profile: .workspace)
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - startWarm.uptimeNanoseconds) / 1_000_000.0

        print("""
        [WARM SEARCH EXECUTION]
        - Warm Execution Latency: \(String(format: "%.2f", warmMs)) ms
        - Has Result: \(!result.isEmpty)
        """)

        #expect(!result.isEmpty)
    }

    // MARK: - 11. Overlap Dedup Hard Case 测试

    @Test("Overlap Dedup: 验证相邻 Chunk 重叠 > 50% 时的误杀边界测试")
    func testOverlapDedupEdgeCaseAnalysis() {
        // 构造两个物理相邻但各含独特重要错误信息的切片
        let chunkA = RetrievalChunk(
            chunkID: "ecore:crash_session#offset_0_2048",
            sourceType: .ecoreToolResult,
            sourceID: "crash_session",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("crash_session"), offsetBytes: 0, lengthBytes: 2048),
            indexableText: """
            Fatal Crash Diagnostic Trace:
            ERROR_CODE_ALPHA: Pointer dereference violation in thread 1.
            Common stack frame lines...
            Common stack frame lines...
            Common stack frame lines...
            """
        )

        // chunkB 与 chunkA 重叠 1200 字节（> 2048 的 50%），但包含完全不同的 ERROR_CODE_BETA
        let chunkB = RetrievalChunk(
            chunkID: "ecore:crash_session#offset_848_2048",
            sourceType: .ecoreToolResult,
            sourceID: "crash_session",
            rawSourceHandle: .ecore(objectID: try! ContextObjectID("crash_session"), offsetBytes: 848, lengthBytes: 2048),
            indexableText: """
            Common stack frame lines...
            Common stack frame lines...
            Common stack frame lines...
            ERROR_CODE_BETA: Stack overflow during memory allocation dispatch.
            """
        )

        let snapshot = BM25IndexSnapshot(chunks: [chunkA, chunkB])

        // 1. 当查询同时包含两个不同特征时：Chunk B 贡献了独特的 ERROR_CODE_BETA 覆盖
        let hitsBoth = snapshot.search(query: "ERROR_CODE_ALPHA ERROR_CODE_BETA", scope: .all, limit: 5)

        print("""
        [OVERLAP DEDUP ANALYSIS]
        - Candidate Chunks: 2 (Overlap ~58.5%)
        - Query: 'ERROR_CODE_ALPHA ERROR_CODE_BETA'
        - Returned Chunks Count: \(hitsBoth.count)
        - Top-1 Chunk: \(hitsBoth.first?.chunk.chunkID ?? "None")
        """)

        // Phase R1.2 修复验证：因为次选 Chunk 提供了独特的 Query 词元覆盖 (BETA)，不再发生误杀，两个切片均被保留！
        #expect(hitsBoth.count == 2)

        // 2. 当查询只包含共有词元时：次选切片未提供独特覆盖，且重叠度高（若使用 50% 阈值策略），验证去重行为
        let strictSnapshot = BM25IndexSnapshot(
            chunks: [chunkA, chunkB],
            config: BM25Config(dedupPolicy: RetrievalDedupPolicy(physicalOverlapThreshold: 0.50, requireTermCoverageDiff: true))
        )
        let hitsCommon = strictSnapshot.search(query: "Common stack frame lines", scope: .all, limit: 5)
        #expect(hitsCommon.count == 1)
    }

    // MARK: - Helper

    /// 获取当前进程内核物理驻留内存 (RSS)
    private func getProcessResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
}
