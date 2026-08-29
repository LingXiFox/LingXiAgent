/// 面向 Client 的 L1 摘要，不携带完整上下文内容。
public struct ContextDebugSnapshot: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let revision: UInt64
    public let messageCount: Int
    public let partCount: Int
    public let characterCount: Int
    public let sourceCounts: [String: Int]
    public let sessionCharacterCount: Int
    public let projectCharacterCount: Int
    public let projectPageCount: Int

    public init(sessionID: SessionID, revision: UInt64, messageCount: Int, partCount: Int, characterCount: Int, sourceCounts: [String: Int], sessionCharacterCount: Int = 0, projectCharacterCount: Int = 0, projectPageCount: Int = 0) {
        self.sessionID = sessionID
        self.revision = revision
        self.messageCount = messageCount
        self.partCount = partCount
        self.characterCount = characterCount
        self.sourceCounts = sourceCounts
        self.sessionCharacterCount = sessionCharacterCount
        self.projectCharacterCount = projectCharacterCount
        self.projectPageCount = projectPageCount
    }
}

public struct ToolPerformance: Sendable, Equatable, Codable {
    public let step: Int
    public let toolName: String
    public let permissionWaitMilliseconds: Double
    public let executionMilliseconds: Double
    public let resultCharacters: Int
    public let permissionDecision: String

    public init(step: Int = 0, toolName: String, permissionWaitMilliseconds: Double, executionMilliseconds: Double, resultCharacters: Int, permissionDecision: String = "autoApproved") {
        self.step = step
        self.toolName = toolName
        self.permissionWaitMilliseconds = permissionWaitMilliseconds
        self.executionMilliseconds = executionMilliseconds
        self.resultCharacters = resultCharacters
        self.permissionDecision = permissionDecision
    }
}

public struct PermissionPerformance: Sendable, Equatable, Codable {
    public let autoApproved: Int
    public let asked: Int
    public let denied: Int
    public let waitMilliseconds: Double

    public init(autoApproved: Int, asked: Int, denied: Int, waitMilliseconds: Double) {
        self.autoApproved = autoApproved
        self.asked = asked
        self.denied = denied
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct StepPerformance: Sendable, Equatable, Codable {
    public var step: Int
    public var contextRevision: UInt64
    public var contextBuildMilliseconds: Double
    public var modelDispatchMilliseconds: Double
    public var streamMilliseconds: Double
    public var firstEventMilliseconds: Double?
    public var firstTextMilliseconds: Double?
    public var firstReasoningMilliseconds: Double?
    public var toolCallCount: Int

    public init(step: Int = 0, contextRevision: UInt64, contextBuildMilliseconds: Double, modelDispatchMilliseconds: Double, streamMilliseconds: Double, firstEventMilliseconds: Double? = nil, firstTextMilliseconds: Double? = nil, firstReasoningMilliseconds: Double? = nil, toolCallCount: Int = 0) {
        self.step = step
        self.contextRevision = contextRevision
        self.contextBuildMilliseconds = contextBuildMilliseconds
        self.modelDispatchMilliseconds = modelDispatchMilliseconds
        self.streamMilliseconds = streamMilliseconds
        self.firstEventMilliseconds = firstEventMilliseconds
        self.firstTextMilliseconds = firstTextMilliseconds
        self.firstReasoningMilliseconds = firstReasoningMilliseconds
        self.toolCallCount = toolCallCount
    }
}

public struct ContextPagingPerformance: Sendable, Equatable, Codable {
    public var turn: ContextPagingTurnPerformance
    public let queryCharacters: Int
    public let queryTerms: Int
    public let candidatePages: Int
    public let candidateCharacters: Int
    public let selectedPages: Int
    public let selectedCharacters: Int
    public let injectedPages: Int
    public let injectedCharacters: Int
    public let filesChecked: Int
    public let filesRebuilt: Int
    public let scanMilliseconds: Int
    public let initialIndexedFiles: Int
    public let l2Lookups: Int
    public let l2Hits: Int
    public let l2Misses: Int
    public let l2Pages: Int
    public let l2Characters: Int
    public let l3Pages: Int
    public let l3Queries: Int
    public let l3Candidates: Int
    public let l3Materializations: Int
    public let staleRebuilds: Int
    public let pageFaults: Int
    public let promotions: Int
    public let evictions: Int
    public let retrievalMilliseconds: Double
    public let materializationMilliseconds: Double
    public let symbolCount: Int
    public let symbolIndexedFiles: Int
    public let symbolHints: Int
    public let symbolExactMatches: Int
    public let symbolQualifiedExactMatches: Int
    public let symbolFallbackExactMatches: Int
    public let symbolPrefixMatches: Int
    public let symbolCandidatePages: Int
    public let symbolHintExtractionMilliseconds: Double
    public let symbolExactLookupMilliseconds: Double
    public let symbolPrefixLookupMilliseconds: Double
    public let symbolCandidateMergeMilliseconds: Double
    public let symbolRankingMilliseconds: Double
    public let symbolTotalMilliseconds: Double
    public let lexicalCandidatePages: Int
    public let currentSourceCandidates: Int
    public let documentationCandidates: Int
    public let referenceCandidates: Int
    public let referenceCount: Int
    public let resolvedReferenceCount: Int
    public let ambiguousReferenceCount: Int
    public let unresolvedReferenceCount: Int
    public let dependencyCount: Int
    public let referenceIndexedFiles: Int
    public let relationHints: Int
    public let directReferenceHits: Int
    public let dependencyHits: Int
    public let relatedPages: Int
    public let referenceResolutionMilliseconds: Double
    public let referenceExpansionMilliseconds: Double

    public init(queryCharacters: Int, queryTerms: Int, candidatePages: Int, candidateCharacters: Int, selectedPages: Int, selectedCharacters: Int, injectedPages: Int, injectedCharacters: Int, filesChecked: Int, filesRebuilt: Int, scanMilliseconds: Int, initialIndexedFiles: Int, l2Lookups: Int, l2Hits: Int, l2Misses: Int, l2Pages: Int, l2Characters: Int, l3Pages: Int, l3Queries: Int, l3Candidates: Int, l3Materializations: Int, staleRebuilds: Int, pageFaults: Int, promotions: Int, evictions: Int, retrievalMilliseconds: Double, materializationMilliseconds: Double, symbolCount: Int = 0, symbolIndexedFiles: Int = 0, symbolHints: Int = 0, symbolExactMatches: Int = 0, symbolQualifiedExactMatches: Int = 0, symbolFallbackExactMatches: Int = 0, symbolPrefixMatches: Int = 0, symbolCandidatePages: Int = 0, symbolHintExtractionMilliseconds: Double = 0, symbolExactLookupMilliseconds: Double = 0, symbolPrefixLookupMilliseconds: Double = 0, symbolCandidateMergeMilliseconds: Double = 0, symbolRankingMilliseconds: Double = 0, symbolTotalMilliseconds: Double = 0, lexicalCandidatePages: Int = 0, currentSourceCandidates: Int = 0, documentationCandidates: Int = 0, referenceCandidates: Int = 0, referenceCount: Int = 0, resolvedReferenceCount: Int = 0, ambiguousReferenceCount: Int = 0, unresolvedReferenceCount: Int = 0, dependencyCount: Int = 0, referenceIndexedFiles: Int = 0, relationHints: Int = 0, directReferenceHits: Int = 0, dependencyHits: Int = 0, relatedPages: Int = 0, referenceResolutionMilliseconds: Double = 0, referenceExpansionMilliseconds: Double = 0, turn: ContextPagingTurnPerformance = .zero) {
        self.turn = turn
        self.queryCharacters = queryCharacters; self.queryTerms = queryTerms; self.candidatePages = candidatePages; self.candidateCharacters = candidateCharacters; self.selectedPages = selectedPages; self.selectedCharacters = selectedCharacters; self.injectedPages = injectedPages; self.injectedCharacters = injectedCharacters; self.filesChecked = filesChecked; self.filesRebuilt = filesRebuilt; self.scanMilliseconds = scanMilliseconds; self.initialIndexedFiles = initialIndexedFiles; self.l2Lookups = l2Lookups; self.l2Hits = l2Hits; self.l2Misses = l2Misses; self.l2Pages = l2Pages; self.l2Characters = l2Characters; self.l3Pages = l3Pages; self.l3Queries = l3Queries; self.l3Candidates = l3Candidates; self.l3Materializations = l3Materializations; self.staleRebuilds = staleRebuilds; self.pageFaults = pageFaults; self.promotions = promotions; self.evictions = evictions; self.retrievalMilliseconds = retrievalMilliseconds; self.materializationMilliseconds = materializationMilliseconds; self.symbolCount = symbolCount; self.symbolIndexedFiles = symbolIndexedFiles; self.symbolHints = symbolHints; self.symbolExactMatches = symbolExactMatches; self.symbolQualifiedExactMatches = symbolQualifiedExactMatches; self.symbolFallbackExactMatches = symbolFallbackExactMatches; self.symbolPrefixMatches = symbolPrefixMatches; self.symbolCandidatePages = symbolCandidatePages; self.symbolHintExtractionMilliseconds = symbolHintExtractionMilliseconds; self.symbolExactLookupMilliseconds = symbolExactLookupMilliseconds; self.symbolPrefixLookupMilliseconds = symbolPrefixLookupMilliseconds; self.symbolCandidateMergeMilliseconds = symbolCandidateMergeMilliseconds; self.symbolRankingMilliseconds = symbolRankingMilliseconds; self.symbolTotalMilliseconds = symbolTotalMilliseconds; self.lexicalCandidatePages = lexicalCandidatePages; self.currentSourceCandidates = currentSourceCandidates; self.documentationCandidates = documentationCandidates; self.referenceCandidates = referenceCandidates; self.referenceCount = referenceCount; self.resolvedReferenceCount = resolvedReferenceCount; self.ambiguousReferenceCount = ambiguousReferenceCount; self.unresolvedReferenceCount = unresolvedReferenceCount; self.dependencyCount = dependencyCount; self.referenceIndexedFiles = referenceIndexedFiles; self.relationHints = relationHints; self.directReferenceHits = directReferenceHits; self.dependencyHits = dependencyHits; self.relatedPages = relatedPages; self.referenceResolutionMilliseconds = referenceResolutionMilliseconds; self.referenceExpansionMilliseconds = referenceExpansionMilliseconds
    }

    public var l2HitRate: Double? { l2Lookups == 0 ? nil : Double(l2Hits) / Double(l2Lookups) }
}

public struct ContextPagingTurnPerformance: Sendable, Equatable, Codable {
    public var lookups: Int
    public var hits: Int
    public var misses: Int
    public var pageFaults: Int
    public var promotions: Int
    public var evictions: Int
    public var candidatePages: Int
    public var candidateCharacters: Int
    public var selectedPages: Int
    public var selectedCharacters: Int
    public var injectedPages: Int
    public var injectedCharacters: Int
    public var scannerChecked: Int
    public var scannerRebuilt: Int
    public var scannerMilliseconds: Int
    public var symbolHints: Int
    public var symbolExactMatches: Int
    public var symbolQualifiedExactMatches: Int
    public var symbolFallbackExactMatches: Int
    public var symbolPrefixMatches: Int
    public var symbolCandidatePages: Int
    public var symbolHintExtractionMilliseconds: Double
    public var symbolExactLookupMilliseconds: Double
    public var symbolPrefixLookupMilliseconds: Double
    public var symbolCandidateMergeMilliseconds: Double
    public var symbolRankingMilliseconds: Double
    public var symbolTotalMilliseconds: Double
    public var lexicalCandidatePages: Int
    public var currentSourceCandidates: Int
    public var documentationCandidates: Int
    public var referenceCandidates: Int
    public var relationHints: Int
    public var directReferenceHits: Int
    public var dependencyHits: Int
    public var relatedPages: Int
    public var referenceResolutionMilliseconds: Double
    public var referenceExpansionMilliseconds: Double
    public static let zero = ContextPagingTurnPerformance()
    public init(lookups: Int = 0, hits: Int = 0, misses: Int = 0, pageFaults: Int = 0, promotions: Int = 0, evictions: Int = 0, candidatePages: Int = 0, candidateCharacters: Int = 0, selectedPages: Int = 0, selectedCharacters: Int = 0, injectedPages: Int = 0, injectedCharacters: Int = 0, scannerChecked: Int = 0, scannerRebuilt: Int = 0, scannerMilliseconds: Int = 0, symbolHints: Int = 0, symbolExactMatches: Int = 0, symbolQualifiedExactMatches: Int = 0, symbolFallbackExactMatches: Int = 0, symbolPrefixMatches: Int = 0, symbolCandidatePages: Int = 0, symbolHintExtractionMilliseconds: Double = 0, symbolExactLookupMilliseconds: Double = 0, symbolPrefixLookupMilliseconds: Double = 0, symbolCandidateMergeMilliseconds: Double = 0, symbolRankingMilliseconds: Double = 0, symbolTotalMilliseconds: Double = 0, lexicalCandidatePages: Int = 0, currentSourceCandidates: Int = 0, documentationCandidates: Int = 0, referenceCandidates: Int = 0, relationHints: Int = 0, directReferenceHits: Int = 0, dependencyHits: Int = 0, relatedPages: Int = 0, referenceResolutionMilliseconds: Double = 0, referenceExpansionMilliseconds: Double = 0) { self.lookups = lookups; self.hits = hits; self.misses = misses; self.pageFaults = pageFaults; self.promotions = promotions; self.evictions = evictions; self.candidatePages = candidatePages; self.candidateCharacters = candidateCharacters; self.selectedPages = selectedPages; self.selectedCharacters = selectedCharacters; self.injectedPages = injectedPages; self.injectedCharacters = injectedCharacters; self.scannerChecked = scannerChecked; self.scannerRebuilt = scannerRebuilt; self.scannerMilliseconds = scannerMilliseconds; self.symbolHints = symbolHints; self.symbolExactMatches = symbolExactMatches; self.symbolQualifiedExactMatches = symbolQualifiedExactMatches; self.symbolFallbackExactMatches = symbolFallbackExactMatches; self.symbolPrefixMatches = symbolPrefixMatches; self.symbolCandidatePages = symbolCandidatePages; self.symbolHintExtractionMilliseconds = symbolHintExtractionMilliseconds; self.symbolExactLookupMilliseconds = symbolExactLookupMilliseconds; self.symbolPrefixLookupMilliseconds = symbolPrefixLookupMilliseconds; self.symbolCandidateMergeMilliseconds = symbolCandidateMergeMilliseconds; self.symbolRankingMilliseconds = symbolRankingMilliseconds; self.symbolTotalMilliseconds = symbolTotalMilliseconds; self.lexicalCandidatePages = lexicalCandidatePages; self.currentSourceCandidates = currentSourceCandidates; self.documentationCandidates = documentationCandidates; self.referenceCandidates = referenceCandidates; self.relationHints = relationHints; self.directReferenceHits = directReferenceHits; self.dependencyHits = dependencyHits; self.relatedPages = relatedPages; self.referenceResolutionMilliseconds = referenceResolutionMilliseconds; self.referenceExpansionMilliseconds = referenceExpansionMilliseconds }
}

public struct ProjectCacheDebugSnapshot: Sendable, Equatable, Codable {
    public let l2Pages: Int
    public let l2Characters: Int
    public let l2HitRate: Double?
    public let l3Pages: Int
    public let staleRebuilds: Int
    public let symbolCount: Int
    public let symbolIndexedFiles: Int
    public let referenceCount: Int
    public let dependencyCount: Int

    public init(l2Pages: Int, l2Characters: Int, l2HitRate: Double?, l3Pages: Int, staleRebuilds: Int, symbolCount: Int = 0, symbolIndexedFiles: Int = 0, referenceCount: Int = 0, dependencyCount: Int = 0) {
        self.l2Pages = l2Pages
        self.l2Characters = l2Characters
        self.l2HitRate = l2HitRate
        self.l3Pages = l3Pages
        self.staleRebuilds = staleRebuilds
        self.symbolCount = symbolCount
        self.symbolIndexedFiles = symbolIndexedFiles
        self.referenceCount = referenceCount
        self.dependencyCount = dependencyCount
    }
}

public struct TurnPerformanceReport: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let totalMilliseconds: Double
    public let stepCount: Int
    public let context: ContextDebugSnapshot?
    public let steps: [StepPerformance]
    public let firstTextMilliseconds: Double?
    public let firstReasoningMilliseconds: Double?
    public let textChunks: Int
    public let reasoningChunks: Int
    public let textCharacters: Int
    public let reasoningCharacters: Int
    public let tools: [ToolPerformance]
    public let usage: ModelUsage?
    public let outputTokensPerSecond: Double?
    public let textCharactersPerSecond: Double?
    public let coreOverheadMilliseconds: Double
    public let contextPaging: ContextPagingPerformance?
    public let permissions: PermissionPerformance

    public init(sessionID: SessionID, totalMilliseconds: Double, stepCount: Int, context: ContextDebugSnapshot?, steps: [StepPerformance], firstTextMilliseconds: Double?, firstReasoningMilliseconds: Double?, textChunks: Int, reasoningChunks: Int, textCharacters: Int, reasoningCharacters: Int, tools: [ToolPerformance], usage: ModelUsage?, outputTokensPerSecond: Double?, textCharactersPerSecond: Double?, coreOverheadMilliseconds: Double = 0, contextPaging: ContextPagingPerformance? = nil, permissions: PermissionPerformance = PermissionPerformance(autoApproved: 0, asked: 0, denied: 0, waitMilliseconds: 0)) {
        self.sessionID = sessionID
        self.totalMilliseconds = totalMilliseconds
        self.stepCount = stepCount
        self.context = context
        self.steps = steps
        self.firstTextMilliseconds = firstTextMilliseconds
        self.firstReasoningMilliseconds = firstReasoningMilliseconds
        self.textChunks = textChunks
        self.reasoningChunks = reasoningChunks
        self.textCharacters = textCharacters
        self.reasoningCharacters = reasoningCharacters
        self.tools = tools
        self.usage = usage
        self.outputTokensPerSecond = outputTokensPerSecond
        self.textCharactersPerSecond = textCharactersPerSecond
        self.coreOverheadMilliseconds = coreOverheadMilliseconds
        self.contextPaging = contextPaging
        self.permissions = permissions
    }
}
