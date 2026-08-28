import Foundation

/// L3 项目页存储。重建以文件版本为粒度，未变化文件的页面实例会被保留。
public actor ProjectPageStore {
    private var filesByProject: [String: [String: ScannedProjectFile]] = [:]

    public init() {}

    @discardableResult
    public func rebuildStaleFiles(using scanner: ProjectScanner) throws -> ProjectPageStoreUpdate {
        let scanStartedAt = Date()
        let isInitialIndex = filesByProject[scanner.projectRoot] == nil
        let oldFiles = filesByProject[scanner.projectRoot, default: [:]]
        let scan = try scanner.scanManifest(reusing: oldFiles)
        let newFiles = Dictionary(uniqueKeysWithValues: scan.files.map { ($0.path, $0) })
        let initialIndexedPaths = isInitialIndex ? newFiles.keys.sorted() : []
        var updatedFiles = isInitialIndex ? [:] : oldFiles
        var rebuiltPaths: [String] = []
        var removedPaths: [String] = []
        var invalidatedPageIDs: [String] = []

        for (path, file) in newFiles where isInitialIndex || oldFiles[path]?.version != file.version {
            if !isInitialIndex {
                rebuiltPaths.append(path)
                invalidatedPageIDs += oldFiles[path]?.pages.map(\.id) ?? []
            }
            updatedFiles[path] = file
        }
        for (path, file) in oldFiles where !isInitialIndex && newFiles[path] == nil {
            removedPaths.append(path)
            invalidatedPageIDs += file.pages.map(\.id)
            updatedFiles.removeValue(forKey: path)
        }
        filesByProject[scan.projectRoot] = updatedFiles
        return ProjectPageStoreUpdate(
            initialIndexedPaths: initialIndexedPaths,
            rebuiltPaths: rebuiltPaths.sorted(),
            removedPaths: removedPaths.sorted(),
            invalidatedPageIDs: Array(Set(invalidatedPageIDs)).sorted(),
            filesChecked: scan.files.count,
            filesRebuilt: isInitialIndex ? 0 : rebuiltPaths.count,
            initialIndexedPages: isInitialIndex ? scan.pages.count : 0,
            scanMilliseconds: Int(Date().timeIntervalSince(scanStartedAt) * 1_000)
        )
    }

    public func page(projectRoot: URL, id: String) -> ContextPage? {
        pages(projectRoot: ContextPage.projectIdentifier(for: projectRoot)).first { $0.id == id }
    }

    public func pages(projectRoot: URL) -> [ContextPage] {
        pages(projectRoot: ContextPage.projectIdentifier(for: projectRoot))
    }

    public func statistics(projectRoot: URL) -> (files: Int, pages: Int) {
        let files = filesByProject[ContextPage.projectIdentifier(for: projectRoot), default: [:]]
        return (files.count, files.values.reduce(0) { $0 + $1.pages.count })
    }

    public func search(projectRoot: URL, query: String, limit: Int = 20) -> [ContextPage] {
        let tokens = lexicalTokens(query)
        let ranked = pages(projectRoot: ContextPage.projectIdentifier(for: projectRoot)).compactMap { page -> (ContextPage, Int)? in
            guard let score = lexicalScore(page, tokens: tokens) else { return nil }
            return (page, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.path != rhs.0.path { return lhs.0.path < rhs.0.path }
            if lhs.0.startLine != rhs.0.startLine { return lhs.0.startLine < rhs.0.startLine }
            return lhs.0.endLine < rhs.0.endLine
        }
        return Array(ranked.prefix(max(0, limit)).map(\.0))
    }

    private func pages(projectRoot: String) -> [ContextPage] {
        filesByProject[projectRoot, default: [:]].values.flatMap(\.pages)
    }

    private func lexicalTokens(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !["the", "and", "with", "this", "that", "please", "当前", "如何", "项目"].contains($0) }
    }

    private func lexicalScore(_ page: ContextPage, tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let content = page.content.lowercased()
        let path = page.path.lowercased()
        var score = 0
        for token in tokens {
            if path == token || path.hasSuffix("/\(token)") { score += 40 }
            if URL(fileURLWithPath: path).lastPathComponent.lowercased().contains(token) { score += 20 }
            var range = content.startIndex..<content.endIndex
            var occurrences = 0
            while let match = content.range(of: token, range: range) {
                occurrences += 1
                range = match.upperBound..<content.endIndex
            }
            score += occurrences
        }
        return score == 0 ? nil : score
    }
}
