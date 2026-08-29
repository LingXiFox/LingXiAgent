import Foundation

/// L3 项目页存储。重建以文件版本为粒度，未变化文件的页面实例会被保留。
public actor ProjectPageStore {
    private var filesByProject: [String: [String: ScannedProjectFile]] = [:]
    private let symbolIndex: ProjectSymbolIndex
    private let symbolExtractor: SwiftSymbolExtractor
    private let referenceIndex: ProjectReferenceIndex
    private let referenceExtractor: SwiftReferenceExtractor
    private let rankingPolicy: ContextPageRankingPolicy
    private let persistence: SQLitePersistenceStore?

    public init(
        symbolIndex: ProjectSymbolIndex = ProjectSymbolIndex(),
        symbolExtractor: SwiftSymbolExtractor = SwiftSymbolExtractor(),
        referenceIndex: ProjectReferenceIndex = ProjectReferenceIndex(),
        referenceExtractor: SwiftReferenceExtractor = SwiftReferenceExtractor(),
        rankingPolicy: ContextPageRankingPolicy = ContextPageRankingPolicy(),
        persistence: SQLitePersistenceStore? = nil
    ) {
        self.symbolIndex = symbolIndex
        self.symbolExtractor = symbolExtractor
        self.referenceIndex = referenceIndex
        self.referenceExtractor = referenceExtractor
        self.rankingPolicy = rankingPolicy
        self.persistence = persistence
    }

    @discardableResult
    public func rebuildStaleFiles(using scanner: ProjectScanner) async throws -> ProjectPageStoreUpdate {
        let scanStartedAt = Date()
        _ = try await persistence?.invalidateCachesIfFormatMismatch()
        let isInitialIndex = filesByProject[scanner.projectRoot] == nil
        let oldFiles = filesByProject[scanner.projectRoot, default: [:]]
        let rawScan = try scanner.scanManifest(reusing: oldFiles)
        let scan = try await bindStableFileIdentities(rawScan)
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
            await updateReferences(projectRoot: scan.projectRoot, file: file)
        }
        for (path, file) in oldFiles where !isInitialIndex && newFiles[path] == nil {
            removedPaths.append(path)
            invalidatedPageIDs += file.pages.map(\.id)
            updatedFiles.removeValue(forKey: path)
            await symbolIndex.remove(projectRoot: scan.projectRoot, path: path)
            await referenceIndex.removeReferences(projectRoot: scan.projectRoot, forPath: path)
        }
        filesByProject[scan.projectRoot] = updatedFiles
        await resolveReferences(projectRoot: scan.projectRoot)
        if let persistence {
            let symbols = await symbolIndex.allSymbols(projectRoot: scan.projectRoot)
            let references = await referenceIndex.references(projectRoot: scan.projectRoot)
            try await persistence.replaceProjectCache(pages: updatedFiles.values.flatMap(\.pages), symbols: symbols, references: references, dependencies: references.map(DependencyEdge.init(reference:)))
        }
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

    public func statistics(projectRoot: URL) async -> (files: Int, pages: Int, symbols: Int, symbolFiles: Int, references: ReferenceIndexStats) {
        let files = filesByProject[ContextPage.projectIdentifier(for: projectRoot), default: [:]]
        let symbols = await symbolIndex.stats(projectRoot: ContextPage.projectIdentifier(for: projectRoot))
        return (files.count, files.values.reduce(0) { $0 + $1.pages.count }, symbols.symbolCount, symbols.fileCount, await referenceIndex.stats(projectRoot: ContextPage.projectIdentifier(for: projectRoot)))
    }

    public func resources(projectRoot: URL) async -> (pages: [ContextPage], symbols: [Symbol], references: [ProjectReference]) {
        let id = ContextPage.projectIdentifier(for: projectRoot)
        return (pages(projectRoot: id), await symbolIndex.allSymbols(projectRoot: id), await referenceIndex.references(projectRoot: id))
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
        var relatedPageIDs = Set<String>()
        var referenceLookup = ReferenceLookupResult()
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
        let resolutionStarted = clock.now
        let relatedSymbols = Set(exactSymbols.values.map(\.id) + prefixMatches.map(\.id))
        if !relatedSymbols.isEmpty || !query.relationHints.isEmpty {
            referenceLookup = await referenceIndex.lookupRelatedPages(
                projectRoot: projectID,
                symbolIDs: relatedSymbols,
                targetNames: Set(query.symbolHints),
                maximumPages: 8,
                maximumDepth: 1
            )
            relatedPageIDs = Set(referenceLookup.pageIDs)
        }
        let referenceResolutionMilliseconds = milliseconds(resolutionStarted.duration(to: clock.now))
        var referenceScoresByPageID: [String: Int] = [:]
        for pageID in relatedPageIDs { referenceScoresByPageID[pageID] = 800 }
        let expansionMilliseconds = milliseconds(resolutionStarted.duration(to: clock.now)) - referenceResolutionMilliseconds
        let candidateMergeMilliseconds = milliseconds(mergeStarted.duration(to: clock.now))
        let rankingStarted = clock.now
        let candidates = rankingPolicy.rank(
            pages: pages(projectRoot: projectID),
            query: query,
            symbolScoresByPageID: symbolScoresByPageID,
            referenceScoresByPageID: referenceScoresByPageID
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
                referenceCandidates: candidates.filter { $0.page.sourceType == .referenceDocumentation || $0.page.sourceType == .researchArchive }.count,
                relationHints: query.relationHints.count,
                directReferenceHits: referenceLookup.directReferenceHits,
                dependencyHits: referenceLookup.dependencyHits,
                relatedPages: relatedPageIDs.count,
                resolutionMilliseconds: referenceResolutionMilliseconds,
                expansionMilliseconds: expansionMilliseconds
            )
        )
    }

    private func pages(projectRoot: String) -> [ContextPage] {
        filesByProject[projectRoot, default: [:]].values.flatMap(\.pages)
    }

    private func bindStableFileIdentities(_ scan: ProjectScan) async throws -> ProjectScan {
        guard let persistence else { return scan }
        let main = try await persistence.mainRootBinding()
        let existing = try await persistence.files().filter { $0.rootBindingID == main.id && $0.state == "active" }
        let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath.rawValue, $0) })
        let incomingPaths = Set(scan.files.map(\.path))
        let missing = existing.filter { !incomingPaths.contains($0.relativePath.rawValue) }
        let newFiles = scan.files.filter { byPath[$0.path] == nil }
        let uniqueNewByHash = Dictionary(grouping: newFiles, by: \.version).filter { $0.value.count == 1 }
        let uniqueMissingByHash = Dictionary(grouping: missing, by: \.contentHash).filter { $0.value.count == 1 }
        var moved: [String: ProjectFileBinding] = [:]
        for (hash, candidates) in uniqueNewByHash {
            guard let old = uniqueMissingByHash[hash]?.first, let file = candidates.first else { continue }
            try await persistence.relocateFile(old.id, rootBindingID: main.id, relativePath: try ProjectRelativePath(file.path))
            moved[file.path] = try await persistence.file(old.id)
        }
        for old in missing where !moved.values.contains(where: { $0.id == old.id }) {
            try await persistence.markFileMissing(old.id)
        }
        var files: [ScannedProjectFile] = []
        for file in scan.files {
            let binding: ProjectFileBinding
            if let movedBinding = moved[file.path] { binding = movedBinding }
            else if let existingBinding = byPath[file.path] {
                binding = try await persistence.upsertFile(
                    rootBindingID: main.id,
                    relativePath: try ProjectRelativePath(file.path),
                    contentHash: file.version,
                    version: file.version
                )
                assert(binding.id == existingBinding.id)
            }
            else { binding = try await persistence.upsertFile(rootBindingID: main.id, relativePath: try ProjectRelativePath(file.path), contentHash: file.version, version: file.version) }
            files.append(file.binding(projectID: persistence.projectID, fileID: binding.id))
        }
        return ProjectScan(projectRoot: scan.projectRoot, files: files)
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

    private func updateReferences(projectRoot: String, file: ScannedProjectFile) async {
        guard URL(fileURLWithPath: file.path).pathExtension.lowercased() == "swift" else {
            await referenceIndex.removeReferences(projectRoot: projectRoot, forPath: file.path)
            return
        }
        let symbols = await symbolIndex.symbols(projectRoot: projectRoot, path: file.path)
        await referenceIndex.replaceReferences(
            projectRoot: projectRoot,
            forPath: file.path,
            references: referenceExtractor.extract(projectRoot: projectRoot, path: file.path, pages: file.pages, symbols: symbols)
        )
    }

    private func resolveReferences(projectRoot: String) async {
        let unresolved = await referenceIndex.references(projectRoot: projectRoot)
        let symbols = await symbolIndex.allSymbols(projectRoot: projectRoot)
        let byQualifiedName = Dictionary(grouping: symbols, by: \.qualifiedName)
        let byName = Dictionary(grouping: symbols, by: \.name)
        var resolved: [ProjectReference] = []
        for reference in unresolved {
            guard reference.kind != .import else { resolved.append(reference); continue }
            var candidates = byQualifiedName[reference.targetName, default: []]
            var quality: ReferenceResolutionQuality = .exactResolved
            if candidates.isEmpty {
                candidates = byName[reference.targetName, default: []]
                quality = .symbolNameResolved
            }
            if candidates.count > 1 {
                let sameFile = candidates.filter { $0.path == reference.sourcePath }
                if sameFile.count == 1 { candidates = sameFile }
                else { resolved.append(reference.resolving(to: candidates, quality: .ambiguous)); continue }
            }
            if candidates.isEmpty { resolved.append(reference.resolving(to: [], quality: reference.receiverHint == nil ? .unresolved : .receiverHint)) }
            else { resolved.append(reference.resolving(to: candidates, quality: quality)) }
        }
        await referenceIndex.replaceResolved(projectRoot: projectRoot, references: resolved)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
