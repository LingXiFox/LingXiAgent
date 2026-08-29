import Foundation

/// L3 项目页存储。重建以文件版本为粒度，未变化文件的页面实例会被保留。
public actor ProjectPageStore {
    private var filesByProject: [String: [String: ScannedProjectFile]] = [:]
    private let symbolIndex: ProjectSymbolIndex
    private let symbolExtractor: SwiftSymbolExtractor
    private let rankingPolicy: ContextPageRankingPolicy

    public init(
        symbolIndex: ProjectSymbolIndex = ProjectSymbolIndex(),
        symbolExtractor: SwiftSymbolExtractor = SwiftSymbolExtractor(),
        rankingPolicy: ContextPageRankingPolicy = ContextPageRankingPolicy()
    ) {
        self.symbolIndex = symbolIndex
        self.symbolExtractor = symbolExtractor
        self.rankingPolicy = rankingPolicy
    }

    @discardableResult
    public func rebuildStaleFiles(using scanner: ProjectScanner) async throws -> ProjectPageStoreUpdate {
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
            await updateSymbols(projectRoot: scan.projectRoot, file: file)
        }
        for (path, file) in oldFiles where !isInitialIndex && newFiles[path] == nil {
            removedPaths.append(path)
            invalidatedPageIDs += file.pages.map(\.id)
            updatedFiles.removeValue(forKey: path)
            await symbolIndex.remove(projectRoot: scan.projectRoot, path: path)
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

    public func statistics(projectRoot: URL) async -> (files: Int, pages: Int, symbols: Int, symbolFiles: Int) {
        let files = filesByProject[ContextPage.projectIdentifier(for: projectRoot), default: [:]]
        let symbols = await symbolIndex.stats(projectRoot: ContextPage.projectIdentifier(for: projectRoot))
        return (files.count, files.values.reduce(0) { $0 + $1.pages.count }, symbols.symbolCount, symbols.fileCount)
    }

    public func search(projectRoot: URL, query: String, limit: Int = 20) async -> [ContextPage] {
        await searchResult(projectRoot: projectRoot, query: ContextQuery(currentTask: query), limit: limit).pages
    }

    public func search(projectRoot: URL, query: ContextQuery, limit: Int = 20) async -> [ContextPage] {
        await searchResult(projectRoot: projectRoot, query: query, limit: limit).pages
    }

    public func searchResult(projectRoot: URL, query: ContextQuery, limit: Int = 20) async -> ProjectPageSearchResult {
        let projectID = ContextPage.projectIdentifier(for: projectRoot)
        let clock = ContinuousClock()
        let totalStarted = clock.now
        var qualifiedMatches: [Symbol] = []
        var nameMatches: [Symbol] = []
        var prefixMatches: [Symbol] = []
        var qualifiedExactIDs = Set<SymbolID>()
        var fallbackExactIDs = Set<SymbolID>()
        let exactStarted = clock.now
        for group in query.symbolHintGroups {
            for (offset, hint) in group.enumerated() {
                let qualified = await symbolIndex.exactQualifiedName(projectRoot: projectID, name: hint)
                let names = await symbolIndex.exact(projectRoot: projectID, name: hint)
                qualifiedMatches += qualified
                nameMatches += names
                if offset == 0, hint.contains(".") {
                    qualifiedExactIDs.formUnion(qualified.map(\.id))
                } else {
                    fallbackExactIDs.formUnion(qualified.map(\.id))
                    fallbackExactIDs.formUnion(names.map(\.id))
                }
            }
        }
        let exactLookupMilliseconds = milliseconds(exactStarted.duration(to: clock.now))
        let prefixStarted = clock.now
        for hint in query.symbolHints {
            prefixMatches += await symbolIndex.prefix(projectRoot: projectID, prefix: hint)
        }
        let prefixLookupMilliseconds = milliseconds(prefixStarted.duration(to: clock.now))
        let mergeStarted = clock.now
        var symbolScoresByPageID: [String: Int] = [:]
        var exactIDs = Set<SymbolID>()
        var prefixIDs = Set<SymbolID>()
        let exactSymbols = Dictionary(
            (qualifiedMatches + nameMatches).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        for symbol in exactSymbols.values {
            let score = qualifiedExactIDs.contains(symbol.id) ? 1_200 : 900
            symbolScoresByPageID[symbol.pageID] = max(symbolScoresByPageID[symbol.pageID, default: 0], score)
            exactIDs.insert(symbol.id)
        }
        for symbol in prefixMatches {
            symbolScoresByPageID[symbol.pageID] = max(symbolScoresByPageID[symbol.pageID, default: 0], 500)
            if !exactIDs.contains(symbol.id) { prefixIDs.insert(symbol.id) }
        }
        let candidateMergeMilliseconds = milliseconds(mergeStarted.duration(to: clock.now))
        let rankingStarted = clock.now
        let candidates = rankingPolicy.rank(
            pages: pages(projectRoot: projectID),
            query: query,
            symbolScoresByPageID: symbolScoresByPageID
        )
        let rankingMilliseconds = milliseconds(rankingStarted.duration(to: clock.now))
        return ProjectPageSearchResult(
            pages: candidates.prefix(max(0, limit)).map { $0.page },
            symbolMetrics: SymbolSearchMetrics(
                hints: query.symbolHints.count,
                exactMatches: exactIDs.count,
                qualifiedExactMatches: qualifiedExactIDs.count,
                fallbackExactMatches: fallbackExactIDs.count,
                prefixMatches: prefixIDs.count,
                candidatePages: symbolScoresByPageID.count,
                exactLookupMilliseconds: exactLookupMilliseconds,
                prefixLookupMilliseconds: prefixLookupMilliseconds,
                candidateMergeMilliseconds: candidateMergeMilliseconds,
                rankingMilliseconds: rankingMilliseconds,
                totalMilliseconds: milliseconds(totalStarted.duration(to: clock.now)),
                lexicalCandidatePages: candidates.filter { $0.textScore > 0 }.count,
                currentSourceCandidates: candidates.filter { $0.page.sourceType == .sourceFile }.count,
                documentationCandidates: candidates.filter { $0.page.sourceType == .documentation }.count,
                referenceCandidates: candidates.filter { $0.page.sourceType == .referenceDocumentation || $0.page.sourceType == .researchArchive }.count
            )
        )
    }

    private func pages(projectRoot: String) -> [ContextPage] {
        filesByProject[projectRoot, default: [:]].values.flatMap(\.pages)
    }

    private func updateSymbols(projectRoot: String, file: ScannedProjectFile) async {
        guard URL(fileURLWithPath: file.path).pathExtension.lowercased() == "swift" else {
            await symbolIndex.remove(projectRoot: projectRoot, path: file.path)
            return
        }
        await symbolIndex.replace(
            projectRoot: projectRoot,
            path: file.path,
            symbols: symbolExtractor.extract(projectRoot: projectRoot, path: file.path, pages: file.pages)
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
