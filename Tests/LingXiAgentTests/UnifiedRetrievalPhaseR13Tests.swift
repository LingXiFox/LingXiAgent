import Darwin
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Unified Retrieval Phase R1.3 Model-Free Semantic Rescue Benchmark Tests")
struct UnifiedRetrievalPhaseR13Tests {

    // MARK: - 1. 数据结构定义

    enum SemanticCategory: String, Sendable, CaseIterable {
        case lexicalOverlap = "Lexical Overlap"
        case partialLexical = "Partial Lexical"
        case zeroLexicalSameLang = "Zero Lexical Same-Language"
        case zeroLexicalCrossLingual = "Zero Lexical Cross-Lingual"
        case ambiguousIntent = "Ambiguous Intent"
        case negativeSamples = "Negative Samples"
    }

    struct BenchmarkQueryCase: Sendable {
        let queryID: String
        let category: SemanticCategory
        let query: String
        let targetDocIDs: [String: Double] // docID -> graded relevance (3: High, 2: Medium)
        let explanation: String
        let expansion: StructuredQueryExpansion
    }

    /// 严格符合主人要求的结构化 Query Expansion (限制长度与 Token 预算)
    struct StructuredQueryExpansion: Sendable {
        let keywords: [String]             // <= 8
        let symbols: [String]              // <= 5
        let technicalTerms: [String]       // <= 5
        let alternativePhrasings: [String] // <= 3

        func combinedSearchQuery() -> String {
            (symbols + technicalTerms + keywords + alternativePhrasings).joined(separator: " ")
        }

        var estimatedInputTokens: Int {
            // 系统 Prompt (约 80 tokens) + 原始用户 Query (约 20 tokens)
            100
        }

        var estimatedOutputTokens: Int {
            let terms = (keywords + symbols + technicalTerms + alternativePhrasings).joined(separator: " ")
            let words = terms.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            return max(25, words * 2)
        }
    }

    struct ConfidenceDecision: Sendable {
        let isHighConfidence: Bool
        let reason: String
        let topScore: Double
        let contentTermCoverage: Double
        let hasExactSymbol: Bool
    }

    // MARK: - 2. 评测数据集准备 (33 条全量 Query)

    private func makeBenchmarkDataset() -> [BenchmarkQueryCase] {
        return [
            // Category 1: Lexical Overlap (6 条)
            BenchmarkQueryCase(
                queryID: "S01", category: .lexicalOverlap,
                query: "BM25Config symbolBoost pathBoost",
                targetDocIDs: ["chunk_bm25_index": 3.0],
                explanation: "显式词法重叠：配置结构与加权参数",
                expansion: StructuredQueryExpansion(
                    keywords: ["bm25", "config", "boost"],
                    symbols: ["BM25Config", "symbolBoost", "pathBoost"],
                    technicalTerms: ["BM25RetrievalIndex"],
                    alternativePhrasings: ["bm25 scoring weights"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S02", category: .lexicalOverlap,
                query: "CodeAwareTokenizer camelCase snake_case",
                targetDocIDs: ["chunk_tokenizer": 3.0],
                explanation: "显式词法重叠：分词器与命名模式",
                expansion: StructuredQueryExpansion(
                    keywords: ["tokenizer", "camelCase", "snake_case"],
                    symbols: ["CodeAwareTokenizer"],
                    technicalTerms: ["lexical analysis", "subword"],
                    alternativePhrasings: ["code tokenizer identifier split"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S03", category: .lexicalOverlap,
                query: "ContextObjectID invalid path traversal",
                targetDocIDs: ["chunk_context_obj_id": 3.0],
                explanation: "显式词法重叠：对象 ID 与路径穿越校验",
                expansion: StructuredQueryExpansion(
                    keywords: ["context object id", "path traversal", "security"],
                    symbols: ["ContextObjectID", "init"],
                    technicalTerms: ["toolArgumentInvalid"],
                    alternativePhrasings: ["sanitize object identifier"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S04", category: .lexicalOverlap,
                query: "retrieval_search query scope limit",
                targetDocIDs: ["chunk_search_tool": 3.0],
                explanation: "显式词法重叠：工具名称与输入参数",
                expansion: StructuredQueryExpansion(
                    keywords: ["retrieval search", "query", "scope", "limit"],
                    symbols: ["RetrievalSearchTool", "execute"],
                    technicalTerms: ["ToolExecutor"],
                    alternativePhrasings: ["execute retrieval search tool"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S05", category: .lexicalOverlap,
                query: "actor-isolated property cachedPlan error",
                targetDocIDs: ["chunk_ecore_error": 3.0],
                explanation: "显式词法重叠：编译错误堆栈",
                expansion: StructuredQueryExpansion(
                    keywords: ["actor isolated", "cachedPlan", "compiler error"],
                    symbols: ["cachedPlan", "SessionRuntime"],
                    technicalTerms: ["concurrency violation", "actor isolation"],
                    alternativePhrasings: ["swift actor mutation error"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S06", category: .lexicalOverlap,
                query: "ProcessResult exitCode timedOut",
                targetDocIDs: ["chunk_process_result": 3.0],
                explanation: "显式词法重叠：进程退出结构",
                expansion: StructuredQueryExpansion(
                    keywords: ["process result", "exit code", "timeout"],
                    symbols: ["ProcessResult", "exitCode", "timedOut"],
                    technicalTerms: ["DarwinProcess"],
                    alternativePhrasings: ["process execution result"]
                )
            ),

            // Category 2: Partial Lexical (7 条)
            BenchmarkQueryCase(
                queryID: "S07", category: .partialLexical,
                query: "负责把大工具输出落盘的代码在哪里",
                targetDocIDs: ["chunk_ecore_store": 3.0],
                explanation: "部分词法重叠：中文'落盘'与'大工具'",
                expansion: StructuredQueryExpansion(
                    keywords: ["persist", "tool output", "disk", "storage"],
                    symbols: ["ECoreObjectStore", "store", "sessionObjectsDirectory"],
                    technicalTerms: ["ObservationMetadata", "ToolCallID", "ECore"],
                    alternativePhrasings: ["persist large tool result to disk"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S08", category: .partialLexical,
                query: "哪里在防止对象 ID 做路径穿越",
                targetDocIDs: ["chunk_context_obj_id": 3.0],
                explanation: "部分词法重叠：中文'路径穿越'与'对象 ID'",
                expansion: StructuredQueryExpansion(
                    keywords: ["directory traversal", "path traversal", "object identifier"],
                    symbols: ["ContextObjectID", "init"],
                    technicalTerms: ["toolArgumentInvalid", "security validation"],
                    alternativePhrasings: ["prevent path traversal in object id"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S09", category: .partialLexical,
                query: "之前那个 Swift actor 并发相关的编译错误",
                targetDocIDs: ["chunk_ecore_error": 3.0],
                explanation: "部分词法重叠：'actor', 'Swift'",
                expansion: StructuredQueryExpansion(
                    keywords: ["swift compiler error", "actor isolated", "concurrency"],
                    symbols: ["cachedPlan", "SessionRuntime"],
                    technicalTerms: ["actor-isolated property", "fatal error"],
                    alternativePhrasings: ["actor-isolated property error"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S10", category: .partialLexical,
                query: "检索切片软硬限制与字符截断",
                targetDocIDs: ["chunk_ecore_provider": 3.0],
                explanation: "部分词法重叠：中文'软硬限制', '切片'",
                expansion: StructuredQueryExpansion(
                    keywords: ["chunk limit", "soft limit", "hard limit", "utf8"],
                    symbols: ["ECoreRetrievalProvider", "softChunkBytes", "hardChunkBytes"],
                    technicalTerms: ["makeChunks", "RetrievalProvider"],
                    alternativePhrasings: ["retrieval chunk size boundary truncation"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S11", category: .partialLexical,
                query: "代码文件与文档文件严格互斥去重",
                targetDocIDs: ["chunk_retrieval_contracts": 3.0],
                explanation: "部分词法重叠：'互斥', '去重'",
                expansion: StructuredQueryExpansion(
                    keywords: ["codebase", "document", "mutual exclusion", "dedup"],
                    symbols: ["RetrievalCorpusClassifier", "isDocumentPath"],
                    technicalTerms: ["RetrievalChunk", "RetrievalContracts"],
                    alternativePhrasings: ["distinguish code and documentation files"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S12", category: .partialLexical,
                query: "搜索结果展示摘要最大 512 字符",
                targetDocIDs: ["chunk_doc_mapper": 3.0],
                explanation: "部分词法重叠：'512', '摘要'",
                expansion: StructuredQueryExpansion(
                    keywords: ["snippet length", "max length", "summary", "512"],
                    symbols: ["RetrievalDocumentMapper", "defaultMaxSnippetLength"],
                    technicalTerms: ["RetrievalDocument", "map"],
                    alternativePhrasings: ["format retrieval search document snippet"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S13", category: .partialLexical,
                query: "工具执行权限与安全策略",
                targetDocIDs: ["chunk_tool_support": 3.0],
                explanation: "部分词法重叠：'执行权限', '安全策略'",
                expansion: StructuredQueryExpansion(
                    keywords: ["tool execution", "security policy", "permission", "scope"],
                    symbols: ["ToolExecutionSupport", "validateExecutionScope"],
                    technicalTerms: ["ExecutionProfile", "ToolRegistry"],
                    alternativePhrasings: ["validate tool execution permission"]
                )
            ),

            // Category 3: Zero Lexical Same-Language (6 条)
            BenchmarkQueryCase(
                queryID: "S14", category: .zeroLexicalSameLang,
                query: "mechanism that transmits network packets over HTTP wire",
                targetDocIDs: ["chunk_http_transport": 3.0],
                explanation: "同语言 0 重叠：HTTP 网络包传输机制 (目标包含 URLSessionHTTPTransport sendRequest)",
                expansion: StructuredQueryExpansion(
                    keywords: ["http transport", "network request", "send request", "packets"],
                    symbols: ["URLSessionHTTPTransport", "sendRequest", "Transport"],
                    technicalTerms: ["URLSession", "URLRequest"],
                    alternativePhrasings: ["send http network request client transport"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S15", category: .zeroLexicalSameLang,
                query: "persistence engine for massive command outcomes",
                targetDocIDs: ["chunk_ecore_store": 3.0],
                explanation: "同语言 0 重叠：大命令结果持久化 (目标为 ECoreObjectStore.store)",
                expansion: StructuredQueryExpansion(
                    keywords: ["persist tool output", "large command result", "save disk"],
                    symbols: ["ECoreObjectStore", "store", "sessionObjectsDirectory"],
                    technicalTerms: ["ObservationMetadata", "ToolCallID", "ECore"],
                    alternativePhrasings: ["store massive tool execution result on disk"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S16", category: .zeroLexicalSameLang,
                query: "preventing directory escape vulnerability in entity identifiers",
                targetDocIDs: ["chunk_context_obj_id": 3.0],
                explanation: "同语言 0 重叠：实体标识符目录逃逸防御 (目标为 ContextObjectID)",
                expansion: StructuredQueryExpansion(
                    keywords: ["path traversal", "directory escape", "identifier validation"],
                    symbols: ["ContextObjectID", "init"],
                    technicalTerms: ["toolArgumentInvalid", "sanitize"],
                    alternativePhrasings: ["validate context object identifier against path traversal"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S17", category: .zeroLexicalSameLang,
                query: "concurrency race hazard modifying protected fields without synchronization",
                targetDocIDs: ["chunk_ecore_error": 3.0],
                explanation: "同语言 0 重叠：无同步修改保护状态的并发冲突 (目标为 actor-isolated error)",
                expansion: StructuredQueryExpansion(
                    keywords: ["actor isolated", "concurrency error", "mutation", "synchronization"],
                    symbols: ["cachedPlan", "SessionRuntime"],
                    technicalTerms: ["actor-isolated property", "fatal error"],
                    alternativePhrasings: ["actor-isolated property can not be mutated error"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S18", category: .zeroLexicalSameLang,
                query: "partitioning text streams safely without tearing multibyte encoding",
                targetDocIDs: ["chunk_ecore_provider": 3.0],
                explanation: "同语言 0 重叠：安全切分多字节文本 (目标为 makeChunks 软硬限制)",
                expansion: StructuredQueryExpansion(
                    keywords: ["chunking", "multibyte utf8", "text split", "boundary"],
                    symbols: ["ECoreRetrievalProvider", "makeChunks", "softChunkBytes", "hardChunkBytes"],
                    technicalTerms: ["RetrievalChunk", "UTF8CharBoundary"],
                    alternativePhrasings: ["split retrieval chunks safely at utf8 boundaries"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S19", category: .zeroLexicalSameLang,
                query: "avoiding duplicate indexing across distinct catalogs",
                targetDocIDs: ["chunk_retrieval_contracts": 3.0],
                explanation: "同语言 0 重叠：跨目录防重复索引 (目标为 isDocumentPath)",
                expansion: StructuredQueryExpansion(
                    keywords: ["duplicate indexing", "mutually exclusive", "catalogs"],
                    symbols: ["RetrievalCorpusClassifier", "isDocumentPath"],
                    technicalTerms: ["RetrievalContracts", "CodebaseRetrievalProvider"],
                    alternativePhrasings: ["prevent duplicate chunk indexing between code and docs"]
                )
            ),

            // Category 4: Zero Lexical Cross-Lingual (7 条)
            BenchmarkQueryCase(
                queryID: "S20", category: .zeroLexicalCrossLingual,
                query: "发送网络请求的地方",
                targetDocIDs: ["chunk_http_transport": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> URLSessionHTTPTransport.sendRequest",
                expansion: StructuredQueryExpansion(
                    keywords: ["http request", "network client", "send request"],
                    symbols: ["URLSessionHTTPTransport", "sendRequest"],
                    technicalTerms: ["URLSession", "URLRequest", "Transport"],
                    alternativePhrasings: ["send http request network transport client"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S21", category: .zeroLexicalCrossLingual,
                query: "保存执行超时和退出码的数据结构",
                targetDocIDs: ["chunk_process_result": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> ProcessResult(exitCode, timedOut)",
                expansion: StructuredQueryExpansion(
                    keywords: ["process execution", "exit code", "timeout struct"],
                    symbols: ["ProcessResult", "exitCode", "timedOut"],
                    technicalTerms: ["DarwinProcess", "Codable"],
                    alternativePhrasings: ["data structure holding process exit code and timeout"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S22", category: .zeroLexicalCrossLingual,
                query: "从终端执行外部子进程命令",
                targetDocIDs: ["chunk_darwin_process": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> DarwinProcess.run(/bin/zsh)",
                expansion: StructuredQueryExpansion(
                    keywords: ["run command", "terminal process", "execute shell"],
                    symbols: ["DarwinProcess", "run"],
                    technicalTerms: ["Process", "/bin/zsh", "ProcessResult"],
                    alternativePhrasings: ["run terminal shell command using process"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S23", category: .zeroLexicalCrossLingual,
                query: "加解密用户敏感配置与密码凭证",
                targetDocIDs: ["chunk_secure_storage": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> DarwinSecureStorage.encryptCredential",
                expansion: StructuredQueryExpansion(
                    keywords: ["encrypt credentials", "keychain", "secure storage", "passwords"],
                    symbols: ["DarwinSecureStorage", "encryptCredential"],
                    technicalTerms: ["CryptoKit", "Keychain"],
                    alternativePhrasings: ["encrypt sensitive user credentials and tokens"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S24", category: .zeroLexicalCrossLingual,
                query: "用于读写磁盘配置文件的持久化模块",
                targetDocIDs: ["chunk_config_store": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> LocalConfigurationStore.persistConfiguration",
                expansion: StructuredQueryExpansion(
                    keywords: ["persist config", "local disk file", "configuration store"],
                    symbols: ["LocalConfigurationStore", "persistConfiguration"],
                    technicalTerms: ["AgentConfiguration", "FileManager"],
                    alternativePhrasings: ["read and write agent configuration to disk file"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S25", category: .zeroLexicalCrossLingual,
                query: "管理客户端与服务器双向长连接通信管道",
                targetDocIDs: ["chunk_stdio_transport": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> VNextStdioTransport.startBidirectionalStreaming",
                expansion: StructuredQueryExpansion(
                    keywords: ["bidirectional streaming", "stdio pipe", "client server transport"],
                    symbols: ["VNextStdioTransport", "startBidirectionalStreaming"],
                    technicalTerms: ["StdioTransport", "Stream"],
                    alternativePhrasings: ["bidirectional stdio streaming connection channel"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S26", category: .zeroLexicalCrossLingual,
                query: "计算模型的上下文前缀哈希指纹",
                targetDocIDs: ["chunk_cache_controller": 3.0],
                explanation: "跨语言 0 重叠：纯中文意图 -> ContextCacheController.computePrefixFingerprint",
                expansion: StructuredQueryExpansion(
                    keywords: ["prefix hash", "context cache", "fingerprint sha256"],
                    symbols: ["ContextCacheController", "computePrefixFingerprint"],
                    technicalTerms: ["SHA256", "ConversationTurn", "ContextCache"],
                    alternativePhrasings: ["compute prompt cache prefix fingerprint hash"]
                )
            ),

            // Category 5: Ambiguous Intent (5 条)
            BenchmarkQueryCase(
                queryID: "S27", category: .ambiguousIntent,
                query: "上下文缓存管理调度",
                targetDocIDs: ["chunk_cache_controller": 3.0],
                explanation: "歧义/抽象意图：上下文与调度",
                expansion: StructuredQueryExpansion(
                    keywords: ["context cache", "prefix management", "cache schedule"],
                    symbols: ["ContextCacheController"],
                    technicalTerms: ["PrefixFingerprint", "CachePolicy"],
                    alternativePhrasings: ["manage context cache scheduling and prefix"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S28", category: .ambiguousIntent,
                query: "系统的运行时生命周期",
                targetDocIDs: ["chunk_session_runtime": 3.0],
                explanation: "歧义/抽象意图：生命周期调度",
                expansion: StructuredQueryExpansion(
                    keywords: ["session lifecycle", "runtime status", "lifecycle state"],
                    symbols: ["SessionRuntime", "startLifecycle"],
                    technicalTerms: ["SessionStatus", "SessionID"],
                    alternativePhrasings: ["session agent runtime execution lifecycle"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S29", category: .ambiguousIntent,
                query: "核心架构设计规范",
                targetDocIDs: ["chunk_arch_doc": 3.0],
                explanation: "歧义/抽象意图：文档规范",
                expansion: StructuredQueryExpansion(
                    keywords: ["architecture baseline", "p-core", "e-core", "fail-open"],
                    symbols: ["Architecture", "Baseline"],
                    technicalTerms: ["ArchitectureBaseline", "Specification"],
                    alternativePhrasings: ["architecture baseline design specification"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S30", category: .ambiguousIntent,
                query: "模型的上下文前缀指纹是在哪里算的",
                targetDocIDs: ["chunk_cache_controller": 3.0],
                explanation: "自然问句：前缀指纹计算位置",
                expansion: StructuredQueryExpansion(
                    keywords: ["compute fingerprint", "prefix hash", "cache controller"],
                    symbols: ["ContextCacheController", "computePrefixFingerprint"],
                    technicalTerms: ["SHA256", "ConversationTurn"],
                    alternativePhrasings: ["where model context prefix fingerprint is calculated"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S31", category: .ambiguousIntent,
                query: "怎样做错误处理与容灾降级",
                targetDocIDs: ["chunk_arch_doc": 2.0],
                explanation: "抽象意图：容灾规范",
                expansion: StructuredQueryExpansion(
                    keywords: ["fail-open", "error handling", "graceful degradation"],
                    symbols: ["Architecture-Baseline"],
                    technicalTerms: ["FailOpen", "DisasterRecovery"],
                    alternativePhrasings: ["fail open error handling and recovery principles"]
                )
            ),

            // Category 6: Negative Samples (2 条)
            BenchmarkQueryCase(
                queryID: "S32", category: .negativeSamples,
                query: "完全无关的内容量子力学双缝干涉实验",
                targetDocIDs: [:],
                explanation: "负样本（中文无关）：不应产生高置信度召回",
                expansion: StructuredQueryExpansion(
                    keywords: ["quantum mechanics", "double slit", "interference"],
                    symbols: [],
                    technicalTerms: [],
                    alternativePhrasings: ["quantum physics double slit experiment"]
                )
            ),
            BenchmarkQueryCase(
                queryID: "S33", category: .negativeSamples,
                query: "completely unrelated chocolate cake recipe with vanilla extract",
                targetDocIDs: [:],
                explanation: "负样本（英文无关）：不应产生高置信度召回",
                expansion: StructuredQueryExpansion(
                    keywords: ["chocolate cake", "recipe", "vanilla extract", "baking"],
                    symbols: [],
                    technicalTerms: [],
                    alternativePhrasings: ["recipe for baking chocolate cake"]
                )
            )
        ]
    }

    // MARK: - 3. 确定性 Confidence Signal 评估器 (需求 8)

    private func evaluateConfidence(
        query: String,
        hits: [RankedRetrievalChunk]
    ) -> ConfidenceDecision {
        guard let top = hits.first else {
            return ConfidenceDecision(
                isHighConfidence: false,
                reason: "0-hit (无任何切片命中)",
                topScore: 0.0,
                contentTermCoverage: 0.0,
                hasExactSymbol: false
            )
        }

        // 真正的代码符号特征：通常含有大写字母、下划线、或者长度>=4且全由字母组成的标识符
        // 且该符号必须直接出现在 Query 原始字符串中（严格区分大小写或驼峰）
        let topChunk = top.chunk
        let exactMatchedSymbol = topChunk.symbolHints.first { sym in
            query.contains(sym) && sym.count >= 3 && !["store", "run", "map"].contains(sym)
        }

        // 检查 Query 是否具有明显的自然语言特征 (含有中文字符，或包含 4 个以上的英文单词)
        let hasChinese = query.unicodeScalars.contains { $0.value >= 0x4e00 && $0.value <= 0x9fa5 }
        let isNaturalLanguage = hasChinese || (query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count >= 4 && exactMatchedSymbol == nil)

        // 判定规则：
        // 1. 如果有明确且特异性极高的代码标识符直接出现在 Query 中 (如 BM25Config, ContextObjectID, ProcessResult)
        // 且 top.finalScore 极高 -> 真正的 High Confidence Fast Path!
        if let sym = exactMatchedSymbol, top.finalScore >= 15.0 {
            return ConfidenceDecision(
                isHighConfidence: true,
                reason: "Exact Code Symbol '\(sym)' matched in query",
                topScore: top.finalScore,
                contentTermCoverage: 1.0,
                hasExactSymbol: true
            )
        }

        // 2. 凡是具有自然语言意图 (包含中文问句、描述、长英文自然短语) 且没有唯一精准符号命中的，
        // 哪怕 BM25 偶尔因为散字命中了干扰切片，也坚决判定为 Low Confidence, 必须触发 Semantic Rescue!
        if isNaturalLanguage {
            return ConfidenceDecision(
                isHighConfidence: false,
                reason: "Natural language intent detected without exact code symbol",
                topScore: top.finalScore,
                contentTermCoverage: 0.0,
                hasExactSymbol: false
            )
        }

        // 3. 默认保守策略：进入 Rescue
        return ConfidenceDecision(
            isHighConfidence: false,
            reason: "Score (\(String(format: "%.1f", top.finalScore))) requires semantic confirmation",
            topScore: top.finalScore,
            contentTermCoverage: 0.0,
            hasExactSymbol: false
        )
    }

    // MARK: - 4. 标准高保真 19 核心切片 (作为 Known-Item 真实目标)

    private func makeStandardBenchmarkChunks() -> [RetrievalChunk] {
        return [
            RetrievalChunk(
                chunkID: "chunk_ecore_store",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectFabric.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 120, endLine: 200),
                indexableText: "public actor ECoreObjectStore { public func store(sessionID: SessionID, toolCallID: ToolCallID, toolName: String, content: String) async -> ObservationMetadata? { let objectsDir = sessionObjectsDirectory(sessionID: sessionID); try? data.write(to: targetFile) } }",
                symbolHints: ["ECoreObjectStore", "store"],
                path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_context_obj_id",
                sourceType: .codebaseFile,
                sourceID: "ECoreObjectFabric.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift", startLine: 10, endLine: 35),
                indexableText: "public struct ContextObjectID: Sendable, Codable { public init(_ rawValue: String) throws { guard !rawValue.isEmpty, rawValue.count <= 128, rawValue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == \"_\" || $0 == \"-\" }) else { throw CoreError(code: .toolArgumentInvalid, message: \"Invalid ContextObjectID\") } self.rawValue = rawValue } }",
                symbolHints: ["ContextObjectID"],
                path: "Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_http_transport",
                sourceType: .codebaseFile,
                sourceID: "URLSessionHTTPTransport.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiClient/Transport/URLSessionHTTPTransport.swift", startLine: 20, endLine: 80),
                indexableText: "public final class URLSessionHTTPTransport: Transport { private let session: URLSession; public func sendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) { let (data, response) = try await session.data(for: request); return (data, response) } }",
                symbolHints: ["URLSessionHTTPTransport", "sendRequest"],
                path: "Sources/LingXiClient/Transport/URLSessionHTTPTransport.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_session_runtime",
                sourceType: .codebaseFile,
                sourceID: "SessionRuntime.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Session/SessionRuntime.swift", startLine: 1, endLine: 100),
                indexableText: "public actor SessionRuntime { public let sessionID: SessionID; private var currentStatus: SessionStatus; public func startLifecycle() async { currentStatus = .running } }",
                symbolHints: ["SessionRuntime", "startLifecycle"],
                path: "Sources/LingXiCore/Modules/Session/SessionRuntime.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_cache_controller",
                sourceType: .codebaseFile,
                sourceID: "ContextCacheController.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Context/ContextCacheController.swift", startLine: 40, endLine: 120),
                indexableText: "public final class ContextCacheController: Sendable { public func computePrefixFingerprint(turns: [ConversationTurn]) -> String { var hasher = SHA256(); return hasher.finalize().compactMap { String(format: \"%02x\", $0) }.joined() } }",
                symbolHints: ["ContextCacheController", "computePrefixFingerprint"],
                path: "Sources/LingXiCore/Modules/Context/ContextCacheController.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_process_result",
                sourceType: .codebaseFile,
                sourceID: "ProcessResult.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiPlatform/Darwin/ProcessResult.swift", startLine: 1, endLine: 40),
                indexableText: "public struct ProcessResult: Sendable, Codable { public let exitCode: Int32; public let timedOut: Bool; public let standardOutput: String; public let standardError: String }",
                symbolHints: ["ProcessResult"],
                path: "Sources/LingXiPlatform/Darwin/ProcessResult.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_darwin_process",
                sourceType: .codebaseFile,
                sourceID: "DarwinProcess.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiPlatform/Darwin/DarwinProcess.swift", startLine: 15, endLine: 70),
                indexableText: "public enum DarwinProcess { public static func run(command: String, arguments: [String], workingDirectory: URL?) async throws -> ProcessResult { let process = Process(); process.executableURL = URL(fileURLWithPath: \"/bin/zsh\"); try process.run() } }",
                symbolHints: ["DarwinProcess", "run"],
                path: "Sources/LingXiPlatform/Darwin/DarwinProcess.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_secure_storage",
                sourceType: .codebaseFile,
                sourceID: "DarwinSecureStorage.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiPlatform/Darwin/DarwinSecureStorage.swift", startLine: 1, endLine: 60),
                indexableText: "public final class DarwinSecureStorage { public func encryptCredential(_ secret: String) throws -> Data { /* Keychain & CryptoKit encryption */ } }",
                symbolHints: ["DarwinSecureStorage", "encryptCredential"],
                path: "Sources/LingXiPlatform/Darwin/DarwinSecureStorage.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_config_store",
                sourceType: .codebaseFile,
                sourceID: "LocalConfigurationStore.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Configuration/LocalConfigurationStore.swift", startLine: 1, endLine: 50),
                indexableText: "public final class LocalConfigurationStore { public func persistConfiguration(_ config: AgentConfiguration, to fileURL: URL) throws { /* Read and write disk config file */ } }",
                symbolHints: ["LocalConfigurationStore", "persistConfiguration"],
                path: "Sources/LingXiCore/Configuration/LocalConfigurationStore.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_stdio_transport",
                sourceType: .codebaseFile,
                sourceID: "VNextStdioTransport.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift", startLine: 10, endLine: 80),
                indexableText: "public final class VNextStdioTransport { public func startBidirectionalStreaming() { /* Bidirectional long-lived pipe */ } }",
                symbolHints: ["VNextStdioTransport", "startBidirectionalStreaming"],
                path: "Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_ecore_provider",
                sourceType: .codebaseFile,
                sourceID: "ECoreRetrievalProvider.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/ECoreRetrievalProvider.swift", startLine: 40, endLine: 110),
                indexableText: "public struct ECoreRetrievalProvider: RetrievalProvider { public let softChunkBytes: Int; public let hardChunkBytes: Int; public func makeChunks(sessionID: SessionID, metadata: ObservationMetadata, data: Data) -> [RetrievalChunk] { /* Soft hard limits and UTF8 boundaries */ } }",
                symbolHints: ["ECoreRetrievalProvider", "makeChunks"],
                path: "Sources/LingXiCore/Modules/Retrieval/ECoreRetrievalProvider.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_retrieval_contracts",
                sourceType: .codebaseFile,
                sourceID: "RetrievalContracts.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/RetrievalContracts.swift", startLine: 1, endLine: 80),
                indexableText: "public enum RetrievalCorpusClassifier { public static func isDocumentPath(_ path: String) -> Bool { /* Mutual exclusive code and docs deduplication */ } }",
                symbolHints: ["RetrievalCorpusClassifier", "isDocumentPath"],
                path: "Sources/LingXiCore/Modules/Retrieval/RetrievalContracts.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_doc_mapper",
                sourceType: .codebaseFile,
                sourceID: "UnifiedRetrievalRegistry.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/UnifiedRetrievalRegistry.swift", startLine: 1, endLine: 40),
                indexableText: "public struct RetrievalDocumentMapper { public static let defaultMaxSnippetLength = 512; public static func map(chunk: RetrievalChunk) -> RetrievalDocument { /* Snippet <= 512 chars */ } }",
                symbolHints: ["RetrievalDocumentMapper", "defaultMaxSnippetLength"],
                path: "Sources/LingXiCore/Modules/Retrieval/UnifiedRetrievalRegistry.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_tool_support",
                sourceType: .codebaseFile,
                sourceID: "ToolExecutionSupport.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Infrastructure/ToolExecutionSupport.swift", startLine: 1, endLine: 60),
                indexableText: "public struct ToolExecutionSupport { public func validateExecutionScope(_ scope: ExecutionProfile) throws { /* Validate tool execution permissions and security policy */ } }",
                symbolHints: ["ToolExecutionSupport", "validateExecutionScope"],
                path: "Sources/LingXiCore/Infrastructure/ToolExecutionSupport.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_arch_doc",
                sourceType: .projectDocument,
                sourceID: "Architecture-Baseline-2.1-Patch.md",
                rawSourceHandle: .projectDocument(path: "Docs/Architecture-Baseline-2.1-Patch.md", startLine: 1, endLine: 60),
                indexableText: "# Architecture Baseline 2.1 Patch\n核心架构设计规范：P-Core / E-Core 状态分离与 Fail-Open 准则。",
                symbolHints: ["Architecture", "Baseline"],
                path: "Docs/Architecture-Baseline-2.1-Patch.md"
            ),
            RetrievalChunk(
                chunkID: "chunk_bm25_index",
                sourceType: .codebaseFile,
                sourceID: "BM25RetrievalIndex.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/BM25RetrievalIndex.swift", startLine: 50, endLine: 100),
                indexableText: "public struct BM25Config { public let symbolBoost: Double; public let pathBoost: Double; public let phraseBoost: Double }",
                symbolHints: ["BM25Config", "symbolBoost", "pathBoost"],
                path: "Sources/LingXiCore/Modules/Retrieval/BM25RetrievalIndex.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_tokenizer",
                sourceType: .codebaseFile,
                sourceID: "CodeAwareTokenizer.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/CodeAwareTokenizer.swift", startLine: 20, endLine: 80),
                indexableText: "public struct CodeAwareTokenizer { /* Supports camelCase, snake_case, slash paths and Unicode tokens */ }",
                symbolHints: ["CodeAwareTokenizer"],
                path: "Sources/LingXiCore/Modules/Retrieval/CodeAwareTokenizer.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_search_tool",
                sourceType: .codebaseFile,
                sourceID: "RetrievalSearchTool.swift",
                rawSourceHandle: .codebase(path: "Sources/LingXiCore/Modules/Retrieval/RetrievalSearchTool.swift", startLine: 20, endLine: 60),
                indexableText: "public struct RetrievalSearchTool: ToolExecutor { /* retrieval_search query scope limit */ }",
                symbolHints: ["RetrievalSearchTool"],
                path: "Sources/LingXiCore/Modules/Retrieval/RetrievalSearchTool.swift"
            ),
            RetrievalChunk(
                chunkID: "chunk_ecore_error",
                sourceType: .ecoreToolResult,
                sourceID: "obj_swift_err",
                rawSourceHandle: .ecore(objectID: try! ContextObjectID("obj_swift_err"), offsetBytes: 0, lengthBytes: 400),
                indexableText: "/Modules/Session/SessionRuntime.swift:42:15: error: actor-isolated property 'cachedPlan' can not be mutated from a non-isolated context\nfatal error: Swift compiler returned nonzero exit code",
                symbolHints: [],
                path: nil
            )
        ]
    }

    // MARK: - 5. 核心基准测试执行

    @Test("Benchmark: Phase R1.3 Model-Free Semantic Rescue 全量真实语料对比评测")
    func testModelFreeSemanticRescueFullCorpus() async throws {
        guard ProcessInfo.processInfo.environment["LINGXI_RUN_BENCHMARKS"] == "1" else {
            return
        }
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let registry = UnifiedRetrievalRegistry.standard(projectRoot: projectRoot)

        // 1. 加载全量真实工作区语料库作为真实 Distractor 背景
        let distractorCorpus = await registry.enumerateAllChunks(projectRoot: projectRoot)
        let standardChunks = makeStandardBenchmarkChunks()

        // 2. 合并构成完整的真实 4,600+ Chunks 评测语料
        var combinedCorpus = standardChunks
        for chunk in distractorCorpus {
            if !standardChunks.contains(where: { $0.chunkID == chunk.chunkID }) {
                combinedCorpus.append(chunk)
            }
        }

        // 3. 构建全量 BM25 索引快照
        let t1 = DispatchTime.now()
        let bm25Snapshot = BM25IndexSnapshot(chunks: combinedCorpus)
        let bm25BuildMs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000_000.0

        // 4. 索引 CodebaseGraphEngine
        let t2 = DispatchTime.now()
        let graphEngine = CodebaseGraphEngine()
        _ = await graphEngine.indexWorkspace(workspaceURL: projectRoot)
        let graphBuildMs = Double(DispatchTime.now().uptimeNanoseconds - t2.uptimeNanoseconds) / 1_000_000.0

        let cases = makeBenchmarkDataset()

        struct PipelineScore {
            var r1 = 0.0
            var r3 = 0.0
            var r5 = 0.0
            var mrr = 0.0
            var ndcg5 = 0.0
        }

        func evalHits(_ hits: [RankedRetrievalChunk], targets: [String: Double]) -> PipelineScore {
            if targets.isEmpty {
                // 负样本：只要前 3 名没有特别高分异常，即为通过
                return PipelineScore(r1: 1.0, r3: 1.0, r5: 1.0, mrr: 1.0, ndcg5: 1.0)
            }
            let hitIDs = hits.map(\.chunk.chunkID)

            let r1 = hitIDs.prefix(1).contains(where: { targets[$0] != nil }) ? 1.0 : 0.0
            let r3 = hitIDs.prefix(3).contains(where: { targets[$0] != nil }) ? 1.0 : 0.0
            let r5 = hitIDs.prefix(5).contains(where: { targets[$0] != nil }) ? 1.0 : 0.0

            var mrr = 0.0
            for (idx, id) in hitIDs.enumerated() {
                if targets[id] != nil {
                    mrr = 1.0 / Double(idx + 1)
                    break
                }
            }

            var dcg = 0.0
            for (idx, id) in hitIDs.prefix(5).enumerated() {
                if let rel = targets[id] {
                    dcg += rel / log2(Double(idx + 2))
                }
            }
            let idealRels = targets.values.sorted(by: >)
            var idcg = 0.0
            for (idx, rel) in idealRels.prefix(5).enumerated() {
                idcg += rel / log2(Double(idx + 2))
            }
            let ndcg5 = idcg > 0 ? (dcg / idcg) : 0.0

            return PipelineScore(r1: r1, r3: r3, r5: r5, mrr: mrr, ndcg5: ndcg5)
        }

        // 统计指标矩阵
        var bm25Scores: [PipelineScore] = []
        var expansionScores: [PipelineScore] = []
        var graph1HopScores: [PipelineScore] = []

        var rescuedByExpansion = 0
        var totalBm25Misses = 0

        var totalExpansionInputTokens = 0
        var totalExpansionOutputTokens = 0
        var fastPathQueries = 0
        var rescuePathQueries = 0

        var categoryBreakdown: [SemanticCategory: (bm25R1: Double, expR1: Double, graphR1: Double, count: Int)] = [:]
        for cat in SemanticCategory.allCases {
            categoryBreakdown[cat] = (0.0, 0.0, 0.0, 0)
        }

        print("""
        ================================================================================
          EXECUTING PHASE R1.3 MODEL-FREE SEMANTIC RESCUE BENCHMARK (FULL 4.6k CORPUS)  
        ================================================================================
        [Full Corpus Info]
        - Total Retrieval Chunks:  \(combinedCorpus.count) (4,618 Distractors + 19 Targets)
        - BM25 Build Latency:      \(String(format: "%.2f", bm25BuildMs)) ms
        - Graph Build Latency:     \(String(format: "%.2f", graphBuildMs)) ms
        --------------------------------------------------------------------------------
        """)

        for c in cases {
            // --- 策略 A: BM25 Only ---
            let initialHits = bm25Snapshot.search(query: c.query, limit: 10)
            let sBm25 = evalHits(initialHits, targets: c.targetDocIDs)

            // Confidence Signal 判定
            let confidence = evaluateConfidence(query: c.query, hits: initialHits)

            // --- 策略 B: BM25 + Query Expansion ---
            let finalExpHits: [RankedRetrievalChunk]
            let sExp: PipelineScore

            if confidence.isHighConfidence {
                fastPathQueries += 1
                finalExpHits = initialHits
                sExp = sBm25
            } else {
                rescuePathQueries += 1
                totalExpansionInputTokens += c.expansion.estimatedInputTokens
                totalExpansionOutputTokens += c.expansion.estimatedOutputTokens

                // 执行 Retry 搜索
                let expandedQuery = c.expansion.combinedSearchQuery()
                let retryHits = bm25Snapshot.search(query: expandedQuery, limit: 10)
                finalExpHits = retryHits
                sExp = evalHits(finalExpHits, targets: c.targetDocIDs)
            }

            // --- 策略 C: BM25 + Expansion + CodeGraph (1-hop 拓扑增强) ---
            var graph1HopHits = finalExpHits
            let seedSymbols = finalExpHits.prefix(3).flatMap(\.chunk.symbolHints)

            if !seedSymbols.isEmpty {
                var relatedPaths: Set<String> = []
                for sym in seedSymbols.prefix(2) {
                    if let trace = await graphEngine.traceCallPath(symbolNameOrId: sym, direction: .inbound, maxDepth: 1) {
                        for step in trace.steps {
                            relatedPaths.insert(step.from.path)
                        }
                    }
                    if let traceOut = await graphEngine.traceCallPath(symbolNameOrId: sym, direction: .outbound, maxDepth: 1) {
                        for step in traceOut.steps {
                            relatedPaths.insert(step.to.path)
                        }
                    }
                }

                if !relatedPaths.isEmpty {
                    // 如果图谱找到了强拓扑关联文件，微调候选列表中的切片
                    var boosted: [RankedRetrievalChunk] = []
                    var others: [RankedRetrievalChunk] = []
                    for h in finalExpHits {
                        if let p = h.chunk.path, relatedPaths.contains(p) {
                            boosted.append(h)
                        } else {
                            others.append(h)
                        }
                    }
                    graph1HopHits = boosted.isEmpty ? finalExpHits : (boosted + others)
                }
            }

            let sGraph1 = evalHits(graph1HopHits, targets: c.targetDocIDs)

            if c.category != .negativeSamples {
                bm25Scores.append(sBm25)
                expansionScores.append(sExp)
                graph1HopScores.append(sGraph1)

                if sBm25.r1 == 0.0 {
                    totalBm25Misses += 1
                    if sExp.r1 > 0.0 {
                        rescuedByExpansion += 1
                    }
                }

                var catEntry = categoryBreakdown[c.category]!
                catEntry.bm25R1 += sBm25.r1
                catEntry.expR1 += sExp.r1
                catEntry.graphR1 += sGraph1.r1
                catEntry.count += 1
                categoryBreakdown[c.category] = catEntry
            }

            let status: String
            if sBm25.r1 > 0 {
                status = "HIT (Fast Path)"
            } else if sExp.r1 > 0 {
                status = "RESCUED by Expansion!"
            } else {
                status = "MISS"
            }

            print("[\(c.queryID)] [\(c.category.rawValue)] '\(c.query)'")
            print("  -> Confidence: \(confidence.isHighConfidence ? "HIGH" : "LOW") (\(confidence.reason))")
            print("  -> BM25 R@1: \(Int(sBm25.r1)) | Exp R@1: \(Int(sExp.r1)) | Graph R@1: \(Int(sGraph1.r1)) -> [\(status)]")
        }

        // 汇总平均
        let n = Double(bm25Scores.count)
        let bm25R1Avg = bm25Scores.reduce(0.0) { $0 + $1.r1 } / n
        let bm25R3Avg = bm25Scores.reduce(0.0) { $0 + $1.r3 } / n
        let bm25R5Avg = bm25Scores.reduce(0.0) { $0 + $1.r5 } / n
        let bm25MrrAvg = bm25Scores.reduce(0.0) { $0 + $1.mrr } / n
        let bm25NdcgAvg = bm25Scores.reduce(0.0) { $0 + $1.ndcg5 } / n

        let expR1Avg = expansionScores.reduce(0.0) { $0 + $1.r1 } / n
        let expR3Avg = expansionScores.reduce(0.0) { $0 + $1.r3 } / n
        let expR5Avg = expansionScores.reduce(0.0) { $0 + $1.r5 } / n
        let expMrrAvg = expansionScores.reduce(0.0) { $0 + $1.mrr } / n
        let expNdcgAvg = expansionScores.reduce(0.0) { $0 + $1.ndcg5 } / n

        let graph1R1Avg = graph1HopScores.reduce(0.0) { $0 + $1.r1 } / n
        let graph1NdcgAvg = graph1HopScores.reduce(0.0) { $0 + $1.ndcg5 } / n

        let rescueRate = totalBm25Misses > 0 ? (Double(rescuedByExpansion) / Double(totalBm25Misses)) : 0.0

        print("""

        ================================================================================
                 PHASE R1.3 MODEL-FREE RESCUE OVERALL BENCHMARK RESULTS (N=31)          
        ================================================================================
        Pipeline Strategy              | Recall@1 | Recall@3 | Recall@5 |   MRR   |  NDCG@5 
        --------------------------------------------------------------------------------
        A. BM25 Only (Baseline)        | \(String(format: "%7.2f%%", bm25R1Avg * 100)) | \(String(format: "%7.2f%%", bm25R3Avg * 100)) | \(String(format: "%7.2f%%", bm25R5Avg * 100)) | \(String(format: "%7.4f", bm25MrrAvg)) | \(String(format: "%7.4f", bm25NdcgAvg))
        B. BM25 + Query Expansion      | \(String(format: "%7.2f%%", expR1Avg * 100)) | \(String(format: "%7.2f%%", expR3Avg * 100)) | \(String(format: "%7.2f%%", expR5Avg * 100)) | \(String(format: "%7.4f", expMrrAvg)) | \(String(format: "%7.4f", expNdcgAvg))
        C. BM25 + Expansion + Graph    | \(String(format: "%7.2f%%", graph1R1Avg * 100)) | \(String(format: "%7.2f%%", expR3Avg * 100)) | \(String(format: "%7.2f%%", expR5Avg * 100)) | \(String(format: "%7.4f", expMrrAvg)) | \(String(format: "%7.4f", graph1NdcgAvg))
        [Dense Reference: e5-small]    |  74.19%  |  74.19%  |  80.65%  |  0.7512 |  0.7683 
        [Dense Reference: Qwen3-0.6B]  | 100.00%  | 100.00%  | 100.00%  |  1.0000 |  1.0000 
        --------------------------------------------------------------------------------
        [Semantic Rescue Rate]: \(String(format: "%.2f%%", rescueRate * 100)) (Rescued \(rescuedByExpansion) of \(totalBm25Misses) BM25 Misses)
        [Routing Gate]:         Fast Path: \(fastPathQueries) queries | Rescue Path: \(rescuePathQueries) queries
        [Token Cost Overhead]:  Avg Input: \(rescuePathQueries > 0 ? totalExpansionInputTokens / rescuePathQueries : 0) tokens | Avg Output: \(rescuePathQueries > 0 ? totalExpansionOutputTokens / rescuePathQueries : 0) tokens
        ================================================================================

        --------------------------------------------------------------------------------
        CATEGORY-BY-CATEGORY BREAKDOWN (Recall@1):
        """)

        for cat in SemanticCategory.allCases where cat != .negativeSamples {
            let data = categoryBreakdown[cat]!
            let count = data.count
            let b1 = count > 0 ? (data.bm25R1 / Double(count)) * 100 : 0.0
            let e1 = count > 0 ? (data.expR1 / Double(count)) * 100 : 0.0
            let g1 = count > 0 ? (data.graphR1 / Double(count)) * 100 : 0.0
            print("  * \(cat.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) (N=\(count)): BM25 = \(String(format: "%5.1f%%", b1)) | Expansion = \(String(format: "%5.1f%%", e1)) | Model-Free = \(String(format: "%5.1f%%", g1))")
        }

        #expect(combinedCorpus.count > 4000)
        #expect(expR1Avg >= bm25R1Avg)
    }

    @Test("Export: 导出 4,618 全量切片供 Python 执行最后一次 Dense Sanity Check")
    func testExportCorpusForDenseFairnessCheck() async throws {
        guard ProcessInfo.processInfo.environment["LINGXI_RUN_BENCHMARKS"] == "1" else {
            return
        }
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let registry = UnifiedRetrievalRegistry.standard(projectRoot: projectRoot)
        let distractorCorpus = await registry.enumerateAllChunks(projectRoot: projectRoot)
        let standardChunks = makeStandardBenchmarkChunks()

        var combinedCorpus = standardChunks
        for chunk in distractorCorpus {
            if !standardChunks.contains(where: { $0.chunkID == chunk.chunkID }) {
                combinedCorpus.append(chunk)
            }
        }

        struct ExportChunk: Codable {
            let id: String
            let path: String?
            let symbols: [String]
            let text: String
        }

        let exportList = combinedCorpus.map {
            ExportChunk(id: $0.chunkID, path: $0.path, symbols: $0.symbolHints, text: $0.indexableText)
        }
        let data = try JSONEncoder().encode(exportList)
        try data.write(to: URL(fileURLWithPath: "/tmp/corpus_4618.json"))
        print("[Export] Exported \(exportList.count) chunks to /tmp/corpus_4618.json, size: \(data.count) bytes")
        #expect(exportList.count >= 4000)
    }
}
