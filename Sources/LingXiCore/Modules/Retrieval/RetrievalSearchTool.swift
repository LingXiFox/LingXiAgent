import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// 统一语义检索独立工具 (retrieval_search)
/// 严格遵守只读、两阶段交互、Model-Free 与 Fail-Open 架构铁律：
/// 1. 绝不自动调用 context_recall 或 read_file，由 Agent 依据摘要按需二次读取
/// 2. 绝不修改 residentPages 或自动注入 P-Core
/// 3. 只返回带有 `<= 512` 字符摘要、精确指针及可选 CodeGraph 1-hop 拓扑提示
/// 4. 首次调用若索引尚在后台预热构建，立即返回 warming 状态，绝不阻塞交互 Turn
/// 5. 纯 CPU 确定性 BM25，零外部向量模型运行时依赖
public struct RetrievalSearchTool: ToolExecutor, Sendable {
    public static let toolID = ToolID("retrieval_search")

    private let registry: UnifiedRetrievalRegistry
    private let runtime: RetrievalRuntime
    private let projectRoot: URL
    private let graphEngine: CodebaseGraphEngine?

    public init(
        projectRoot: URL,
        registry: UnifiedRetrievalRegistry? = nil,
        runtime: RetrievalRuntime? = nil,
        index: BM25RetrievalIndex? = nil,
        ecoreStore: ECoreObjectStore? = nil,
        graphEngine: CodebaseGraphEngine? = nil
    ) {
        self.projectRoot = projectRoot
        let reg = registry ?? UnifiedRetrievalRegistry.standard(projectRoot: projectRoot, ecoreStore: ecoreStore)
        self.registry = reg
        self.runtime = runtime ?? RetrievalRuntime(registry: reg)
        self.graphEngine = graphEngine
    }

    /// 获取底层运行时（供生命周期管理与预热调用）
    public var retrievalRuntime: RetrievalRuntime {
        runtime
    }

    public let definition = ToolDefinition(
        id: toolID,
        description: """
        Search project codebase, documentation, and past E-Core tool execution outputs using CodeAware BM25 retrieval.
        TIPS FOR OPTIMAL RESULTS:
        - If your search is conceptual, natural language, or in Chinese, provide likely English terms in 'lexical_hints' (e.g. ['HTTP', 'transport', 'send']) and likely symbols in 'symbol_hints' (e.g. ['URLSessionHTTPTransport', 'sendRequest']).
        - If searching for an exact symbol, identifier, path, or compiler error, simply pass 'query' without hints for ultra-fast zero-overhead matching.
        Returns brief snippets (<= 512 chars), exact pointers, and 1-hop related code graph context. Does NOT auto-read full content.
        """,
        inputSchema: ToolInputSchema(
            properties: [
                "query": ToolInputProperty(
                    type: .string,
                    description: "Original search query, identifier, error message, or natural language intent"
                ),
                "lexical_hints": ToolInputProperty(
                    type: .array,
                    description: "Optional list of likely technical keywords, English terms, and concepts (e.g. ['HTTP', 'transport', 'send'])"
                ),
                "symbol_hints": ToolInputProperty(
                    type: .array,
                    description: "Optional list of likely code symbols, types, functions (e.g. ['URLSessionHTTPTransport', 'sendRequest'])"
                ),
                "scope": ToolInputProperty(
                    type: .string,
                    description: "Search scope: 'all' (default), 'codebase', 'ecore', or 'docs'",
                    enumValues: ["all", "codebase", "ecore", "docs"]
                ),
                "limit": ToolInputProperty(
                    type: .integer,
                    description: "Maximum results to return (default: 5, max: 10)",
                    minimum: 1,
                    maximum: 10
                )
            ],
            required: ["query"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        ""
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.projectRead]
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        struct SearchInput: Decodable {
            let query: String
            let lexical_hints: [String]?
            let lexicalHints: [String]?
            let symbol_hints: [String]?
            let symbolHints: [String]?
            let scope: String?
            let limit: Int?
            let session_id: String?
            let sessionId: String?
        }

        guard let data = arguments.data(using: .utf8) else {
            return "Error: Invalid UTF-8 arguments"
        }

        let input: SearchInput
        do {
            input = try JSONDecoder().decode(SearchInput.self, from: data)
        } catch {
            return "Error: Failed to parse arguments: \(error.localizedDescription)"
        }

        let trimmedQuery = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return "Error: Query must not be empty"
        }

        let lexicalHints = input.lexical_hints ?? input.lexicalHints
        let symbolHints = input.symbol_hints ?? input.symbolHints
        let scope = RetrievalScope(rawValue: input.scope?.lowercased() ?? "all") ?? .all
        let limit = min(max(1, input.limit ?? 5), 10)

        let sessionID = (input.session_id ?? input.sessionId).map(SessionID.init) ?? ToolExecutionContext.sessionID
        let searchResult = await runtime.search(
            query: trimmedQuery,
            lexicalHints: lexicalHints,
            symbolHints: symbolHints,
            scope: scope,
            limit: limit,
            projectRoot: projectRoot,
            sessionID: sessionID
        )

        switch searchResult {
        case .warming(let message):
            return """
            Status: warming
            Notice: \(message)
            Tip: You can retry after a few seconds or use fallback tools like 'read_file'.
            """

        case .unavailable(let reason):
            return """
            Status: unavailable
            Error: \(reason)
            Tip: Please check system logs or use 'read_file'.
            """

        case .results(let rankedResults):
            guard !rankedResults.isEmpty else {
                let hasHints = (lexicalHints?.isEmpty == false) || (symbolHints?.isEmpty == false)
                Task {
                    await RetrievalTelemetry.shared.record(
                        query: trimmedQuery,
                        hasHints: hasHints,
                        lexicalHintCount: lexicalHints?.count ?? 0,
                        symbolHintCount: symbolHints?.count ?? 0,
                        scope: scope.rawValue,
                        confidence: "low_confidence",
                        topScore: 0.0,
                        resultCount: 0
                    )
                }
                return "No matching documents found for query: '\(trimmedQuery)' (scope: \(scope.rawValue))."
            }

            // 1. 计算确定性 Confidence Level
            let topScore = rankedResults.first?.finalScore ?? 0.0
            let topExactBoost = rankedResults.first?.exactBoost ?? 0.0
            let confidence: String
            if topExactBoost > 0 && topScore >= 15.0 {
                confidence = "high_confidence"
            } else if topScore >= 8.0 {
                confidence = "medium_confidence"
            } else {
                confidence = "low_confidence"
            }

            // 2. 异步记录生产遥测 (Fail-Open)
            let hasHints = (lexicalHints?.isEmpty == false) || (symbolHints?.isEmpty == false)
            Task {
                await RetrievalTelemetry.shared.record(
                    query: trimmedQuery,
                    hasHints: hasHints,
                    lexicalHintCount: lexicalHints?.count ?? 0,
                    symbolHintCount: symbolHints?.count ?? 0,
                    scope: scope.rawValue,
                    confidence: confidence,
                    topScore: topScore,
                    resultCount: rankedResults.count
                )
            }

            // 3. 映射为展示 Document 与两阶段读取指引
            var outputLines: [String] = [
                "Status: ready | Confidence: \(confidence)",
                "Found \(rankedResults.count) result(s) for '\(trimmedQuery)':"
            ]

            var activeHints: [String] = []
            if let symbols = symbolHints, !symbols.isEmpty {
                activeHints.append("[Symbols: \(symbols.joined(separator: ", "))]")
            }
            if let lex = lexicalHints, !lex.isEmpty {
                activeHints.append("[Lexical: \(lex.joined(separator: ", "))]")
            }
            if !activeHints.isEmpty {
                outputLines.append("Active Hints: \(activeHints.joined(separator: " "))")
            }
            outputLines.append("")

            for (idx, ranked) in rankedResults.enumerated() {
                let doc = RetrievalDocumentMapper.map(chunk: ranked.chunk, score: ranked.finalScore)
                outputLines.append("[\(idx + 1)] [\(doc.sourceType.rawValue)] Score: \(String(format: "%.3f", doc.score ?? 0.0))")

                switch doc.rawSourceHandle {
                case .ecore(let objectID, let offsetBytes, let lengthBytes):
                    outputLines.append("    Target: E-Core Object '\(objectID.rawValue)' (offset: \(offsetBytes), length: \(lengthBytes))")
                    outputLines.append("    Action Hint: Call context_recall(id: \"\(objectID.rawValue)\", offset: \(offsetBytes), limit_bytes: \(lengthBytes)) to inspect full slice")
                case .codebase(let path, let startLine, let endLine):
                    outputLines.append("    Target: Code '\(path)' L\(startLine)-L\(endLine)")
                    outputLines.append("    Action Hint: Call read_file(path: \"\(path)\", start_line: \(startLine), end_line: \(endLine)) to inspect source")
                case .projectDocument(let path, let startLine, let endLine):
                    outputLines.append("    Target: Doc '\(path)' L\(startLine)-L\(endLine)")
                    outputLines.append("    Action Hint: Call read_file(path: \"\(path)\", start_line: \(startLine), end_line: \(endLine)) to inspect document")
                }

                if let symbol = doc.symbol {
                    outputLines.append("    Symbol Hint: \(symbol)")

                    // 4. Secondary Context Enrichment (仅对 Top-2 结果附着 1-hop 拓扑提示，绝不篡改主排序)
                    if idx < 2, let engine = graphEngine {
                        if let traceIn = await engine.traceCallPath(symbolNameOrId: symbol, direction: .inbound, maxDepth: 1),
                           !traceIn.steps.isEmpty {
                            let callers = Set(traceIn.steps.map { URL(fileURLWithPath: $0.from.path).lastPathComponent }).prefix(3)
                            outputLines.append("    Related Callers (Graph 1-hop): \(callers.joined(separator: ", "))")
                        }
                    }
                }

                outputLines.append("    Snippet:")
                for line in doc.snippet.components(separatedBy: "\n").prefix(6) {
                    outputLines.append("      \(line)")
                }
                outputLines.append("")
            }

            return outputLines.joined(separator: "\n")
        }
    }
}
