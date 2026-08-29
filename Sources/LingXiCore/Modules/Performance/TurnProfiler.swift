import Foundation
import LingXiProtocol

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// 本地 turn collector：只由 SessionRuntime 的单一任务修改，DMA 路径仅做计数。
final class TurnProfiler: @unchecked Sendable {
    private let enabled: Bool
    private let sessionID: SessionID
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var context: ContextDebugSnapshot?
    private var steps: [StepPerformance] = []
    private var firstText: ContinuousClock.Instant?
    private var firstReasoning: ContinuousClock.Instant?
    private var textChunks = 0
    private var reasoningChunks = 0
    private var textCharacters = 0
    private var reasoningCharacters = 0
    private var tools: [ToolPerformance] = []
    private var usage: ModelUsage?
    private var paging: ContextPagingPerformance?
    private var pagingTurn = ContextPagingTurnPerformance.zero
    private var budget: ContextBudgetDebug?
    private var compactions: [CompactionTurnPerformance] = []
    private var protocolValidatorPassed = 0
    private var liveToolBatchCount = 0
    private var derivedL3Hits = 0
    private var sessionL2DerivedHits = 0
    private var sessionL2DerivedPromotions = 0
    private var derivedPageIns = 0

    init(sessionID: SessionID, enabled: Bool) {
        self.sessionID = sessionID
        self.enabled = enabled
        started = clock.now
    }

    func recordContext(_ snapshot: L1ContextSnapshot, build: Duration) {
        guard enabled else { return }
        context = ContextDebugSnapshot(
            sessionID: snapshot.sessionID,
            revision: snapshot.revision,
            messageCount: snapshot.metrics.messageCount,
            partCount: snapshot.metrics.partCount,
            characterCount: snapshot.metrics.characterCount,
            sourceCounts: Dictionary(uniqueKeysWithValues: snapshot.metrics.sourceCounts.map { ($0.key.rawValue, $0.value) }),
            sessionCharacterCount: snapshot.metrics.sessionCharacterCount,
            projectCharacterCount: snapshot.metrics.projectCharacterCount,
            projectPageCount: snapshot.metrics.projectPageCount,
            estimatedTokens: snapshot.metrics.estimatedTokens,
            mandatoryTokens: snapshot.metrics.mandatoryTokens,
            recentSessionTokens: snapshot.metrics.recentSessionTokens,
            projectTokens: snapshot.metrics.projectTokens,
            derivedTokens: snapshot.metrics.derivedTokens,
            derivedPageCount: snapshot.metrics.derivedPageCount,
            liveToolBatchCount: snapshot.metrics.liveToolBatchCount,
            compactionGeneration: snapshot.metrics.compactionGeneration
        )
        steps.append(StepPerformance(step: steps.count + 1, contextRevision: snapshot.revision, contextBuildMilliseconds: build.milliseconds, modelDispatchMilliseconds: 0, streamMilliseconds: 0))
    }

    func recordModel(dispatch: Duration, stream: Duration) {
        guard enabled, !steps.isEmpty else { return }
        steps[steps.count - 1].modelDispatchMilliseconds = dispatch.milliseconds
        steps[steps.count - 1].streamMilliseconds = stream.milliseconds
    }

    func recordFirstEvent(streamElapsed: Duration) {
        guard enabled, !steps.isEmpty, steps[steps.count - 1].firstEventMilliseconds == nil else { return }
        steps[steps.count - 1].firstEventMilliseconds = streamElapsed.milliseconds
    }

    func recordText(_ text: String, streamElapsed: Duration) {
        guard enabled else { return }
        if firstText == nil { firstText = clock.now }
        if !steps.isEmpty, steps[steps.count - 1].firstTextMilliseconds == nil {
            steps[steps.count - 1].firstTextMilliseconds = streamElapsed.milliseconds
        }
        textChunks += 1
        textCharacters += text.count
    }

    func recordReasoning(_ text: String, streamElapsed: Duration) {
        guard enabled else { return }
        if firstReasoning == nil { firstReasoning = clock.now }
        if !steps.isEmpty, steps[steps.count - 1].firstReasoningMilliseconds == nil {
            steps[steps.count - 1].firstReasoningMilliseconds = streamElapsed.milliseconds
        }
        reasoningChunks += 1
        reasoningCharacters += text.count
    }

    func recordTool(_ outcome: ToolRuntime.ExecutionOutcome) {
        guard enabled else { return }
        tools.append(ToolPerformance(
            step: steps.last?.step ?? 0,
            toolName: outcome.toolName,
            permissionWaitMilliseconds: outcome.permissionWait.milliseconds,
            executionMilliseconds: outcome.execution.milliseconds,
            resultCharacters: outcome.result.content.count,
            permissionDecision: outcome.result.error?.code == CoreError.Code.permissionDenied.rawValue ? "denied" : (outcome.permissionAsked ? "asked" : "autoApproved")
        ))
        if !steps.isEmpty { steps[steps.count - 1].toolCallCount += 1 }
    }

    func recordUsage(_ usage: ModelUsage) { if enabled { self.usage = usage } }

    func recordBudget(_ budget: ContextBudget, modelWindow: Int) {
        guard enabled else { return }
        self.budget = ContextBudgetDebug(modelWindow: modelWindow, outputReserve: budget.reservedOutputTokens, fixedOverhead: budget.fixedOverheadTokens, safetyMargin: budget.safetyMarginTokens, hardInputLimit: budget.hardInputLimit, preferredActive: budget.preferredActiveTokens, highWater: budget.highWaterTokens, lowWater: budget.lowWaterTokens)
    }

    func recordCompaction(_ result: CompactionResult, budget: ContextBudget) {
        guard enabled else { return }
        compactions.append(CompactionTurnPerformance(triggerSource: result.triggerSource.rawValue, triggered: result.triggered, beforeTokens: result.beforeTokens, afterTokens: result.afterTokens, targetLowWater: budget.lowWaterTokens, mandatoryFloor: result.mandatoryFloor, unitsKept: result.unitsKept, unitsPagedOut: result.pagedOut, historicalToolBatchesPagedOut: result.historicalToolBatchesPagedOut, projectBackedOffloads: result.projectBackedOffloads, derivedPagesCreated: result.derivedCreated, redundantDrops: result.redundantDrops, emergencyTrims: result.emergencyTrims))
    }

    func recordProtocolValidator(liveBatches: Int) { if enabled { protocolValidatorPassed += 1; liveToolBatchCount = liveBatches } }

    func recordDerivedPaging(l3Hits: Int, l2Hits: Int, l2Promotions: Int, pageIns: Int) {
        guard enabled else { return }
        derivedL3Hits = l3Hits
        sessionL2DerivedHits = l2Hits
        sessionL2DerivedPromotions = l2Promotions
        derivedPageIns = pageIns
    }

    func recordPaging(_ metrics: ContextPagingDebugMetrics, turn: ContextPagingTurnMetrics = .zero, scan: ProjectPageStoreUpdate? = nil) {
        guard enabled else { return }
        paging = ContextPagingPerformance(
            queryCharacters: metrics.queryCharacters, queryTerms: metrics.queryTerms,
            candidatePages: metrics.candidatePages, candidateCharacters: metrics.candidateCharacters,
            selectedPages: metrics.selectedPages, selectedCharacters: metrics.selectedCharacters,
            injectedPages: metrics.injectedPages, injectedCharacters: metrics.injectedCharacters,
            filesChecked: metrics.filesChecked, filesRebuilt: metrics.filesRebuilt, scanMilliseconds: metrics.scanMilliseconds,
            initialIndexedFiles: metrics.initialIndexedFiles,
            l2Lookups: metrics.l2Lookups, l2Hits: metrics.l2Hits, l2Misses: metrics.l2Misses,
            l2Pages: metrics.l2Pages, l2Characters: metrics.l2Characters, l3Pages: metrics.l3Pages,
            l3Queries: metrics.l3Queries, l3Candidates: metrics.l3Candidates, l3Materializations: metrics.l3Materializations,
            staleRebuilds: metrics.staleRebuilds, pageFaults: metrics.pageFaults, promotions: metrics.promotions,
            evictions: metrics.evictions,
            retrievalMilliseconds: metrics.retrievalMilliseconds, materializationMilliseconds: metrics.materializationMilliseconds,
            symbolCount: metrics.symbolCount, symbolIndexedFiles: metrics.symbolIndexedFiles,
            symbolHints: metrics.symbolHints, symbolExactMatches: metrics.symbolExactMatches,
            symbolQualifiedExactMatches: metrics.symbolQualifiedExactMatches, symbolFallbackExactMatches: metrics.symbolFallbackExactMatches,
            symbolPrefixMatches: metrics.symbolPrefixMatches, symbolCandidatePages: metrics.symbolCandidatePages,
            symbolHintExtractionMilliseconds: metrics.symbolHintExtractionMilliseconds,
            symbolExactLookupMilliseconds: metrics.symbolExactLookupMilliseconds,
            symbolPrefixLookupMilliseconds: metrics.symbolPrefixLookupMilliseconds,
            symbolCandidateMergeMilliseconds: metrics.symbolCandidateMergeMilliseconds,
            symbolRankingMilliseconds: metrics.symbolRankingMilliseconds,
            symbolTotalMilliseconds: metrics.symbolTotalMilliseconds,
            lexicalCandidatePages: metrics.lexicalCandidatePages,
            currentSourceCandidates: metrics.currentSourceCandidates,
            documentationCandidates: metrics.documentationCandidates,
            referenceCandidates: metrics.referenceCandidates,
            referenceCount: metrics.referenceCount, resolvedReferenceCount: metrics.resolvedReferenceCount,
            ambiguousReferenceCount: metrics.ambiguousReferenceCount, unresolvedReferenceCount: metrics.unresolvedReferenceCount,
            dependencyCount: metrics.dependencyCount, referenceIndexedFiles: metrics.referenceIndexedFiles,
            relationHints: metrics.relationHints, directReferenceHits: metrics.directReferenceHits,
            dependencyHits: metrics.dependencyHits, relatedPages: metrics.relatedPages,
            referenceResolutionMilliseconds: metrics.referenceResolutionMilliseconds,
            referenceExpansionMilliseconds: metrics.referenceExpansionMilliseconds
        )
        pagingTurn.lookups += turn.lookups; pagingTurn.hits += turn.hits; pagingTurn.misses += turn.misses
        pagingTurn.pageFaults += turn.pageFaults; pagingTurn.promotions += turn.promotions; pagingTurn.evictions += turn.evictions
        pagingTurn.candidatePages += turn.candidatePages; pagingTurn.candidateCharacters += turn.candidateCharacters
        pagingTurn.selectedPages += turn.selectedPages; pagingTurn.selectedCharacters += turn.selectedCharacters
        pagingTurn.injectedPages += metrics.injectedPages; pagingTurn.injectedCharacters += metrics.injectedCharacters
        pagingTurn.symbolHints += turn.symbolHints; pagingTurn.symbolExactMatches += turn.symbolExactMatches
        pagingTurn.symbolQualifiedExactMatches += turn.symbolQualifiedExactMatches; pagingTurn.symbolFallbackExactMatches += turn.symbolFallbackExactMatches
        pagingTurn.symbolPrefixMatches += turn.symbolPrefixMatches; pagingTurn.symbolCandidatePages += turn.symbolCandidatePages
        pagingTurn.symbolHintExtractionMilliseconds += turn.symbolHintExtractionMilliseconds
        pagingTurn.symbolExactLookupMilliseconds += turn.symbolExactLookupMilliseconds
        pagingTurn.symbolPrefixLookupMilliseconds += turn.symbolPrefixLookupMilliseconds
        pagingTurn.symbolCandidateMergeMilliseconds += turn.symbolCandidateMergeMilliseconds
        pagingTurn.symbolRankingMilliseconds += turn.symbolRankingMilliseconds
        pagingTurn.symbolTotalMilliseconds += turn.symbolTotalMilliseconds
        pagingTurn.lexicalCandidatePages += turn.lexicalCandidatePages
        pagingTurn.currentSourceCandidates += turn.currentSourceCandidates
        pagingTurn.documentationCandidates += turn.documentationCandidates
        pagingTurn.referenceCandidates += turn.referenceCandidates
        pagingTurn.relationHints += turn.relationHints; pagingTurn.directReferenceHits += turn.directReferenceHits
        pagingTurn.dependencyHits += turn.dependencyHits; pagingTurn.relatedPages += turn.relatedPages
        pagingTurn.referenceResolutionMilliseconds += turn.referenceResolutionMilliseconds
        pagingTurn.referenceExpansionMilliseconds += turn.referenceExpansionMilliseconds
        if let scan { pagingTurn.scannerChecked += scan.filesChecked; pagingTurn.scannerRebuilt += scan.filesRebuilt; pagingTurn.scannerMilliseconds += scan.scanMilliseconds }
        paging?.turn = pagingTurn
    }

    func report() -> TurnPerformanceReport? {
        guard enabled else { return nil }
        let total = started.duration(to: clock.now).milliseconds
        let streamTotal = steps.reduce(0) { $0 + $1.streamMilliseconds }
        let outputRate = usage?.outputTokens.flatMap { streamTotal > 0 ? Double($0) / (streamTotal / 1_000) : nil }
        let charRate = streamTotal > 0 ? Double(textCharacters) / (streamTotal / 1_000) : nil
        let measured = steps.reduce(0) { $0 + $1.contextBuildMilliseconds + $1.modelDispatchMilliseconds + $1.streamMilliseconds } + tools.reduce(0) { $0 + $1.permissionWaitMilliseconds + $1.executionMilliseconds }
        let permissions = PermissionPerformance(
            autoApproved: tools.filter { $0.permissionDecision == "autoApproved" }.count,
            asked: tools.filter { $0.permissionDecision == "asked" }.count,
            denied: tools.filter { $0.permissionDecision == "denied" }.count,
            waitMilliseconds: tools.reduce(0) { $0 + $1.permissionWaitMilliseconds }
        )
        let estimated = context?.estimatedTokens
        let actual = usage?.inputTokens
        let error = estimated.flatMap { estimate in actual.map { actual in estimate == 0 ? 0 : Double(abs(estimate - actual)) / Double(estimate) * 100 } }
        return TurnPerformanceReport(
            sessionID: sessionID,
            totalMilliseconds: total,
            stepCount: steps.count,
            context: context,
            steps: steps,
            firstTextMilliseconds: firstText.map { started.duration(to: $0).milliseconds },
            firstReasoningMilliseconds: firstReasoning.map { started.duration(to: $0).milliseconds },
            textChunks: textChunks,
            reasoningChunks: reasoningChunks,
            textCharacters: textCharacters,
            reasoningCharacters: reasoningCharacters,
            tools: tools,
            usage: usage,
            outputTokensPerSecond: outputRate,
            textCharactersPerSecond: charRate,
            coreOverheadMilliseconds: max(0, total - measured),
            contextPaging: paging,
            permissions: permissions,
            contextBudget: budget,
            compactions: compactions,
            protocolValidatorPassed: protocolValidatorPassed,
            liveToolBatchCount: liveToolBatchCount,
            estimatedPromptTokens: estimated,
            actualPromptTokens: actual,
            estimatorErrorPercent: error,
            derivedL3Hits: derivedL3Hits,
            sessionL2DerivedHits: sessionL2DerivedHits,
            sessionL2DerivedPromotions: sessionL2DerivedPromotions,
            derivedPageIns: derivedPageIns
        )
    }
}

public actor PerformanceStore {
    public let enabled: Bool
    private var reports: [SessionID: TurnPerformanceReport] = [:]

    public init(enabled: Bool = ProcessInfo.processInfo.environment["LINGXI_PERF_DEBUG"] == "1") {
        self.enabled = enabled
    }

    public func save(_ report: TurnPerformanceReport) { reports[report.sessionID] = report }
    public func report(for sessionID: SessionID) -> TurnPerformanceReport? { reports[sessionID] }
}
