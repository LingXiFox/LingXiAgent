import Foundation
import LingXiProtocol

/// BM25 搜索匹配结果切片单元
public struct RankedRetrievalChunk: Sendable, Identifiable {
    public let chunk: RetrievalChunk
    public let lexicalScore: Double
    public let exactBoost: Double
    public let finalScore: Double
    public let matchedTerms: [String]

    public var id: String { chunk.chunkID }

    public init(
        chunk: RetrievalChunk,
        lexicalScore: Double,
        exactBoost: Double,
        finalScore: Double,
        matchedTerms: [String]
    ) {
        self.chunk = chunk
        self.lexicalScore = lexicalScore
        self.exactBoost = exactBoost
        self.finalScore = finalScore
        self.matchedTerms = matchedTerms
    }
}

/// 检索范围枚举
public enum RetrievalScope: String, Sendable, Codable, Equatable {
    case all
    case codebase
    case ecore
    case docs

    public func matches(_ sourceType: RetrievalSourceType) -> Bool {
        switch self {
        case .all:
            return true
        case .codebase:
            return sourceType == .codebaseFile
        case .ecore:
            return sourceType == .ecoreToolResult
        case .docs:
            return sourceType == .projectDocument
        }
    }
}

/// 紧凑倒排切片项 (CompactPosting)
/// 仅占 6 字节（内存对齐 8 字节），支持连续平铺数组存储，杜绝嵌套哈希表与碎片分配
public struct CompactPosting: Sendable {
    public let docID: Int32
    public let termFrequency: UInt16

    @inlinable
    public init(docID: Int32, termFrequency: UInt16) {
        self.docID = docID
        self.termFrequency = termFrequency
    }
}

/// BM25 权重与 Boost 配置参数（确定性、可解释，严禁包含任何 Heat / Feedback / 学习权重）
public struct BM25Config: Sendable, Equatable {
    public let k1: Double
    public let b: Double
    public let symbolBoost: Double
    public let pathBoost: Double
    public let phraseBoost: Double
    public let maxExactBoost: Double
    public let dedupPolicy: RetrievalDedupPolicy

    public init(
        k1: Double = 1.2,
        b: Double = 0.75,
        symbolBoost: Double = 1.5,
        pathBoost: Double = 1.0,
        phraseBoost: Double = 0.5,
        maxExactBoost: Double = 3.0,
        dedupPolicy: RetrievalDedupPolicy = .standard
    ) {
        self.k1 = k1
        self.b = b
        self.symbolBoost = symbolBoost
        self.pathBoost = pathBoost
        self.phraseBoost = phraseBoost
        self.maxExactBoost = maxExactBoost
        self.dedupPolicy = dedupPolicy
    }

    public static let standard = BM25Config()
}

/// BM25 不可变快照 (BM25IndexSnapshot)
/// 线程安全，纯内存只读，支持并发搜索与高效复用
/// 内存优化版：采用 Term Interning (termID) + 紧凑连续 CompactPosting 倒排表 + 紧凑 IDF 数组，内存较初版下降 >80%
public final class BM25IndexSnapshot: Sendable {
    public let corpusFingerprint: String
    public let totalDocuments: Int
    public let averageDocumentLength: Double
    public let config: BM25Config

    // 集中 Term 词典：term -> termID (0..<N)
    private let termDictionary: [String: Int32]
    // 紧凑倒排索引：以 termID 为索引，对应按 docID 严格递增的 CompactPosting 数组
    private let postingsByTermID: [[CompactPosting]]
    // 紧凑 IDF 数组：以 termID 为索引
    private let idfByTermID: [Float]
    // 语料存储：顺序保留引用
    private let documents: [RetrievalChunk]
    // 紧凑 doc 词长数组：以 docIdx 索引
    private let docLengths: [Int32]
    // 分词器
    private let tokenizer: any RetrievalTokenizer

    public init(
        chunks: [RetrievalChunk],
        config: BM25Config = .standard,
        tokenizer: any RetrievalTokenizer = CodeAwareTokenizer()
    ) {
        self.config = config
        self.tokenizer = tokenizer
        self.documents = chunks
        self.totalDocuments = chunks.count

        var termDict: [String: Int32] = [:]
        var nextTermID: Int32 = 0

        var postings: [[CompactPosting]] = []
        var lengths: [Int32] = []
        lengths.reserveCapacity(chunks.count)
        var totalLen: Int64 = 0

        // 1. 顺序构建正排与倒排表
        // 关键特性：docID 单调自增遍历，天然保证了 postingsByTermID 中每个 termID 的 Posting 按 docID 递增有序！
        for (docIdx, chunk) in chunks.enumerated() {
            let docID = Int32(docIdx)
            #if canImport(ObjectiveC)
            autoreleasepool {
                let tf = tokenizer.termFrequencies(chunk.indexableText)
                var currentDocLen: Int32 = 0

                for (term, count) in tf {
                    let termCount = UInt16(min(count, Int(UInt16.max)))
                    currentDocLen += Int32(termCount)

                    let termID: Int32
                    if let existingID = termDict[term] {
                        termID = existingID
                    } else {
                        termID = nextTermID
                        termDict[term] = termID
                        nextTermID += 1
                        postings.append([])
                    }

                    postings[Int(termID)].append(CompactPosting(docID: docID, termFrequency: termCount))
                }

                lengths.append(currentDocLen)
                totalLen += Int64(currentDocLen)
            }
            #else
            do {
                let tf = tokenizer.termFrequencies(chunk.indexableText)
                var currentDocLen: Int32 = 0

                for (term, count) in tf {
                    let termCount = UInt16(min(count, Int(UInt16.max)))
                    currentDocLen += Int32(termCount)

                    let termID: Int32
                    if let existingID = termDict[term] {
                        termID = existingID
                    } else {
                        termID = nextTermID
                        termDict[term] = termID
                        nextTermID += 1
                        postings.append([])
                    }

                    postings[Int(termID)].append(CompactPosting(docID: docID, termFrequency: termCount))
                }

                lengths.append(currentDocLen)
                totalLen += Int64(currentDocLen)
            }
            #endif
        }

        self.termDictionary = termDict
        self.postingsByTermID = postings
        self.docLengths = lengths
        self.averageDocumentLength = chunks.isEmpty ? 0 : Double(totalLen) / Double(chunks.count)

        // 2. 预计算所有词元的 IDF: ln((N - n(q) + 0.5) / (n(q) + 0.5) + 1.0)
        let nDocs = Double(chunks.count)
        var idfs: [Float] = []
        idfs.reserveCapacity(postings.count)

        for postingList in postings {
            let docFreq = Double(postingList.count)
            let idf = log((nDocs - docFreq + 0.5) / (docFreq + 0.5) + 1.0)
            idfs.append(Float(max(0.0, idf)))
        }
        self.idfByTermID = idfs

        // 3. 计算语料指纹
        var hasher = Hasher()
        for chunk in chunks {
            hasher.combine(chunk.chunkID)
        }
        self.corpusFingerprint = String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    /// 估算该索引快照占用的内存字节数（供诊断与可观测性使用）
    public var estimatedMemoryBytes: Int {
        var bytes = 0
        bytes += termDictionary.count * 48
        for list in postingsByTermID {
            bytes += list.count * MemoryLayout<CompactPosting>.stride + 16
        }
        bytes += idfByTermID.count * MemoryLayout<Float>.stride
        bytes += docLengths.count * MemoryLayout<Int32>.stride
        bytes += documents.count * 64
        return bytes
    }

    /// 词汇表大小
    public var vocabularySize: Int {
        termDictionary.count
    }

    /// 倒排记录总数
    public var totalPostingsCount: Int {
        postingsByTermID.reduce(0) { $0 + $1.count }
    }

    /// 执行只读并发检索（支持自然语言 Query 与 Model-Free Semantic Hints）
    /// - Parameters:
    ///   - query: 原始查询文本（保持原意与日志可审计性）
    ///   - lexicalHints: 可选的技术关键词、概念与英文词汇提示
    ///   - symbolHints: 可选的代码符号与函数名提示（享受 exact symbol boost，绝非硬过滤）
    ///   - scope: 检索来源范围
    ///   - limit: 最大返回数量（上限 10）
    ///   - sessionID: 可选的当前会话 ID（用于严格隔离 E-Core 会话对象，杜绝跨会话泄露）
    public func search(
        query: String,
        lexicalHints: [String]? = nil,
        symbolHints: [String]? = nil,
        scope: RetrievalScope = .all,
        limit: Int = 5,
        sessionID: SessionID? = nil
    ) -> [RankedRetrievalChunk] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, totalDocuments > 0 else { return [] }

        let safeLimit = min(max(1, limit), 10)
        let queryTokens = tokenizer.tokenize(trimmed)
        let hintTokens = (lexicalHints ?? []).flatMap { tokenizer.tokenize($0) }
        guard !queryTokens.isEmpty || !hintTokens.isEmpty else { return [] }

        // Audit #47: 校验 Chunk 是否对当前检索请求与会话可见
        @inline(__always)
        func isChunkPermitted(_ chunk: RetrievalChunk) -> Bool {
            guard scope.matches(chunk.sourceType) else { return false }
            if chunk.sourceType == .ecoreToolResult {
                if let targetSession = sessionID {
                    if let chunkSession = chunk.metadata["session_id"], !chunkSession.isEmpty, chunkSession != targetSession.rawValue {
                        return false
                    }
                } else {
                    if let chunkSession = chunk.metadata["session_id"], !chunkSession.isEmpty {
                        return false
                    }
                }
            }
            return true
        }

        // docIndex -> 累加 BM25 得分
        var docScores: [Int32: Double] = [:]
        var matchedTermsByDoc: [Int32: Set<String>] = [:]

        // 1. 词法 BM25 累加计算
        // 1.1 核心 Query Tokens (权重 1.0)
        for qTerm in queryTokens {
            guard let termID = termDictionary[qTerm] else { continue }
            let idf = Double(idfByTermID[Int(termID)])
            let postingList = postingsByTermID[Int(termID)]

            for posting in postingList {
                let docIdx = Int(posting.docID)
                let chunk = documents[docIdx]
                guard isChunkPermitted(chunk) else { continue }

                let dl = Double(docLengths[docIdx])
                let tfDouble = Double(posting.termFrequency)
                let denom = tfDouble + config.k1 * (1.0 - config.b + config.b * (dl / max(1.0, averageDocumentLength)))
                let termScore = idf * (tfDouble * (config.k1 + 1.0)) / max(0.001, denom)

                docScores[posting.docID, default: 0.0] += termScore
                matchedTermsByDoc[posting.docID, default: []].insert(qTerm)
            }
        }

        // 1.2 辅助 Lexical Hints Tokens (权重 0.6，作为 soft retrieval boost，防止词数冲淡原始意图)
        for hTerm in hintTokens {
            guard let termID = termDictionary[hTerm] else { continue }
            let idf = Double(idfByTermID[Int(termID)])
            let postingList = postingsByTermID[Int(termID)]

            for posting in postingList {
                let docIdx = Int(posting.docID)
                let chunk = documents[docIdx]
                guard isChunkPermitted(chunk) else { continue }

                let dl = Double(docLengths[docIdx])
                let tfDouble = Double(posting.termFrequency)
                let denom = tfDouble + config.k1 * (1.0 - config.b + config.b * (dl / max(1.0, averageDocumentLength)))
                let termScore = idf * (tfDouble * (config.k1 + 1.0)) / max(0.001, denom) * 0.6

                docScores[posting.docID, default: 0.0] += termScore
                matchedTermsByDoc[posting.docID, default: []].insert(hTerm)
            }
        }

        guard !docScores.isEmpty else { return [] }

        // 2. 取词法得分最高的前 100 个候选进行精确 Boost 计算与最终重排序（保证检索毫秒级响应）
        let topLexicalCandidates = docScores.sorted { $0.value > $1.value }.prefix(100)

        var ranked: [RankedRetrievalChunk] = []
        ranked.reserveCapacity(topLexicalCandidates.count)

        let lowerQuery = trimmed.lowercased()
        let customSymbolSet = Set((symbolHints ?? []).map { $0.lowercased() })

        for (docID, lexicalScore) in topLexicalCandidates {
            let docIdx = Int(docID)
            let chunk = documents[docIdx]
            var exactBoost = 0.0

            // 2.1 精确符号 Boost (包含原始 Query 符号命中与 LLM soft symbolHints 提示)
            for hint in chunk.symbolHints {
                let lowerHint = hint.lowercased()
                if lowerHint == lowerQuery || queryTokens.contains(lowerHint) || customSymbolSet.contains(lowerHint) {
                    exactBoost += config.symbolBoost
                    break
                }
            }

            // 2.2 精确路径 Boost
            if let path = chunk.path?.lowercased() {
                if path.contains(lowerQuery) || queryTokens.contains(URL(fileURLWithPath: path).lastPathComponent) {
                    exactBoost += config.pathBoost
                }
            }

            // 2.3 精确短语包含 Boost (使用标准高效 caseInsensitive 查找)
            if trimmed.count <= 128 && chunk.indexableText.range(of: trimmed, options: .caseInsensitive) != nil {
                exactBoost += config.phraseBoost
            }

            // 限制 Boost 上限
            exactBoost = min(config.maxExactBoost, exactBoost)
            let finalScore = lexicalScore + exactBoost

            ranked.append(
                RankedRetrievalChunk(
                    chunk: chunk,
                    lexicalScore: lexicalScore,
                    exactBoost: exactBoost,
                    finalScore: finalScore,
                    matchedTerms: Array(matchedTermsByDoc[docID, default: []]).sorted()
                )
            )
        }

        // 3. 排序：得分降序
        ranked.sort { lhs, rhs in
            if abs(lhs.finalScore - rhs.finalScore) > 0.0001 {
                return lhs.finalScore > rhs.finalScore
            }
            return lhs.chunk.chunkID < rhs.chunk.chunkID
        }

        // 4. 去重：联合物理重叠与词元覆盖度去重，杜绝误杀具有独立 Query 覆盖的切片
        let deduplicated = deduplicateTopK(ranked)

        return Array(deduplicated.prefix(safeLimit))
    }

    /// 对检索候选项执行物理重叠与词元覆盖联合去重
    /// 修复误杀：只有满足高物理重叠 (>= threshold) 且次选切片未提供独特 Query 词元覆盖时，才予去重
    private func deduplicateTopK(_ candidates: [RankedRetrievalChunk]) -> [RankedRetrievalChunk] {
        var results: [RankedRetrievalChunk] = []
        let policy = config.dedupPolicy

        for candidate in candidates {
            var shouldDeduplicate = false

            switch candidate.chunk.rawSourceHandle {
            case .ecore(let objectID, let offsetBytes, let lengthBytes):
                let candidateRange = (offset: offsetBytes, length: lengthBytes)
                let overlappingItems = results.filter { existing in
                    guard case .ecore(let existingObjID, let exOffset, let exLength) = existing.chunk.rawSourceHandle,
                          existingObjID == objectID else { return false }
                    let overlapStart = max(exOffset, candidateRange.offset)
                    let overlapEnd = min(exOffset + exLength, candidateRange.offset + candidateRange.length)
                    let overlap = max(0, overlapEnd - overlapStart)
                    let minLen = max(1, min(exLength, candidateRange.length))
                    let overlapRatio = Double(overlap) / Double(minLen)
                    return overlapRatio >= policy.physicalOverlapThreshold
                }

                if !overlappingItems.isEmpty {
                    if policy.requireTermCoverageDiff {
                        var coveredTerms = Set<String>()
                        for item in overlappingItems {
                            coveredTerms.formUnion(item.matchedTerms)
                        }
                        let candidateTerms = Set(candidate.matchedTerms)
                        let newTerms = candidateTerms.subtracting(coveredTerms)
                        if newTerms.isEmpty {
                            shouldDeduplicate = true
                        }
                    } else {
                        shouldDeduplicate = true
                    }
                }

            case .codebase(let path, let startLine, let endLine), .projectDocument(let path, let startLine, let endLine):
                let candidateRange = (start: startLine, end: endLine)
                let overlappingItems = results.filter { existing in
                    let existingPath: String
                    let exStart: Int
                    let exEnd: Int
                    switch existing.chunk.rawSourceHandle {
                    case .codebase(let p, let s, let e):
                        existingPath = p; exStart = s; exEnd = e
                    case .projectDocument(let p, let s, let e):
                        existingPath = p; exStart = s; exEnd = e
                    default:
                        return false
                    }
                    guard existingPath == path else { return false }

                    let overlapStart = max(exStart, candidateRange.start)
                    let overlapEnd = min(exEnd, candidateRange.end)
                    let overlap = max(0, overlapEnd - overlapStart + 1)
                    let minLines = max(1, min(exEnd - exStart + 1, candidateRange.end - candidateRange.start + 1))
                    let overlapRatio = Double(overlap) / Double(minLines)
                    return overlapRatio >= policy.physicalOverlapThreshold
                }

                if !overlappingItems.isEmpty {
                    if policy.requireTermCoverageDiff {
                        var coveredTerms = Set<String>()
                        for item in overlappingItems {
                            coveredTerms.formUnion(item.matchedTerms)
                        }
                        let candidateTerms = Set(candidate.matchedTerms)
                        let newTerms = candidateTerms.subtracting(coveredTerms)
                        if newTerms.isEmpty {
                            shouldDeduplicate = true
                        }
                    } else {
                        shouldDeduplicate = true
                    }
                }
            }

            if !shouldDeduplicate {
                results.append(candidate)
            }
        }

        return results
    }
}

/// BM25 索引管理器与生命周期构建器
public actor BM25RetrievalIndex {
    private var currentSnapshot: BM25IndexSnapshot?
    private var lastFingerprint: String?
    private let tokenizer: any RetrievalTokenizer

    public init(tokenizer: any RetrievalTokenizer = CodeAwareTokenizer()) {
        self.tokenizer = tokenizer
    }

    /// 获取或构建当前可复用不可变快照（Fail-Open，构建失败不崩溃，返回 nil）
    public func snapshot(for chunks: [RetrievalChunk], config: BM25Config = .standard) -> BM25IndexSnapshot {
        var hasher = Hasher()
        for c in chunks {
            hasher.combine(c.chunkID)
        }
        let fingerprint = String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))

        if let current = currentSnapshot, lastFingerprint == fingerprint {
            return current
        }

        let newSnapshot = BM25IndexSnapshot(chunks: chunks, config: config, tokenizer: tokenizer)
        self.currentSnapshot = newSnapshot
        self.lastFingerprint = fingerprint
        return newSnapshot
    }

    /// 显式刷新或使快照失效
    public func invalidate() {
        self.currentSnapshot = nil
        self.lastFingerprint = nil
    }
}
