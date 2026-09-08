import Foundation

public enum RuntimeTraceKind: String, Sendable, Equatable, Codable {
    case core
    case session
    case agentRun
    case workflow
    case provider
    case tool
    case mcp
    case subagent
    case hitl
    case watchdog
    case recovery
    case cancellation
    case error
}

public struct RuntimeTraceEvent: Sendable, Equatable, Codable {
    public let traceID: String
    public let timestamp: Date
    public let kind: RuntimeTraceKind
    public let event: String
    public let sessionID: SessionID?
    public let runID: AgentRunID?
    public let rootRunID: AgentRunID?
    public let parentRunID: AgentRunID?
    public let workflowID: WorkflowID?
    public let taskID: WorkflowTaskID?
    public let executionID: String?
    public let providerRequestID: String?
    public let toolCallID: ToolCallID?
    public let metadata: [String: String]
    public let errorCode: String?

    public init(traceID: String = UUID().uuidString, timestamp: Date = .now, kind: RuntimeTraceKind, event: String, sessionID: SessionID? = nil, runID: AgentRunID? = nil, rootRunID: AgentRunID? = nil, parentRunID: AgentRunID? = nil, workflowID: WorkflowID? = nil, taskID: WorkflowTaskID? = nil, executionID: String? = nil, providerRequestID: String? = nil, toolCallID: ToolCallID? = nil, metadata: [String: String] = [:], errorCode: String? = nil) {
        self.traceID = traceID
        self.timestamp = timestamp
        self.kind = kind
        self.event = event
        self.sessionID = sessionID
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.workflowID = workflowID
        self.taskID = taskID
        self.executionID = executionID
        self.providerRequestID = providerRequestID
        self.toolCallID = toolCallID
        self.metadata = metadata
        self.errorCode = errorCode
    }
}

public struct RuntimeDiagnosticProviderStatus: Sendable, Equatable, Codable {
    public let configured: Bool
    public let model: String?
    public let missingRequirements: [String]

    public init(configured: Bool, model: String?, missingRequirements: [String]) {
        self.configured = configured
        self.model = model
        self.missingRequirements = missingRequirements
    }
}

public struct RuntimeDiagnosticMCPStatus: Sendable, Equatable, Codable {
    public let catalogTools: Int
    public let schemaFiles: Int
    public let schemaBytes: Int
    public let pageFaults: Int
    public let activeLeases: Int

    public init(catalogTools: Int, schemaFiles: Int, schemaBytes: Int, pageFaults: Int, activeLeases: Int) {
        self.catalogTools = catalogTools
        self.schemaFiles = schemaFiles
        self.schemaBytes = schemaBytes
        self.pageFaults = pageFaults
        self.activeLeases = activeLeases
    }
}

public struct RuntimeDiagnosticsBundle: Sendable, Equatable, Codable {
    public let generatedAt: Date
    public let runtimeVersion: String
    public let protocolVersion: String
    public let configurationSummary: [String: String]
    public let trace: [RuntimeTraceEvent]
    public let recentErrors: [RuntimeTraceEvent]
    public let provider: RuntimeDiagnosticProviderStatus
    public let mcp: RuntimeDiagnosticMCPStatus
    public let runs: [AgentRunInfo]
    public let workflows: [WorkflowSnapshot]
    public let recoveryRequiredRunIDs: [AgentRunID]
    public let orphanRunIDs: [AgentRunID]

    public init(generatedAt: Date = .now, runtimeVersion: String, protocolVersion: String, configurationSummary: [String: String], trace: [RuntimeTraceEvent], recentErrors: [RuntimeTraceEvent], provider: RuntimeDiagnosticProviderStatus, mcp: RuntimeDiagnosticMCPStatus, runs: [AgentRunInfo], workflows: [WorkflowSnapshot], recoveryRequiredRunIDs: [AgentRunID], orphanRunIDs: [AgentRunID]) {
        self.generatedAt = generatedAt
        self.runtimeVersion = runtimeVersion
        self.protocolVersion = protocolVersion
        self.configurationSummary = configurationSummary
        self.trace = trace
        self.recentErrors = recentErrors
        self.provider = provider
        self.mcp = mcp
        self.runs = runs
        self.workflows = workflows
        self.recoveryRequiredRunIDs = recoveryRequiredRunIDs
        self.orphanRunIDs = orphanRunIDs
    }
}

/// 面向 Client 的 L1 摘要，不携带完整上下文内容。
public enum ContextUnitResidency: String, Sendable, Equatable, Codable {
    case active
    case pagedOut
    case derived
    case superseded
}

/// 只暴露 provenance，不暴露原始 Session 正文。
public struct ContextUnitDebugSnapshot: Sendable, Equatable, Codable {
    public let messageID: MessageID
    public let residency: ContextUnitResidency
    public let derivedPageID: String?
    public let contentHash: String?

    public init(messageID: MessageID, residency: ContextUnitResidency, derivedPageID: String? = nil, contentHash: String? = nil) {
        self.messageID = messageID
        self.residency = residency
        self.derivedPageID = derivedPageID
        self.contentHash = contentHash
    }
}

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
    public let estimatedTokens: Int
    public let mandatoryTokens: Int
    public let recentSessionTokens: Int
    public let projectTokens: Int
    public let derivedTokens: Int
    public let derivedPageCount: Int
    public let liveToolBatchCount: Int
    public let compactionGeneration: Int
    public let units: [ContextUnitDebugSnapshot]
    public let materializedDerivedPageIDs: [String]

    public init(sessionID: SessionID, revision: UInt64, messageCount: Int, partCount: Int, characterCount: Int, sourceCounts: [String: Int], sessionCharacterCount: Int = 0, projectCharacterCount: Int = 0, projectPageCount: Int = 0, estimatedTokens: Int = 0, mandatoryTokens: Int = 0, recentSessionTokens: Int = 0, projectTokens: Int = 0, derivedTokens: Int = 0, derivedPageCount: Int = 0, liveToolBatchCount: Int = 0, compactionGeneration: Int = 0, units: [ContextUnitDebugSnapshot] = [], materializedDerivedPageIDs: [String] = []) {
        self.sessionID = sessionID
        self.revision = revision
        self.messageCount = messageCount
        self.partCount = partCount
        self.characterCount = characterCount
        self.sourceCounts = sourceCounts
        self.sessionCharacterCount = sessionCharacterCount
        self.projectCharacterCount = projectCharacterCount
        self.projectPageCount = projectPageCount
        self.estimatedTokens = estimatedTokens
        self.mandatoryTokens = mandatoryTokens
        self.recentSessionTokens = recentSessionTokens
        self.projectTokens = projectTokens
        self.derivedTokens = derivedTokens
        self.derivedPageCount = derivedPageCount
        self.liveToolBatchCount = liveToolBatchCount
        self.compactionGeneration = compactionGeneration
        self.units = units
        self.materializedDerivedPageIDs = materializedDerivedPageIDs
    }
}

public enum ContextLayer: String, Sendable, Equatable, Codable {
    case l1, l2, l3
}

public enum ContextLayerState: String, Sendable, Equatable, Codable {
    case available, empty, paging, compacting, unavailable
}

public enum ContextPagingActivity: String, Sendable, Equatable, Codable {
    case idle, paging, compacting
}

public enum TokenFormatter {
    public static func format(_ tokens: Int) -> String {
        if tokens < 1_000 {
            return "\(tokens)"
        } else if tokens < 10_000 {
            let k = Double(tokens) / 1_000.0
            let rounded = (k * 10).rounded() / 10
            return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))K" : String(format: "%.1fK", rounded)
        } else if tokens < 100_000 {
            let k = Double(tokens) / 1_000.0
            let rounded = (k * 10).rounded() / 10
            return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))K" : String(format: "%.1fK", rounded)
        } else if tokens < 1_000_000 {
            let k = (Double(tokens) / 1_000.0).rounded()
            return "\(Int(k))K"
        } else {
            let m = Double(tokens) / 1_000_000.0
            let rounded = (m * 100).rounded() / 100
            return rounded.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rounded))M" : String(format: "%.2fM", rounded)
        }
    }

    public static func formatLayer(layer: String, usage: Int, capacity: Int, state: ContextLayerState) -> String {
        if state == .unavailable {
            return "\(layer) off"
        }
        let usageStr = usage == 0 ? "0" : format(usage)
        let capacityStr = format(capacity)
        return "\(layer) \(usageStr)/\(capacityStr)"
    }
}

public struct EffectiveContextPolicy: Sendable, Equatable, Codable {
    public let addressableBudget: Int
    public let modelWindow: Int
    public let economicThreshold: Int?
    public let reserve: Int
    public let l1Target: Int
    public let l1SoftLimit: Int
    public let l1HardLimit: Int
    public let l2Max: Int
    public let l3Capacity: Int
    public let l3Enabled: Bool

    public init(
        addressableBudget: Int = 1_048_576,
        modelWindow: Int = 1_048_576,
        economicThreshold: Int? = 272_000,
        reserve: Int = 22_000,
        l1Target: Int = 220_000,
        l1SoftLimit: Int = 235_000,
        l1HardLimit: Int = 250_000,
        l2Max: Int = 350_000,
        l3Capacity: Int = 456_576,
        l3Enabled: Bool = true
    ) {
        self.addressableBudget = addressableBudget
        self.modelWindow = modelWindow
        self.economicThreshold = economicThreshold
        self.reserve = reserve
        self.l1Target = l1Target
        self.l1SoftLimit = l1SoftLimit
        self.l1HardLimit = l1HardLimit
        self.l2Max = l2Max
        self.l3Capacity = l3Capacity
        self.l3Enabled = l3Enabled
    }
}

public struct ContextCachePolicySnapshot: Sendable, Equatable, Codable {
    public let addressableBudget: Int
    public let modelWindow: Int
    public let economicThreshold: Int?
    public let reserve: Int
    public let l1Target: Int
    public let l1SoftLimit: Int
    public let l1HardLimit: Int
    public let l2Max: Int
    public let l3Capacity: Int

    public init(
        addressableBudget: Int = 1_048_576,
        modelWindow: Int = 1_048_576,
        economicThreshold: Int? = 272_000,
        reserve: Int = 22_000,
        l1Target: Int = 220_000,
        l1SoftLimit: Int = 235_000,
        l1HardLimit: Int = 250_000,
        l2Max: Int = 350_000,
        l3Capacity: Int = 456_576
    ) {
        self.addressableBudget = addressableBudget
        self.modelWindow = modelWindow
        self.economicThreshold = economicThreshold
        self.reserve = reserve
        self.l1Target = l1Target
        self.l1SoftLimit = l1SoftLimit
        self.l1HardLimit = l1HardLimit
        self.l2Max = l2Max
        self.l3Capacity = l3Capacity
    }

    public init(policy: EffectiveContextPolicy) {
        self.init(
            addressableBudget: policy.addressableBudget,
            modelWindow: policy.modelWindow,
            economicThreshold: policy.economicThreshold,
            reserve: policy.reserve,
            l1Target: policy.l1Target,
            l1SoftLimit: policy.l1SoftLimit,
            l1HardLimit: policy.l1HardLimit,
            l2Max: policy.l2Max,
            l3Capacity: policy.l3Capacity
        )
    }
}

public struct ContextPagingStats: Sendable, Equatable, Codable {
    public let pageIns: Int
    public let pageOuts: Int
    public let promotions: Int
    public let demotions: Int

    public init(pageIns: Int = 0, pageOuts: Int = 0, promotions: Int = 0, demotions: Int = 0) {
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.promotions = promotions
        self.demotions = demotions
    }
}

public struct ContextLayerStatus: Sendable, Equatable, Codable {
    public let layer: ContextLayer
    public let usageTokens: Int
    public let capacityTokens: Int
    public let entryCount: Int
    public let state: ContextLayerState
    public let pageInCount: Int
    public let pageOutCount: Int

    // Diagnostics / backward compatibility accessors
    public var usage: Int? { usageTokens }
    public var capacity: Int? { capacityTokens }
    public var unit: String { "tokens" }
    public var percent: Int? {
        guard capacityTokens > 0 else { return nil }
        return min(100, max(0, Int((Double(usageTokens) / Double(capacityTokens)) * 100.0)))
    }
    public var residentPages: Int? { entryCount }
    public var totalPages: Int? { entryCount }

    public init(
        layer: ContextLayer,
        usageTokens: Int,
        capacityTokens: Int,
        entryCount: Int = 0,
        state: ContextLayerState,
        pageInCount: Int = 0,
        pageOutCount: Int = 0
    ) {
        self.layer = layer
        self.usageTokens = usageTokens
        self.capacityTokens = capacityTokens
        self.entryCount = entryCount
        self.state = state
        self.pageInCount = pageInCount
        self.pageOutCount = pageOutCount
    }

    public init(
        layer: ContextLayer,
        usage: Int?,
        capacity: Int?,
        unit: String? = nil,
        percent: Int? = nil,
        state: ContextLayerState,
        residentPages: Int? = nil,
        totalPages: Int? = nil,
        pageInCount: Int = 0,
        pageOutCount: Int = 0
    ) {
        self.layer = layer
        self.usageTokens = usage ?? 0
        self.capacityTokens = capacity ?? 0
        self.entryCount = residentPages ?? totalPages ?? 0
        self.state = state
        self.pageInCount = pageInCount
        self.pageOutCount = pageOutCount
    }

    private enum CodingKeys: String, CodingKey {
        case layer, usageTokens, capacityTokens, entryCount, state, pageInCount, pageOutCount, usage, capacity, unit, percent, residentPages, totalPages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layer = try container.decode(ContextLayer.self, forKey: .layer)
        state = try container.decode(ContextLayerState.self, forKey: .state)
        pageInCount = try container.decodeIfPresent(Int.self, forKey: .pageInCount) ?? 0
        pageOutCount = try container.decodeIfPresent(Int.self, forKey: .pageOutCount) ?? 0

        if let u = try container.decodeIfPresent(Int.self, forKey: .usageTokens) {
            usageTokens = u
        } else {
            usageTokens = try container.decodeIfPresent(Int.self, forKey: .usage) ?? 0
        }

        if let c = try container.decodeIfPresent(Int.self, forKey: .capacityTokens) {
            capacityTokens = c
        } else {
            capacityTokens = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? 0
        }

        if let e = try container.decodeIfPresent(Int.self, forKey: .entryCount) {
            entryCount = e
        } else {
            entryCount = try container.decodeIfPresent(Int.self, forKey: .residentPages) ?? container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layer, forKey: .layer)
        try container.encode(usageTokens, forKey: .usageTokens)
        try container.encode(capacityTokens, forKey: .capacityTokens)
        try container.encode(entryCount, forKey: .entryCount)
        try container.encode(state, forKey: .state)
        try container.encode(pageInCount, forKey: .pageInCount)
        try container.encode(pageOutCount, forKey: .pageOutCount)
        try container.encode(usageTokens, forKey: .usage)
        try container.encode(capacityTokens, forKey: .capacity)
        try container.encode("tokens", forKey: .unit)
        try container.encode(percent, forKey: .percent)
        try container.encode(entryCount, forKey: .residentPages)
        try container.encode(entryCount, forKey: .totalPages)
    }
}

public struct ContextCacheProjection: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let policy: ContextCachePolicySnapshot
    public let l1: ContextLayerStatus
    public let l2: ContextLayerStatus
    public let l3: ContextLayerStatus
    public let paging: ContextPagingStats
    public let pagingActivity: ContextPagingActivity
    public let compactionGeneration: Int
    public let latestManifest: ProviderContextManifest?
    public let lastProviderInputTokens: Int?
    public let cacheTelemetry: ProviderCacheTelemetry?

    public init(
        sessionID: SessionID,
        policy: ContextCachePolicySnapshot = ContextCachePolicySnapshot(),
        l1: ContextLayerStatus,
        l2: ContextLayerStatus,
        l3: ContextLayerStatus,
        paging: ContextPagingStats = ContextPagingStats(),
        pagingActivity: ContextPagingActivity = .idle,
        compactionGeneration: Int = 0,
        latestManifest: ProviderContextManifest? = nil,
        lastProviderInputTokens: Int? = nil,
        cacheTelemetry: ProviderCacheTelemetry? = nil
    ) {
        self.sessionID = sessionID
        self.policy = policy
        self.l1 = l1
        self.l2 = l2
        self.l3 = l3
        self.paging = paging
        self.pagingActivity = pagingActivity
        self.compactionGeneration = compactionGeneration
        self.latestManifest = latestManifest
        self.lastProviderInputTokens = lastProviderInputTokens
        self.cacheTelemetry = cacheTelemetry
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, policy, l1, l2, l3, paging, pagingActivity, compactionGeneration, latestManifest, lastProviderInputTokens, cacheTelemetry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        policy = try container.decodeIfPresent(ContextCachePolicySnapshot.self, forKey: .policy) ?? ContextCachePolicySnapshot()
        l1 = try container.decode(ContextLayerStatus.self, forKey: .l1)
        l2 = try container.decode(ContextLayerStatus.self, forKey: .l2)
        l3 = try container.decode(ContextLayerStatus.self, forKey: .l3)
        paging = try container.decodeIfPresent(ContextPagingStats.self, forKey: .paging) ?? ContextPagingStats()
        pagingActivity = try container.decodeIfPresent(ContextPagingActivity.self, forKey: .pagingActivity) ?? .idle
        compactionGeneration = try container.decodeIfPresent(Int.self, forKey: .compactionGeneration) ?? 0
        latestManifest = try container.decodeIfPresent(ProviderContextManifest.self, forKey: .latestManifest)
        lastProviderInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastProviderInputTokens)
        cacheTelemetry = try container.decodeIfPresent(ProviderCacheTelemetry.self, forKey: .cacheTelemetry)
    }
}

/// Provider prompt-cache 时代与本次请求的可观测 token 账本。
/// 新字段均通过 optional 兼容旧的持久化与 VCR 数据。
public struct ProviderCacheEpoch: Sendable, Equatable, Codable {
    public let epoch: UInt64
    public let hash: String

    public init(epoch: UInt64, hash: String) {
        self.epoch = epoch
        self.hash = hash
    }
}

public struct ProviderCacheTelemetry: Sendable, Equatable, Codable {
    public let stablePrefixTokens: Int
    public let reusableHistoryTokens: Int
    public let volatileTailTokens: Int
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cacheMissTokens: Int?
    public let cacheHitRatio: Double?
    public let epoch: ProviderCacheEpoch?

    public init(
        stablePrefixTokens: Int,
        reusableHistoryTokens: Int = 0,
        volatileTailTokens: Int = 0,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheMissTokens: Int? = nil,
        cacheHitRatio: Double? = nil,
        epoch: ProviderCacheEpoch? = nil
    ) {
        self.stablePrefixTokens = stablePrefixTokens
        self.reusableHistoryTokens = reusableHistoryTokens
        self.volatileTailTokens = volatileTailTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheMissTokens = cacheMissTokens
        self.cacheHitRatio = cacheHitRatio
        self.epoch = epoch
    }

    public func withProviderUsage(_ usage: ModelUsage?) -> Self {
        let read = usage?.cacheReadTokens
        let write = usage?.cacheWriteTokens
        let miss = read.map { max(0, stablePrefixTokens - min(stablePrefixTokens, $0)) }
        let hitRatio = read.flatMap { stablePrefixTokens > 0 ? Double(min(stablePrefixTokens, max(0, $0))) / Double(stablePrefixTokens) : nil }
        return Self(
            stablePrefixTokens: stablePrefixTokens,
            reusableHistoryTokens: reusableHistoryTokens,
            volatileTailTokens: volatileTailTokens,
            cacheReadTokens: read,
            cacheWriteTokens: write,
            cacheMissTokens: miss,
            cacheHitRatio: hitRatio,
            epoch: epoch
        )
    }

    public static func aggregate(_ values: [ProviderCacheTelemetry]) -> Self? {
        guard let first = values.first else { return nil }
        let stable = values.reduce(0) { $0 + $1.stablePrefixTokens }
        let history = values.reduce(0) { $0 + $1.reusableHistoryTokens }
        let volatile = values.reduce(0) { $0 + $1.volatileTailTokens }
        let read = values.allSatisfy { $0.cacheReadTokens != nil } ? values.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) } : nil
        let write = values.allSatisfy { $0.cacheWriteTokens != nil } ? values.reduce(0) { $0 + ($1.cacheWriteTokens ?? 0) } : nil
        let miss = read.map { max(0, stable - min(stable, $0)) }
        let ratio = read.flatMap { stable > 0 ? Double(min(stable, max(0, $0))) / Double(stable) : nil }
        return Self(stablePrefixTokens: stable, reusableHistoryTokens: history, volatileTailTokens: volatile, cacheReadTokens: read, cacheWriteTokens: write, cacheMissTokens: miss, cacheHitRatio: ratio, epoch: first.epoch)
    }
}

/// Sanitized Provider Context Manifest
/// 记录进入本次 Provider 推理的全部动态与静态上下文条目。
public struct ContextManifestEntry: Sendable, Equatable, Codable {
    public let sourceKind: String        // "Pinned", "L1", "Dynamic Page-in", "Current Turn"
    public let sourceID: String          // page ID or message ID
    public let origin: String            // file path, turn ID, system prompt
    public let tokenCount: Int
    public let inclusionReason: String   // e.g. "Active user prompt", "Pinned system context", "Retrieved by query"
    public let cacheProvenance: String   // e.g. "pinned", "l1WorkingSet", "l2Promotion", "l3PageFault"

    public init(sourceKind: String, sourceID: String, origin: String, tokenCount: Int, inclusionReason: String, cacheProvenance: String) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.origin = origin
        self.tokenCount = tokenCount
        self.inclusionReason = inclusionReason
        self.cacheProvenance = cacheProvenance
    }
}

public struct ProviderContextManifest: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let step: Int
    public let entries: [ContextManifestEntry]
    public let totalTokens: Int

    public init(sessionID: SessionID, step: Int, entries: [ContextManifestEntry], totalTokens: Int) {
        self.sessionID = sessionID
        self.step = step
        self.entries = entries
        self.totalTokens = totalTokens
    }

    public var summary: String {
        let lines = entries.map { entry in
            "  [\(entry.sourceKind)] \(entry.origin) · \(entry.tokenCount) tok · reason: \(entry.inclusionReason) (\(entry.cacheProvenance))"
        }
        return "Context Manifest (step \(step), \(totalTokens) tok, \(entries.count) entries):\n" + lines.joined(separator: "\n")
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
    public let sessionL2DerivedPages: Int
    public let derivedL3Pages: Int
    public let derivedPageOutCount: Int
    public let derivedPageInCount: Int
    public let historicalToolEvidencePages: Int
    public let derivedL3Hits: Int
    public let sessionL2DerivedHits: Int
    public let sessionL2DerivedPromotions: Int

    public init(l2Pages: Int, l2Characters: Int, l2HitRate: Double?, l3Pages: Int, staleRebuilds: Int, symbolCount: Int = 0, symbolIndexedFiles: Int = 0, referenceCount: Int = 0, dependencyCount: Int = 0, sessionL2DerivedPages: Int = 0, derivedL3Pages: Int = 0, derivedPageOutCount: Int = 0, derivedPageInCount: Int = 0, historicalToolEvidencePages: Int = 0, derivedL3Hits: Int = 0, sessionL2DerivedHits: Int = 0, sessionL2DerivedPromotions: Int = 0) {
        self.l2Pages = l2Pages
        self.l2Characters = l2Characters
        self.l2HitRate = l2HitRate
        self.l3Pages = l3Pages
        self.staleRebuilds = staleRebuilds
        self.symbolCount = symbolCount
        self.symbolIndexedFiles = symbolIndexedFiles
        self.referenceCount = referenceCount
        self.dependencyCount = dependencyCount
        self.sessionL2DerivedPages = sessionL2DerivedPages
        self.derivedL3Pages = derivedL3Pages
        self.derivedPageOutCount = derivedPageOutCount
        self.derivedPageInCount = derivedPageInCount
        self.historicalToolEvidencePages = historicalToolEvidencePages
        self.derivedL3Hits = derivedL3Hits
        self.sessionL2DerivedHits = sessionL2DerivedHits
        self.sessionL2DerivedPromotions = sessionL2DerivedPromotions
    }
}

public struct ContextBudgetDebug: Sendable, Equatable, Codable {
    public let modelWindow: Int
    public let outputReserve: Int
    public let fixedOverhead: Int
    public let safetyMargin: Int
    public let hardInputLimit: Int
    public let preferredActive: Int
    public let highWater: Int
    public let lowWater: Int

    public init(modelWindow: Int, outputReserve: Int, fixedOverhead: Int, safetyMargin: Int, hardInputLimit: Int, preferredActive: Int, highWater: Int, lowWater: Int) {
        self.modelWindow = modelWindow; self.outputReserve = outputReserve; self.fixedOverhead = fixedOverhead; self.safetyMargin = safetyMargin; self.hardInputLimit = hardInputLimit; self.preferredActive = preferredActive; self.highWater = highWater; self.lowWater = lowWater
    }
}

public struct CompactionTurnPerformance: Sendable, Equatable, Codable {
    public let triggerSource: String
    public let triggered: Bool
    public let beforeTokens: Int
    public let afterTokens: Int
    public let targetLowWater: Int
    public let mandatoryFloor: Int
    public let unitsKept: Int
    public let unitsPagedOut: Int
    public let historicalToolBatchesPagedOut: Int
    public let projectBackedOffloads: Int
    public let derivedPagesCreated: Int
    public let redundantDrops: Int
    public let emergencyTrims: Int

    public init(triggerSource: String, triggered: Bool, beforeTokens: Int, afterTokens: Int, targetLowWater: Int, mandatoryFloor: Int, unitsKept: Int, unitsPagedOut: Int, historicalToolBatchesPagedOut: Int, projectBackedOffloads: Int, derivedPagesCreated: Int, redundantDrops: Int, emergencyTrims: Int) {
        self.triggerSource = triggerSource; self.triggered = triggered; self.beforeTokens = beforeTokens; self.afterTokens = afterTokens; self.targetLowWater = targetLowWater; self.mandatoryFloor = mandatoryFloor; self.unitsKept = unitsKept; self.unitsPagedOut = unitsPagedOut; self.historicalToolBatchesPagedOut = historicalToolBatchesPagedOut; self.projectBackedOffloads = projectBackedOffloads; self.derivedPagesCreated = derivedPagesCreated; self.redundantDrops = redundantDrops; self.emergencyTrims = emergencyTrims
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
    public let contextBudget: ContextBudgetDebug?
    public let compactions: [CompactionTurnPerformance]
    public let protocolValidatorPassed: Int
    public let liveToolBatchCount: Int
    public let estimatedPromptTokens: Int?
    public let actualPromptTokens: Int?
    public let estimatorErrorPercent: Double?
    public let derivedL3Hits: Int
    public let sessionL2DerivedHits: Int
    public let sessionL2DerivedPromotions: Int
    public let derivedPageIns: Int
    public let providerCalls: [ProviderCallTrace]
    public let cacheTelemetry: ProviderCacheTelemetry?

    public var providerRequestCount: Int { providerCalls.count }
    public var totalPromptTokens: Int {
        providerCalls.reduce(0) { $0 + ($1.actualUsage?.inputTokens ?? $1.estimatedPromptTokens) }
    }

    public init(sessionID: SessionID, totalMilliseconds: Double, stepCount: Int, context: ContextDebugSnapshot?, steps: [StepPerformance], firstTextMilliseconds: Double?, firstReasoningMilliseconds: Double?, textChunks: Int, reasoningChunks: Int, textCharacters: Int, reasoningCharacters: Int, tools: [ToolPerformance], usage: ModelUsage?, outputTokensPerSecond: Double?, textCharactersPerSecond: Double?, coreOverheadMilliseconds: Double = 0, contextPaging: ContextPagingPerformance? = nil, permissions: PermissionPerformance = PermissionPerformance(autoApproved: 0, asked: 0, denied: 0, waitMilliseconds: 0), contextBudget: ContextBudgetDebug? = nil, compactions: [CompactionTurnPerformance] = [], protocolValidatorPassed: Int = 0, liveToolBatchCount: Int = 0, estimatedPromptTokens: Int? = nil, actualPromptTokens: Int? = nil, estimatorErrorPercent: Double? = nil, derivedL3Hits: Int = 0, sessionL2DerivedHits: Int = 0, sessionL2DerivedPromotions: Int = 0, derivedPageIns: Int = 0, providerCalls: [ProviderCallTrace] = [], cacheTelemetry: ProviderCacheTelemetry? = nil) {
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
        self.contextBudget = contextBudget
        self.compactions = compactions
        self.protocolValidatorPassed = protocolValidatorPassed
        self.liveToolBatchCount = liveToolBatchCount
        self.estimatedPromptTokens = estimatedPromptTokens
        self.actualPromptTokens = actualPromptTokens
        self.estimatorErrorPercent = estimatorErrorPercent
        self.derivedL3Hits = derivedL3Hits
        self.sessionL2DerivedHits = sessionL2DerivedHits
        self.sessionL2DerivedPromotions = sessionL2DerivedPromotions
        self.derivedPageIns = derivedPageIns
        self.providerCalls = providerCalls
        self.cacheTelemetry = cacheTelemetry
    }
}

public struct ProviderCallTrace: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let userTurnID: MessageID
    public let runID: AgentRunID?
    public let parentRunID: AgentRunID?
    public let providerRequestID: String
    public let sequence: Int
    public let reason: String
    public let model: String
    public let estimatedPromptTokens: Int
    public let actualUsage: ModelUsage?
    public let toolSchemaTokens: Int
    public let toolCount: Int
    public let l1Tokens: Int
    public let systemPinnedTokens: Int
    public let currentTurnTokens: Int
    public let providerFramingTokens: Int
    public let retryAttempt: Int
    public let retryCount: Int
    public let rateWaitMilliseconds: Int
    public let rateLimit429Count: Int
    public let timestamp: Date
    public let cacheTelemetry: ProviderCacheTelemetry?

    public init(
        sessionID: SessionID,
        userTurnID: MessageID,
        runID: AgentRunID? = nil,
        parentRunID: AgentRunID? = nil,
        providerRequestID: String,
        sequence: Int,
        reason: String,
        model: String,
        estimatedPromptTokens: Int,
        actualUsage: ModelUsage? = nil,
        toolSchemaTokens: Int,
        toolCount: Int,
        l1Tokens: Int,
        systemPinnedTokens: Int,
        currentTurnTokens: Int,
        providerFramingTokens: Int,
        retryAttempt: Int = 0,
        retryCount: Int = 0,
        rateWaitMilliseconds: Int = 0,
        rateLimit429Count: Int = 0,
        timestamp: Date = .now,
        cacheTelemetry: ProviderCacheTelemetry? = nil
    ) {
        self.sessionID = sessionID
        self.userTurnID = userTurnID
        self.runID = runID
        self.parentRunID = parentRunID
        self.providerRequestID = providerRequestID
        self.sequence = sequence
        self.reason = reason
        self.model = model
        self.estimatedPromptTokens = estimatedPromptTokens
        self.actualUsage = actualUsage
        self.toolSchemaTokens = toolSchemaTokens
        self.toolCount = toolCount
        self.l1Tokens = l1Tokens
        self.systemPinnedTokens = systemPinnedTokens
        self.currentTurnTokens = currentTurnTokens
        self.providerFramingTokens = providerFramingTokens
        self.retryAttempt = retryAttempt
        self.retryCount = retryCount
        self.rateWaitMilliseconds = rateWaitMilliseconds
        self.rateLimit429Count = rateLimit429Count
        self.timestamp = timestamp
        self.cacheTelemetry = cacheTelemetry
    }

    public func updating(actualUsage: ModelUsage?) -> Self {
        Self(
            sessionID: sessionID, userTurnID: userTurnID, runID: runID, parentRunID: parentRunID,
            providerRequestID: providerRequestID, sequence: sequence, reason: reason, model: model,
            estimatedPromptTokens: estimatedPromptTokens, actualUsage: actualUsage,
            toolSchemaTokens: toolSchemaTokens, toolCount: toolCount, l1Tokens: l1Tokens,
            systemPinnedTokens: systemPinnedTokens, currentTurnTokens: currentTurnTokens,
            providerFramingTokens: providerFramingTokens, retryAttempt: retryAttempt,
            retryCount: retryCount, rateWaitMilliseconds: rateWaitMilliseconds,
            rateLimit429Count: rateLimit429Count, timestamp: timestamp,
            cacheTelemetry: cacheTelemetry?.withProviderUsage(actualUsage)
        )
    }
}
