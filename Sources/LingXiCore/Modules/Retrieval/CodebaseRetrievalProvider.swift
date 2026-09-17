import Foundation
import LingXiProtocol

/// Codebase 源码只读检索适配器 (CodebaseRetrievalProvider)
/// 直接复用现有的 ContextPager / ProjectPageStore / ProjectScanner 扫描与页面切分能力，
/// 坚决不重新实现第二套代码 Chunker，将 ContextPage 无损映射为 RetrievalChunk。
public struct CodebaseRetrievalProvider: RetrievalProvider, Sendable {
    public let sourceType: RetrievalSourceType = .codebaseFile
    public let scanner: ProjectScanner

    public init(scanner: ProjectScanner) {
        self.scanner = scanner
    }

    public init(projectRoot: URL) {
        self.scanner = ProjectScanner(root: projectRoot)
    }

    /// 枚举工作区源码切片并映射为 RetrievalChunk
    public func enumerateChunks(
        projectRoot: URL,
        sessionID: SessionID? = nil
    ) async throws -> [RetrievalChunk] {
        let activeScanner: ProjectScanner
        if scanner.root.standardizedFileURL.path == projectRoot.standardizedFileURL.path {
            activeScanner = scanner
        } else {
            activeScanner = ProjectScanner(root: projectRoot)
        }

        do {
            let scan = try activeScanner.scanManifest()
            // 过滤出源码与测试类文件，严格排除任何文档或规范文件，文档留给 ProjectDocumentRetrievalProvider
            let codePages = scan.pages.filter { page in
                guard !RetrievalCorpusClassifier.isDocumentPath(page.path, pageSourceType: page.sourceType) else {
                    return false
                }
                return page.sourceType == .sourceFile || page.sourceType == .test || page.sourceType == .configuration
            }

            return codePages.map { page in
                let handle = RawSourceHandle.codebase(
                    path: page.path,
                    startLine: page.startLine,
                    endLine: page.endLine
                )

                let hints = extractSymbolHints(from: page.content)

                return RetrievalChunk(
                    chunkID: "code:\(page.path)#L\(page.startLine)-L\(page.endLine)",
                    sourceType: .codebaseFile,
                    sourceID: page.path,
                    rawSourceHandle: handle,
                    indexableText: page.content,
                    symbolHints: hints,
                    path: page.path,
                    timestamp: .now,
                    metadata: [
                        "start_line": String(page.startLine),
                        "end_line": String(page.endLine),
                        "page_source_type": page.sourceType.rawValue,
                        "content_hash": page.hash
                    ]
                )
            }
        } catch {
            // Fail-Open 兜底：扫描异常静默返回空，绝不崩溃
            return []
        }
    }

    /// 从代码片段中提取核心符号名
    private func extractSymbolHints(from code: String) -> [String] {
        var hints: Set<String> = []
        let lines = code.components(separatedBy: "\n")
        let keywords = ["func ", "class ", "struct ", "actor ", "enum ", "protocol ", "extension "]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for kw in keywords {
                if let range = trimmed.range(of: kw) {
                    let suffix = trimmed[range.upperBound...]
                    let name = suffix.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty {
                        hints.insert(String(name))
                    }
                    break
                }
            }
        }

        return Array(hints).sorted()
    }
}
