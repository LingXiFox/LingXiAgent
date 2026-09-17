import Foundation
import LingXiProtocol

/// 检索语料来源类型（Phase R0 支持核心三大类型）
public enum RetrievalSourceType: String, Codable, Sendable, Equatable, Hashable {
    case ecoreToolResult = "ecore_tool_result"
    case codebaseFile = "codebase_file"
    case projectDocument = "project_document"
}

/// 原始权威数据定位句柄（只负责物理定位，绝对不保存完整内容）
public enum RawSourceHandle: Codable, Sendable, Equatable, Hashable {
    /// 指向 E-Core 派生切片，可通过 context_recall 精确拉取
    case ecore(objectID: ContextObjectID, offsetBytes: Int, lengthBytes: Int)
    /// 指向 Codebase 源码行区间，可通过 read_file 精确拉取
    case codebase(path: String, startLine: Int, endLine: Int)
    /// 指向项目文档行区间，可通过 read_file 精确拉取
    case projectDocument(path: String, startLine: Int, endLine: Int)
}

/// 检索去重集中配置策略 (RetrievalDedupPolicy)
/// 严格禁止散落 magic number，去重依据完全基于物理重叠与词元覆盖度，严禁依赖展示 Snippet
public struct RetrievalDedupPolicy: Sendable, Equatable, Codable {
    /// 物理重叠阈值（默认调高至 0.75，超过此比例才进入候选去重判断）
    public let physicalOverlapThreshold: Double
    /// 是否要求次选切片必须提供新的唯一词元覆盖（默认 true）
    public let requireTermCoverageDiff: Bool

    public init(
        physicalOverlapThreshold: Double = 0.75,
        requireTermCoverageDiff: Bool = true
    ) {
        self.physicalOverlapThreshold = physicalOverlapThreshold
        self.requireTermCoverageDiff = requireTermCoverageDiff
    }

    public static let standard = RetrievalDedupPolicy()
}

/// 统一检索运行时生命周期状态 (RetrievalRuntimeState)
public enum RetrievalRuntimeState: String, Sendable, Codable, Equatable {
    case uninitialized
    case building
    case ready
    case failed
}

/// 统一检索执行状态响应结果 (RetrievalSearchResult)
public enum RetrievalSearchResult: Sendable {
    case warming(message: String)
    case unavailable(reason: String)
    case results([RankedRetrievalChunk])
}

/// 检索最小索引单元（包含完整受控大小的 indexableText，供未来 BM25/Embedding 建立倒排或向量索引）
public struct RetrievalChunk: Sendable, Identifiable, Equatable {
    public let chunkID: String
    public let sourceType: RetrievalSourceType
    public let sourceID: String
    public let rawSourceHandle: RawSourceHandle
    public let indexableText: String
    public let symbolHints: [String]
    public let path: String?
    public let timestamp: Date
    public let metadata: [String: String]

    public var id: String { chunkID }

    public init(
        chunkID: String,
        sourceType: RetrievalSourceType,
        sourceID: String,
        rawSourceHandle: RawSourceHandle,
        indexableText: String,
        symbolHints: [String] = [],
        path: String? = nil,
        timestamp: Date = .now,
        metadata: [String: String] = [:]
    ) {
        self.chunkID = chunkID
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.rawSourceHandle = rawSourceHandle
        self.indexableText = indexableText
        self.symbolHints = symbolHints
        self.path = path
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

/// 最终候选展示与决策对象（包含不超过 512 字符的紧凑展示摘要，保护模型上下文预算）
public struct RetrievalDocument: Sendable, Identifiable, Equatable, Codable {
    public let documentID: String
    public let sourceType: RetrievalSourceType
    public let sourceID: String
    public let path: String?
    public let symbol: String?
    public let snippet: String
    public let timestamp: Date
    public let metadata: [String: String]
    public let rawSourceHandle: RawSourceHandle
    public let score: Double?

    public var id: String { documentID }

    public init(
        documentID: String,
        sourceType: RetrievalSourceType,
        sourceID: String,
        path: String? = nil,
        symbol: String? = nil,
        snippet: String,
        timestamp: Date = .now,
        metadata: [String: String] = [:],
        rawSourceHandle: RawSourceHandle,
        score: Double? = nil
    ) {
        self.documentID = documentID
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.path = path
        self.symbol = symbol
        self.snippet = snippet
        self.timestamp = timestamp
        self.metadata = metadata
        self.rawSourceHandle = rawSourceHandle
        self.score = score
    }
}

/// 检索语料提供者只读协议（严禁修改 P-Core、E-Core 或 SessionStore，严禁自动注入上下文）
public protocol RetrievalProvider: Sendable {
    var sourceType: RetrievalSourceType { get }

    func enumerateChunks(
        projectRoot: URL,
        sessionID: SessionID?
    ) async throws -> [RetrievalChunk]
}

/// 语料类型分类器（保证 Codebase 与 Document Providers 严格互斥，杜绝重复 Chunk）
public enum RetrievalCorpusClassifier {
    public static func isDocumentPath(_ path: String, pageSourceType: ContextPageSourceType? = nil) -> Bool {
        if let pageSourceType {
            switch pageSourceType {
            case .documentation, .referenceDocumentation, .projectMetadata, .researchArchive:
                return true
            default:
                break
            }
        }
        let lower = path.lowercased()
        let filename = URL(fileURLWithPath: lower).lastPathComponent
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt") || lower.hasSuffix(".rst") || lower.hasSuffix(".adoc") {
            return true
        }
        if filename.contains("license") || filename.contains("readme") || filename == "agents.md" || filename == "claude.md" || filename.contains("contributing") || filename.contains("notice") {
            return true
        }
        if lower.hasPrefix("docs/") || lower.contains("/docs/") {
            return true
        }
        return false
    }
}
