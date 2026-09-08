import Foundation
import LingXiProtocol

public struct CachePriorityWeights: Sendable {
    public let recency: Double
    public let frequency: Double
    public let relevance: Double
    public let taskAffinity: Double
    public let activeFileAffinity: Double
    public let explicitReuse: Double
    public let pin: Double
    public let tokenCostPenalty: Double

    public init(
        recency: Double = 1.0,
        frequency: Double = 0.5,
        relevance: Double = 2.0,
        taskAffinity: Double = 0.5,
        activeFileAffinity: Double = 1.0,
        explicitReuse: Double = 3.0,
        pin: Double = 10_000.0,
        tokenCostPenalty: Double = 0.001
    ) {
        self.recency = recency
        self.frequency = frequency
        self.relevance = relevance
        self.taskAffinity = taskAffinity
        self.activeFileAffinity = activeFileAffinity
        self.explicitReuse = explicitReuse
        self.pin = pin
        self.tokenCostPenalty = tokenCostPenalty
    }
}

public struct L1ResidentPage: Sendable, Equatable {
    public let page: ContextPage
    public let tokens: Int
    public var lastUsed: UInt64
    public var accessCount: Int
    public var retrievalRelevance: Double
    public var isPinned: Bool
    public var inclusionReason: String

    public init(
        page: ContextPage,
        tokens: Int? = nil,
        lastUsed: UInt64,
        accessCount: Int = 1,
        retrievalRelevance: Double = 1.0,
        isPinned: Bool = false,
        inclusionReason: String = "Explicit retrieval"
    ) {
        self.page = page
        self.tokens = tokens ?? max(1, page.characterCount / 3)
        self.lastUsed = lastUsed
        self.accessCount = accessCount
        self.retrievalRelevance = retrievalRelevance
        self.isPinned = isPinned
        self.inclusionReason = inclusionReason
    }
}

public struct WarmL2Entry: Sendable, Equatable {
    public let id: String
    public let page: ContextPage?
    public let derivedPage: DerivedContextPage?
    public let tokens: Int
    public var lastUsed: UInt64
    public var accessCount: Int
    public var inclusionReason: String

    public init(
        id: String,
        page: ContextPage? = nil,
        derivedPage: DerivedContextPage? = nil,
        tokens: Int,
        lastUsed: UInt64,
        accessCount: Int = 1,
        inclusionReason: String = "Warm cache"
    ) {
        self.id = id
        self.page = page
        self.derivedPage = derivedPage
        self.tokens = tokens
        self.lastUsed = lastUsed
        self.accessCount = accessCount
        self.inclusionReason = inclusionReason
    }
}

/// Cache Controller 负责三级缓存的加权调度与 L1/L2/L3 Residency 管理。
/// 模型只负责声明检索意图 (context_search)，调度决策完全由 Cache Controller 驱动。
public actor ContextCacheController {
    public let policy: EffectiveContextPolicy
    private let weights: CachePriorityWeights
    private let contextPager: ContextPager
    private let scanner: ProjectScanner
    public nonisolated let compactor: ContextCompactor?
    private var clock: UInt64 = 0

    // Per-session L1 resident dynamic pages
    private var residentPagesBySession: [SessionID: [String: L1ResidentPage]] = [:]
    // Per-session session-level base L1 tokens (messages + system prompt)
    private var sessionL1BaseTokens: [SessionID: Int] = [:]
    private var sessionL1BaseCount: [SessionID: Int] = [:]
    // Last Provider input tokens recorded during context build for inference
    private var lastProviderInputTokensBySession: [SessionID: Int] = [:]
    // Per-session L2 warm cache entries
    private var warmL2EntriesBySession: [SessionID: [String: WarmL2Entry]] = [:]
    // Per-session paged-in derived pages
    private var residentDerivedPagesBySession: [SessionID: [String: DerivedContextPage]] = [:]

    // Paging statistics per session
    private var pageInsBySession: [SessionID: Int] = [:]
    private var pageOutsBySession: [SessionID: Int] = [:]
    private var promotionsBySession: [SessionID: Int] = [:]
    private var demotionsBySession: [SessionID: Int] = [:]

    public init(
        contextPager: ContextPager,
        scanner: ProjectScanner,
        compactor: ContextCompactor? = nil,
        policy: EffectiveContextPolicy = EffectiveContextPolicy(),
        weights: CachePriorityWeights = CachePriorityWeights()
    ) {
        self.contextPager = contextPager
        self.scanner = scanner
        self.compactor = compactor
        self.policy = policy
        self.weights = weights
    }

    // Convenience initializer preserving existing calls
    public init(
        contextPager: ContextPager,
        scanner: ProjectScanner,
        compactor: ContextCompactor? = nil,
        maxL1ResidentCharacters: Int,
        weights: CachePriorityWeights = CachePriorityWeights()
    ) {
        self.contextPager = contextPager
        self.scanner = scanner
        self.compactor = compactor
        self.policy = EffectiveContextPolicy(
            addressableBudget: 1_048_576,
            modelWindow: 1_048_576,
            economicThreshold: 272_000,
            reserve: 22_000,
            l1Target: max(1, maxL1ResidentCharacters / 3),
            l1SoftLimit: max(2, Int(Double(maxL1ResidentCharacters / 3) * 1.07)),
            l1HardLimit: max(3, Int(Double(maxL1ResidentCharacters / 3) * 1.14)),
            l2Max: 350_000,
            l3Capacity: 456_576
        )
        self.weights = weights
    }

    /// 记录指定 Session 的基础 L1 token 数与条目数（当前 resident working set）
    public func recordSessionL1Tokens(sessionID: SessionID, tokens: Int, count: Int? = nil) {
        sessionL1BaseTokens[sessionID] = tokens
        if let count { sessionL1BaseCount[sessionID] = count }
    }

    /// 记录最近一次 Provider 推理实际构建发送的 input token 数（与当前 resident working set 明确分离）
    public func recordProviderInputTokens(sessionID: SessionID, tokens: Int) {
        lastProviderInputTokensBySession[sessionID] = tokens
    }

    /// 最近一次 Provider 推理的 input token 数
    public func lastProviderInputTokens(for sessionID: SessionID) -> Int? {
        lastProviderInputTokensBySession[sessionID]
    }

    /// L1 当前占用 token 数
    public func l1UsageTokens(for sessionID: SessionID) -> Int {
        let dynamicTokens = residentPagesBySession[sessionID]?.values.reduce(0) { $0 + $1.tokens } ?? 0
        let baseTokens = sessionL1BaseTokens[sessionID] ?? 0
        return dynamicTokens + baseTokens
    }

    /// L1 条目数
    public func l1Count(for sessionID: SessionID) -> Int {
        let dynamicCount = residentPagesBySession[sessionID]?.count ?? 0
        let baseCount = sessionL1BaseCount[sessionID] ?? ((sessionL1BaseTokens[sessionID] ?? 0) > 0 ? 1 : 0)
        return dynamicCount + baseCount
    }

    /// L2 当前占用 token 数
    public func l2UsageTokens(for sessionID: SessionID) -> Int {
        warmL2EntriesBySession[sessionID]?.values.reduce(0) { $0 + $1.tokens } ?? 0
    }

    /// L2 条目数
    public func l2Count(for sessionID: SessionID) -> Int {
        warmL2EntriesBySession[sessionID]?.count ?? 0
    }

    /// L3 当前占用 token 数
    public func l3UsageTokens(for sessionID: SessionID) async -> Int {
        guard let compactor else { return 0 }
        let pages = await compactor.derivedStore.pages(sessionID: sessionID)
        return pages.reduce(0) { $0 + $1.tokenEstimate }
    }

    /// L3 条目数
    public func l3Count(for sessionID: SessionID) async -> Int {
        guard let compactor else { return 0 }
        return await compactor.derivedStore.pages(sessionID: sessionID).count
    }

    /// 调度统计指标
    public func pagingStats(for sessionID: SessionID) -> ContextPagingStats {
        ContextPagingStats(
            pageIns: pageInsBySession[sessionID] ?? 0,
            pageOuts: pageOutsBySession[sessionID] ?? 0,
            promotions: promotionsBySession[sessionID] ?? 0,
            demotions: demotionsBySession[sessionID] ?? 0
        )
    }

    /// 执行明确检索并将高权重条目调度到当前 Session 的 L1 Working Set
    public func handleSearch(sessionID: SessionID, query: String, activeTask: String = "", activeFiles: [String] = [], limit: Int = 5) async throws -> String {
        clock &+= 1
        let currentClock = clock

        // 1. Search L2 Warm Cache
        var l2Candidates: [(WarmL2Entry, Double)] = []
        if let l2Entries = warmL2EntriesBySession[sessionID] {
            let normalizedQuery = query.lowercased()
            for entry in l2Entries.values {
                let content = entry.page?.content ?? entry.derivedPage?.content ?? ""
                let path = entry.page?.path ?? ""
                if content.localizedCaseInsensitiveContains(normalizedQuery) || path.localizedCaseInsensitiveContains(normalizedQuery) {
                    let score = calculatePriority(
                        content: content,
                        path: path,
                        characterCount: content.count,
                        query: query,
                        activeTask: activeTask,
                        activeFiles: activeFiles,
                        clock: currentClock,
                        lastUsed: entry.lastUsed,
                        accessCount: entry.accessCount,
                        isPinned: false
                    )
                    l2Candidates.append((entry, score + 2.0)) // Warm cache bonus
                }
            }
        }

        // 2. Search L3 Cold Cache
        var l3Candidates: [(DerivedContextPage, Double)] = []
        if let compactor {
            let derivedMatches = await compactor.derivedStore.search(sessionID: sessionID, query: query, limit: limit)
            for page in derivedMatches {
                let score = calculatePriority(
                    content: page.content,
                    path: "",
                    characterCount: page.content.count,
                    query: query,
                    activeTask: activeTask,
                    activeFiles: activeFiles,
                    clock: currentClock,
                    lastUsed: currentClock,
                    accessCount: 1,
                    isPinned: false
                )
                l3Candidates.append((page, score))
            }
        }

        // 3. Search Codebase Index
        _ = try await contextPager.rebuildStaleFiles(using: scanner)
        let contextQuery = ContextQuery(currentTask: query)
        let searchResult = await contextPager.query(projectRoot: scanner.root, query: contextQuery, limit: limit * 2)

        var codebaseCandidates: [(ContextPage, Double, String)] = []
        for page in searchResult.pages {
            let priority = calculatePriority(
                content: page.content,
                path: page.path,
                characterCount: page.characterCount,
                query: query,
                activeTask: activeTask,
                activeFiles: activeFiles,
                clock: currentClock,
                lastUsed: currentClock,
                accessCount: 1,
                isPinned: false
            )
            codebaseCandidates.append((page, priority, "Explicit retrieval for query: \(query)"))
        }

        // Check if anything matched across all sources
        guard !l2Candidates.isEmpty || !l3Candidates.isEmpty || !codebaseCandidates.isEmpty else {
            return "No matching context found for query: \"\(query)\"."
        }

        var currentL1 = residentPagesBySession[sessionID] ?? [:]
        var currentL2 = warmL2EntriesBySession[sessionID] ?? [:]
        var pagedInCodebasePages: [ContextPage] = []
        var pagedInDerivedPages: [DerivedContextPage] = []

        // Promote L2 entries
        for (l2Entry, _) in l2Candidates.prefix(limit) {
            currentL2.removeValue(forKey: l2Entry.id)
            promotionsBySession[sessionID, default: 0] += 1
            pageInsBySession[sessionID, default: 0] += 1

            if let page = l2Entry.page {
                currentL1[page.id] = L1ResidentPage(
                    page: page,
                    tokens: l2Entry.tokens,
                    lastUsed: currentClock,
                    accessCount: l2Entry.accessCount + 1,
                    retrievalRelevance: 2.0,
                    isPinned: false,
                    inclusionReason: "Promoted from L2 warm cache"
                )
                pagedInCodebasePages.append(page)
            } else if let derived = l2Entry.derivedPage {
                pagedInDerivedPages.append(derived)
            }
        }

        // Admit L3 entries
        for (l3Entry, _) in l3Candidates.prefix(limit) {
            pageInsBySession[sessionID, default: 0] += 1
            pagedInDerivedPages.append(l3Entry)
            residentDerivedPagesBySession[sessionID, default: [:]][l3Entry.id] = l3Entry
        }

        // Admit Codebase entries
        codebaseCandidates.sort { $0.1 > $1.1 }
        for (page, _, reason) in codebaseCandidates.prefix(limit) {
            currentL1[page.id] = L1ResidentPage(
                page: page,
                tokens: max(1, page.characterCount / 3),
                lastUsed: currentClock,
                accessCount: (currentL1[page.id]?.accessCount ?? 0) + 1,
                retrievalRelevance: 1.0,
                isPinned: false,
                inclusionReason: reason
            )
            pagedInCodebasePages.append(page)
            pageInsBySession[sessionID, default: 0] += 1
        }

        // Record admission into context pager
        await contextPager.recordInjection(pagedInCodebasePages)

        // Evict from L1 to L2 Warm Cache if over soft limit (demote lower priority entries)
        let baseTokens = sessionL1BaseTokens[sessionID] ?? 0
        var dynamicTokens = currentL1.values.reduce(0) { $0 + $1.tokens }

        while (dynamicTokens + baseTokens) > policy.l1SoftLimit && currentL1.count > 1 {
            let lowest = currentL1.values.filter { !$0.isPinned }.min { lhs, rhs in
                let scoreL = calculatePriority(
                    content: lhs.page.content,
                    path: lhs.page.path,
                    characterCount: lhs.page.characterCount,
                    query: query,
                    activeTask: activeTask,
                    activeFiles: activeFiles,
                    clock: currentClock,
                    lastUsed: lhs.lastUsed,
                    accessCount: lhs.accessCount,
                    isPinned: lhs.isPinned
                )
                let scoreR = calculatePriority(
                    content: rhs.page.content,
                    path: rhs.page.path,
                    characterCount: rhs.page.characterCount,
                    query: query,
                    activeTask: activeTask,
                    activeFiles: activeFiles,
                    clock: currentClock,
                    lastUsed: rhs.lastUsed,
                    accessCount: rhs.accessCount,
                    isPinned: rhs.isPinned
                )
                return scoreL < scoreR
            }
            guard let victim = lowest else { break }
            currentL1.removeValue(forKey: victim.page.id)
            dynamicTokens -= victim.tokens

            // Move to L2 warm cache
            currentL2[victim.page.id] = WarmL2Entry(
                id: victim.page.id,
                page: victim.page,
                tokens: victim.tokens,
                lastUsed: victim.lastUsed,
                accessCount: victim.accessCount,
                inclusionReason: "Paged-out to warm cache"
            )
            demotionsBySession[sessionID, default: 0] += 1
            pageOutsBySession[sessionID, default: 0] += 1
        }

        // Evict oldest from L2 if over L2 max
        var l2Tokens = currentL2.values.reduce(0) { $0 + $1.tokens }
        while l2Tokens > policy.l2Max && !currentL2.isEmpty {
            let oldest = currentL2.values.min { $0.lastUsed < $1.lastUsed }
            guard let victim = oldest else { break }
            currentL2.removeValue(forKey: victim.id)
            l2Tokens -= victim.tokens
        }

        residentPagesBySession[sessionID] = currentL1
        warmL2EntriesBySession[sessionID] = currentL2

        var outputSections: [String] = []
        if !pagedInCodebasePages.isEmpty {
            let formatted = pagedInCodebasePages.map { page in
                "### \(page.path):\(page.startLine)-\(page.endLine)\n```\n\(page.content)\n```"
            }.joined(separator: "\n\n")
            outputSections.append("## Codebase Context (\(pagedInCodebasePages.count) pages paged into L1)\n" + formatted)
        }

        if !pagedInDerivedPages.isEmpty {
            let formatted = pagedInDerivedPages.map { page in
                let snippet = page.content.count > 500 ? String(page.content.prefix(500)) + "..." : page.content
                return "- [\(page.sourceKind.rawValue)]: \(snippet)"
            }.joined(separator: "\n")
            outputSections.append("## Historical Context\n" + formatted)
        }

        return outputSections.joined(separator: "\n\n")
    }

    private func calculatePriority(
        content: String,
        path: String,
        characterCount: Int,
        query: String,
        activeTask: String,
        activeFiles: [String],
        clock: UInt64,
        lastUsed: UInt64,
        accessCount: Int,
        isPinned: Bool
    ) -> Double {
        if isPinned { return weights.pin }

        let recencyScore = Double(lastUsed) / Double(max(1, clock)) * weights.recency
        let frequencyScore = Double(accessCount) * weights.frequency

        let lowerPath = path.lowercased()
        let activeFileMatch = (!lowerPath.isEmpty && activeFiles.contains { lowerPath.contains($0.lowercased()) }) ? weights.activeFileAffinity : 0.0
        let taskMatch = (!activeTask.isEmpty && content.localizedCaseInsensitiveContains(activeTask)) ? weights.taskAffinity : 0.0
        let explicitMatch = (!lowerPath.isEmpty && lowerPath.localizedCaseInsensitiveContains(query)) ? weights.explicitReuse : 0.0
        let relevanceScore = (content.localizedCaseInsensitiveContains(query) ? 1.0 : 0.2) * weights.relevance

        let tokenCost = Double(characterCount / 3) * weights.tokenCostPenalty

        return recencyScore + frequencyScore + relevanceScore + activeFileMatch + taskMatch + explicitMatch - tokenCost
    }

    /// L1 常驻 Working Set 中的动态页面（由 Cache Controller 严格管理）
    public func residentPages(for sessionID: SessionID) -> [ContextPage] {
        guard let pages = residentPagesBySession[sessionID] else { return [] }
        return Array(pages.values.map(\.page))
    }

    /// L1 常驻 Working Set 中的衍生页面
    public func residentDerivedPages(for sessionID: SessionID) -> [DerivedContextPage] {
        guard let pages = residentDerivedPagesBySession[sessionID] else { return [] }
        return Array(pages.values)
    }

    /// L1 常驻详细状态
    public func residentEntries(for sessionID: SessionID) -> [L1ResidentPage] {
        guard let pages = residentPagesBySession[sessionID] else { return [] }
        return Array(pages.values)
    }

    /// 重置指定 Session 的所有级别缓存（用于 /new 或 session 清理）
    public func resetSession(_ sessionID: SessionID) {
        residentPagesBySession.removeValue(forKey: sessionID)
        residentDerivedPagesBySession.removeValue(forKey: sessionID)
        sessionL1BaseTokens.removeValue(forKey: sessionID)
        sessionL1BaseCount.removeValue(forKey: sessionID)
        lastProviderInputTokensBySession.removeValue(forKey: sessionID)
        warmL2EntriesBySession.removeValue(forKey: sessionID)
        pageInsBySession.removeValue(forKey: sessionID)
        pageOutsBySession.removeValue(forKey: sessionID)
        promotionsBySession.removeValue(forKey: sessionID)
        demotionsBySession.removeValue(forKey: sessionID)
    }
}
