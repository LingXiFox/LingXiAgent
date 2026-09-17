import Foundation
import LingXiProtocol

/// 项目文档只读检索适配器 (ProjectDocumentRetrievalProvider)
/// 针对 AGENTS.md, README.md, Docs/*.md 等规范与架构文档，
/// 严格复用现有 ProjectScanner 扫描与切片能力，坚决不构建独立重复的文件缓存体系。
public struct ProjectDocumentRetrievalProvider: RetrievalProvider, Sendable {
    public let sourceType: RetrievalSourceType = .projectDocument
    public let scanner: ProjectScanner

    public init(scanner: ProjectScanner) {
        self.scanner = scanner
    }

    public init(projectRoot: URL) {
        self.scanner = ProjectScanner(root: projectRoot)
    }

    /// 枚举项目文档切片并映射为 RetrievalChunk
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
            // 筛选出文档类、Markdown 文件及项目规范
            let docPages = scan.pages.filter { page in
                isDocumentPage(page)
            }

            return docPages.map { page in
                let handle = RawSourceHandle.projectDocument(
                    path: page.path,
                    startLine: page.startLine,
                    endLine: page.endLine
                )

                let headings = extractHeadings(from: page.content)

                return RetrievalChunk(
                    chunkID: "doc:\(page.path)#L\(page.startLine)-L\(page.endLine)",
                    sourceType: .projectDocument,
                    sourceID: page.path,
                    rawSourceHandle: handle,
                    indexableText: page.content,
                    symbolHints: headings,
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
            // Fail-Open 保护
            return []
        }
    }

    private func isDocumentPage(_ page: ContextPage) -> Bool {
        RetrievalCorpusClassifier.isDocumentPath(page.path, pageSourceType: page.sourceType)
    }

    /// 提取 Markdown 标题层级作为结构化语义提示
    private func extractHeadings(from markdown: String) -> [String] {
        var headings: [String] = []
        let lines = markdown.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let text = trimmed.drop(while: { $0 == "#" || $0.isWhitespace })
                if !text.isEmpty {
                    headings.append(String(text))
                }
            }
        }

        return headings
    }
}
