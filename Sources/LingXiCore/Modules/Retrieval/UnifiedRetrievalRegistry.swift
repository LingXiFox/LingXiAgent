import Foundation
import LingXiProtocol

/// 检索文档映射器 (RetrievalDocumentMapper)
/// 负责将包含完整正文的 RetrievalChunk 转换为面向展示的轻量 RetrievalDocument
public struct RetrievalDocumentMapper: Sendable {
    public static let defaultMaxSnippetLength = 512

    /// 将检索最小索引单元映射为展示候选文档
    /// - Parameters:
    ///   - chunk: 检索切片
    ///   - score: 候选打分（预留字段，Phase R0 默认为 nil）
    ///   - maxSnippetLength: 展示摘要最大字符数（默认 512，绝对不截断 chunk 原有的 indexableText）
    public static func map(
        chunk: RetrievalChunk,
        score: Double? = nil,
        maxSnippetLength: Int = defaultMaxSnippetLength
    ) -> RetrievalDocument {
        let maxLen = max(64, maxSnippetLength)
        let rawText = chunk.indexableText.trimmingCharacters(in: .whitespacesAndNewlines)

        let snippet: String
        if rawText.count <= maxLen {
            snippet = rawText
        } else {
            let prefixIndex = rawText.index(rawText.startIndex, offsetBy: min(rawText.count, maxLen - 3))
            snippet = String(rawText[..<prefixIndex]) + "..."
        }

        return RetrievalDocument(
            documentID: chunk.chunkID,
            sourceType: chunk.sourceType,
            sourceID: chunk.sourceID,
            path: chunk.path,
            symbol: chunk.symbolHints.first,
            snippet: snippet,
            timestamp: chunk.timestamp,
            metadata: chunk.metadata,
            rawSourceHandle: chunk.rawSourceHandle,
            score: score
        )
    }
}

/// 统一检索提供者只读注册表 (UnifiedRetrievalRegistry)
/// 负责管理多源数据 Provider，提供聚合只读枚举能力，全链路 Fail-Open
public struct UnifiedRetrievalRegistry: Sendable {
    public let providers: [any RetrievalProvider]

    public init(providers: [any RetrievalProvider] = []) {
        self.providers = providers
    }

    /// 创建标准内置默认注册表（包含 E-Core、Codebase 与项目文档 Providers）
    public static func standard(
        projectRoot: URL,
        ecoreStore: ECoreObjectStore? = nil
    ) -> UnifiedRetrievalRegistry {
        let scanner = ProjectScanner(root: projectRoot)
        let store = ecoreStore ?? ECoreObjectStore()

        return UnifiedRetrievalRegistry(providers: [
            ECoreRetrievalProvider(ecoreStore: store),
            CodebaseRetrievalProvider(scanner: scanner),
            ProjectDocumentRetrievalProvider(scanner: scanner)
        ])
    }

    /// 聚合枚举所有可用 Provider 的 Chunks（Fail-Open，任一 Provider 异常不影响其它 Provider）
    public func enumerateAllChunks(
        projectRoot: URL,
        sessionID: SessionID? = nil
    ) async -> [RetrievalChunk] {
        var allChunks: [RetrievalChunk] = []

        for provider in providers {
            do {
                let chunks = try await provider.enumerateChunks(projectRoot: projectRoot, sessionID: sessionID)
                allChunks.append(contentsOf: chunks)
            } catch {
                // Fail-Open: 记录弱告警并静默继续
                FileHandle.standardError.write(
                    Data("[RETRIEVAL WARNING] Provider \(provider.sourceType.rawValue) enumeration failed: \(error)\n".utf8)
                )
            }
        }

        return Self.deduplicateChunks(allChunks)
    }

    /// Canonical Chunk 去重：禁止同一物理 path + range 因 Provider 不同而重复进入索引
    public static func deduplicateChunks(_ chunks: [RetrievalChunk]) -> [RetrievalChunk] {
        var seenFileRanges: Set<String> = []
        var uniqueChunks: [RetrievalChunk] = []

        for chunk in chunks {
            switch chunk.rawSourceHandle {
            case .codebase(let path, let startLine, let endLine), .projectDocument(let path, let startLine, let endLine):
                let canonicalKey = "\(path)#L\(startLine)-L\(endLine)"
                if seenFileRanges.contains(canonicalKey) {
                    continue
                }
                seenFileRanges.insert(canonicalKey)
                uniqueChunks.append(chunk)
            case .ecore:
                uniqueChunks.append(chunk)
            }
        }
        return uniqueChunks
    }

    /// 获取特定类型的 Provider
    public func provider(for type: RetrievalSourceType) -> (any RetrievalProvider)? {
        providers.first { $0.sourceType == type }
    }
}
