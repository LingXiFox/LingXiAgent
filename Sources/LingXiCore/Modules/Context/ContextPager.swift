import Foundation
import LingXiProtocol

/// L2 是有字符上限的 LRU 工作集，页面超出上限时只保留在 L3。
public actor L2WorkingSet {
    private let characterBudget: Int
    private let policy: L2WorkingSetPolicy
    private let rankingPolicy: ContextPageRankingPolicy
    private var entries: [String: L2WorkingSetEntry] = [:]
    private var characterCount = 0
    private var clock: UInt64 = 0

    public init(
        characterBudget: Int = 48 * 1024,
        policy: L2WorkingSetPolicy = L2WorkingSetPolicy(),
        rankingPolicy: ContextPageRankingPolicy = ContextPageRankingPolicy()
    ) {
        self.characterBudget = max(0, characterBudget)
        self.policy = policy
        self.rankingPolicy = rankingPolicy
    }

    public func page(id: String) -> ContextPage? {
        guard var entry = entries[id] else { return nil }
        entry.lastUsed = nextClock()
        entry.useCount &+= 1
        entries[id] = entry
        return entry.page
    }

    public func search(projectRoot: URL, query: String, limit: Int) -> [ContextPage] {
        search(projectRoot: projectRoot, query: ContextQuery(currentTask: query), limit: limit)
    }

    public func search(projectRoot: URL, query: ContextQuery, limit: Int) -> [ContextPage] {
        let projectID = ContextPage.projectIdentifier(for: projectRoot)
        let pages = rankingPolicy.rank(
            pages: entries.values.filter { $0.page.projectRoot == projectID }.map(\.page),
            query: query,
            symbolScoresByPageID: [:]
        ).prefix(max(0, limit)).map { $0.page }
        touch(pages.map(\.id))
        return pages
    }

    @discardableResult
    public func promote(_ pages: [ContextPage], queryRelevance: Double = 0, taskAffinity: Double = 0, explicitPin: Bool = false) -> L2PromotionResult {
        var admitted: [ContextPage] = []
        var evicted: [ContextPage] = []
        var seen = Set<String>()
        for page in pages where seen.insert(page.id).inserted {
            if let old = entries.removeValue(forKey: page.id) {
                characterCount -= old.page.characterCount
            }
            guard page.characterCount <= characterBudget else { continue }
            while characterCount + page.characterCount > characterBudget, let victimID = policy.evictionCandidate(in: entries, clock: clock), let victim = entries.removeValue(forKey: victimID) {
                characterCount -= victim.page.characterCount
                evicted.append(victim.page)
            }
            entries[page.id] = L2WorkingSetEntry(page: page, lastUsed: nextClock(), useCount: 1, queryRelevance: queryRelevance, taskAffinity: taskAffinity, explicitPin: explicitPin)
            characterCount += page.characterCount
            admitted.append(page)
        }
        return L2PromotionResult(admitted: admitted, evicted: evicted)
    }

    public func touch(_ pageIDs: [String]) {
        var seen = Set<String>()
        for id in pageIDs where seen.insert(id).inserted {
            guard var entry = entries[id] else { continue }
            entry.lastUsed = nextClock()
            entry.useCount &+= 1
            entries[id] = entry
        }
    }

    public func invalidate(_ pageIDs: [String]) {
        var seen = Set<String>()
        for id in pageIDs where seen.insert(id).inserted {
            if let removed = entries.removeValue(forKey: id) {
                characterCount -= removed.page.characterCount
            }
        }
    }

    public func invalidate(projectRoot: URL) {
        let projectID = ContextPage.projectIdentifier(for: projectRoot)
        invalidate(entries.values.filter { $0.page.projectRoot == projectID }.map { $0.page.id })
    }

    public func metrics() -> L2WorkingSetMetrics {
        L2WorkingSetMetrics(pageCount: entries.count, characterCount: characterCount)
    }

    private func nextClock() -> UInt64 {
        clock &+= 1
        return clock
    }

}

/// 将确定性 L3 查询结果按项目预算装配为模型可用上下文，并维护 L2 命中统计。
public actor ContextPager {
    private let store: ProjectPageStore
    private let workingSet: L2WorkingSet
    private let projectCharacterBudget: Int
    private var hits = 0
    private var misses = 0
    private var pageFaults = 0
    private var l3Queries = 0
    private var l3Candidates = 0
    private var l3Materializations = 0
    private var staleRebuilds = 0
    private var initialIndexedFiles = 0
    private var promotions = 0
    private var evictions = 0
    private var selectedPages = 0
    private var injectedCharacters = 0
    private var retrievalMilliseconds = 0.0
    private var materializationMilliseconds = 0.0
    private var queryCharacters = 0
    private var queryTerms = 0
    private var candidatePages = 0
    private var candidateCharacters = 0
    private var latestSelectedPages = 0
    private var latestSelectedCharacters = 0
    private var latestInjectedPages = 0
    private var latestInjectedCharacters = 0
    private var filesChecked = 0
    private var filesRebuilt = 0
    private var scanMilliseconds = 0
    private var symbolHints = 0
    private var symbolExactMatches = 0
    private var symbolQualifiedExactMatches = 0
    private var symbolFallbackExactMatches = 0
    private var symbolPrefixMatches = 0
    private var symbolCandidatePages = 0
    private var symbolHintExtractionMilliseconds = 0.0
    private var symbolExactLookupMilliseconds = 0.0
    private var symbolPrefixLookupMilliseconds = 0.0
    private var symbolCandidateMergeMilliseconds = 0.0
    private var symbolRankingMilliseconds = 0.0
    private var symbolTotalMilliseconds = 0.0
    private var lexicalCandidatePages = 0
    private var currentSourceCandidates = 0
    private var documentationCandidates = 0
    private var referenceCandidates = 0
    private var relationHints = 0
    private var directReferenceHits = 0
    private var dependencyHits = 0
    private var relatedPages = 0
    private var referenceResolutionMilliseconds = 0.0
    private var referenceExpansionMilliseconds = 0.0

    public init(store: ProjectPageStore, workingSet: L2WorkingSet, projectCharacterBudget: Int = 48 * 1024) {
        self.store = store
        self.workingSet = workingSet
        self.projectCharacterBudget = max(0, projectCharacterBudget)
    }

    @discardableResult
    public func rebuildStaleFiles(using scanner: ProjectScanner) async throws -> ProjectPageStoreUpdate {
        let update = try await store.rebuildStaleFiles(using: scanner)
        await workingSet.invalidate(update.invalidatedPageIDs)
        initialIndexedFiles += update.initialIndexedPaths.count
        staleRebuilds += update.rebuiltPaths.count
        filesChecked += update.filesChecked
        filesRebuilt += update.filesRebuilt
        scanMilliseconds += update.scanMilliseconds
        return update
    }

    public func query(projectRoot: URL, query: String, limit: Int = 20) async -> ContextPagerResult {
        await self.query(projectRoot: projectRoot, query: ContextQuery(currentTask: query), limit: limit)
    }

    public func query(projectRoot: URL, query: ContextQuery, limit: Int = 20) async -> ContextPagerResult {
        guard limit > 0 else { return ContextPagerResult(pages: [], metrics: metrics()) }
        let clock = ContinuousClock()
        let retrievalStart = clock.now
        let l2Candidates = await workingSet.search(projectRoot: projectRoot, query: query, limit: limit)
        let candidates: [ContextPage]
        let symbolMetrics: SymbolSearchMetrics
        let requiresStructuralCoverage = !query.symbolHints.isEmpty
        if l2Candidates.isEmpty || requiresStructuralCoverage {
            let result = await store.searchResult(projectRoot: projectRoot, query: query, limit: .max)
            candidates = result.pages
            symbolMetrics = result.symbolMetrics
            l3Queries += 1
            l3Candidates += candidates.count
        } else {
            candidates = l2Candidates
            symbolMetrics = .zero
        }
        retrievalMilliseconds += milliseconds(retrievalStart.duration(to: clock.now))
        queryCharacters = query.text.count
        queryTerms = query.terms.count
        candidatePages = candidates.count
        candidateCharacters = candidates.reduce(0) { $0 + $1.characterCount }
        symbolHints = symbolMetrics.hints
        symbolExactMatches = symbolMetrics.exactMatches
        symbolQualifiedExactMatches = symbolMetrics.qualifiedExactMatches
        symbolFallbackExactMatches = symbolMetrics.fallbackExactMatches
        symbolPrefixMatches = symbolMetrics.prefixMatches
        symbolCandidatePages = symbolMetrics.candidatePages
        symbolHintExtractionMilliseconds = query.symbolHintExtractionMilliseconds
        symbolExactLookupMilliseconds = symbolMetrics.exactLookupMilliseconds
        symbolPrefixLookupMilliseconds = symbolMetrics.prefixLookupMilliseconds
        symbolCandidateMergeMilliseconds = symbolMetrics.candidateMergeMilliseconds
        symbolRankingMilliseconds = symbolMetrics.rankingMilliseconds
        symbolTotalMilliseconds = query.symbolHintExtractionMilliseconds + symbolMetrics.totalMilliseconds
        lexicalCandidatePages = symbolMetrics.lexicalCandidatePages
        currentSourceCandidates = symbolMetrics.currentSourceCandidates
        documentationCandidates = symbolMetrics.documentationCandidates
        referenceCandidates = symbolMetrics.referenceCandidates
        relationHints = symbolMetrics.relationHints
        directReferenceHits = symbolMetrics.directReferenceHits
        dependencyHits = symbolMetrics.dependencyHits
        relatedPages = symbolMetrics.relatedPages
        referenceResolutionMilliseconds = symbolMetrics.resolutionMilliseconds
        referenceExpansionMilliseconds = symbolMetrics.expansionMilliseconds
        var selected: [ContextPage] = []
        var seenIDs = Set<String>()
        var seenContent = Set<String>()
        var characters = 0
        for page in candidates where selected.count < limit {
            guard seenIDs.insert(page.id).inserted, seenContent.insert(page.content).inserted,
                  characters + page.characterCount <= projectCharacterBudget else {
                continue
            }
            selected.append(page)
            characters += page.characterCount
        }
        let materializationStart = clock.now
        let before = (hits, misses, pageFaults, promotions, evictions)
        let resolved = await resolve(selected)
        let materialization = milliseconds(materializationStart.duration(to: clock.now))
        materializationMilliseconds += materialization
        l3Materializations += resolved.count
        selectedPages += resolved.count
        injectedCharacters += resolved.reduce(0) { $0 + $1.characterCount }
        latestSelectedPages = selected.count
        latestSelectedCharacters = characters
        return ContextPagerResult(
            pages: resolved,
            metrics: metrics(),
            candidatePageCount: candidates.count,
            candidateCharacterCount: candidates.reduce(0) { $0 + $1.characterCount },
            selectedPageCount: selected.count,
            selectedCharacterCount: characters,
            turnMetrics: ContextPagingTurnMetrics(
                lookups: (hits - before.0) + (misses - before.1), hits: hits - before.0, misses: misses - before.1,
                pageFaults: pageFaults - before.2, promotions: promotions - before.3, evictions: evictions - before.4,
                candidatePages: candidates.count, candidateCharacters: candidates.reduce(0) { $0 + $1.characterCount },
                selectedPages: selected.count, selectedCharacters: characters,
                retrievalMilliseconds: milliseconds(retrievalStart.duration(to: materializationStart)), materializationMilliseconds: materialization,
                symbolHints: symbolMetrics.hints, symbolExactMatches: symbolMetrics.exactMatches,
                symbolQualifiedExactMatches: symbolMetrics.qualifiedExactMatches, symbolFallbackExactMatches: symbolMetrics.fallbackExactMatches,
                symbolPrefixMatches: symbolMetrics.prefixMatches, symbolCandidatePages: symbolMetrics.candidatePages,
                symbolHintExtractionMilliseconds: query.symbolHintExtractionMilliseconds,
                symbolExactLookupMilliseconds: symbolMetrics.exactLookupMilliseconds,
                symbolPrefixLookupMilliseconds: symbolMetrics.prefixLookupMilliseconds,
                symbolCandidateMergeMilliseconds: symbolMetrics.candidateMergeMilliseconds,
                symbolRankingMilliseconds: symbolMetrics.rankingMilliseconds,
                symbolTotalMilliseconds: query.symbolHintExtractionMilliseconds + symbolMetrics.totalMilliseconds,
                lexicalCandidatePages: symbolMetrics.lexicalCandidatePages,
                currentSourceCandidates: symbolMetrics.currentSourceCandidates,
                documentationCandidates: symbolMetrics.documentationCandidates,
                referenceCandidates: symbolMetrics.referenceCandidates,
                relationHints: symbolMetrics.relationHints, directReferenceHits: symbolMetrics.directReferenceHits,
                dependencyHits: symbolMetrics.dependencyHits, relatedPages: symbolMetrics.relatedPages,
                referenceResolutionMilliseconds: symbolMetrics.resolutionMilliseconds,
                referenceExpansionMilliseconds: symbolMetrics.expansionMilliseconds
            )
        )
    }

    public func page(projectRoot: URL, id: String) async -> ContextPage? {
        guard let stored = await store.page(projectRoot: projectRoot, id: id) else {
            misses += 1
            return nil
        }
        return (await resolve([stored])).first
    }

    public func metrics() -> ContextPagerMetrics {
        ContextPagerMetrics(hits: hits, misses: misses, pageFaults: pageFaults)
    }

    public func invalidate(projectRoot: URL) async {
        await workingSet.invalidate(projectRoot: projectRoot)
    }

    public func debugMetrics(projectRoot: URL) async -> ContextPagingDebugMetrics {
        let l2 = await workingSet.metrics()
        let l3 = await store.statistics(projectRoot: projectRoot)
        return ContextPagingDebugMetrics(
            queryCharacters: queryCharacters,
            queryTerms: queryTerms,
            candidatePages: candidatePages,
            candidateCharacters: candidateCharacters,
            selectedPages: latestSelectedPages,
            selectedCharacters: latestSelectedCharacters,
            injectedPages: latestInjectedPages,
            injectedCharacters: latestInjectedCharacters,
            filesChecked: filesChecked,
            filesRebuilt: filesRebuilt,
            scanMilliseconds: scanMilliseconds,
            initialIndexedFiles: initialIndexedFiles,
            l2Lookups: hits + misses,
            l2Hits: hits,
            l2Misses: misses,
            l2Pages: l2.pageCount,
            l2Characters: l2.characterCount,
            l3Pages: l3.pages,
            l3Queries: l3Queries,
            l3Candidates: l3Candidates,
            l3Materializations: l3Materializations,
            staleRebuilds: staleRebuilds,
            pageFaults: pageFaults,
            promotions: promotions,
            evictions: evictions,
            retrievalMilliseconds: retrievalMilliseconds,
            materializationMilliseconds: materializationMilliseconds,
            symbolCount: l3.symbols,
            symbolIndexedFiles: l3.symbolFiles,
            symbolHints: symbolHints,
            symbolExactMatches: symbolExactMatches,
            symbolQualifiedExactMatches: symbolQualifiedExactMatches,
            symbolFallbackExactMatches: symbolFallbackExactMatches,
            symbolPrefixMatches: symbolPrefixMatches,
            symbolCandidatePages: symbolCandidatePages,
            symbolHintExtractionMilliseconds: symbolHintExtractionMilliseconds,
            symbolExactLookupMilliseconds: symbolExactLookupMilliseconds,
            symbolPrefixLookupMilliseconds: symbolPrefixLookupMilliseconds,
            symbolCandidateMergeMilliseconds: symbolCandidateMergeMilliseconds,
            symbolRankingMilliseconds: symbolRankingMilliseconds,
            symbolTotalMilliseconds: symbolTotalMilliseconds,
            lexicalCandidatePages: lexicalCandidatePages,
            currentSourceCandidates: currentSourceCandidates,
            documentationCandidates: documentationCandidates,
            referenceCandidates: referenceCandidates
            , referenceCount: l3.references.referenceCount, resolvedReferenceCount: l3.references.resolvedCount,
            ambiguousReferenceCount: l3.references.ambiguousCount, unresolvedReferenceCount: l3.references.unresolvedCount,
            dependencyCount: l3.references.dependencyCount, referenceIndexedFiles: l3.references.indexedFileCount,
            relationHints: relationHints, directReferenceHits: directReferenceHits, dependencyHits: dependencyHits,
            relatedPages: relatedPages, referenceResolutionMilliseconds: referenceResolutionMilliseconds,
            referenceExpansionMilliseconds: referenceExpansionMilliseconds
        )
    }

    public func recordInjection(_ pages: [ContextPage]) {
        latestInjectedPages = pages.count
        latestInjectedCharacters = pages.reduce(0) { $0 + $1.characterCount }
    }

    /// Session/Derived L3 与 Project L2/L3 共用本 pager 进入 L1，绝不产生 Provider tool role。
    public func pageInDerived(store: DerivedContextStore, sessionID: SessionID, query: String, remainingTokens: Int) async -> [ContextEntry] {
        var remaining = max(0, remainingTokens)
        var entries: [ContextEntry] = []
        let estimator = ConservativeTokenEstimator()
        for page in await store.search(sessionID: sessionID, query: query, limit: 4) {
            let entry = ContextEntry(messageID: MessageID(page.id), role: .system, source: .derivedPage, part: .text("[Session context]\n\(page.content)"))
            let cost = estimator.estimate(entries: [entry])
            guard cost <= remaining else { break }
            entries.append(entry)
            remaining -= cost
        }
        return entries
    }

    private func resolve(_ pages: [ContextPage]) async -> [ContextPage] {
        var resolved: [ContextPage] = []
        var faults: [ContextPage] = []
        for page in pages {
            let cached = await workingSet.page(id: page.id)
            if let cached, cached.hash == page.hash, cached.version == page.version {
                hits += 1
                resolved.append(cached)
            } else {
                if cached != nil { await workingSet.invalidate([page.id]) }
                misses += 1
                pageFaults += 1
                faults.append(page)
                resolved.append(page)
            }
        }
        let promotion = await workingSet.promote(faults)
        promotions += promotion.admitted.count
        evictions += promotion.evicted.count
        return resolved
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func lexicalTerms(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}
