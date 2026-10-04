import Foundation
import LingXiProtocol

public protocol TokenEstimator: Sendable {
    func estimate(text: String) -> Int
    func estimate(entries: [ContextEntry]) -> Int
    func estimate(tools: [ToolDefinition]) -> Int
}

public struct ConservativeTokenEstimator: TokenEstimator {
    private final class ToolTokenCache: @unchecked Sendable {
        private var storage: [String: Int] = [:]
        private let lock = NSLock()

        func get(_ key: String) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func set(_ key: String, tokens: Int) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count > 2000 {
                storage.removeAll(keepingCapacity: true)
            }
            storage[key] = tokens
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll(keepingCapacity: false)
        }
    }

    private static let toolCache = ToolTokenCache()

    public init() {}
    public func estimate(text: String) -> Int { max(1, (text.utf8.count + 2) / 3) }
    public func estimate(entries: [ContextEntry]) -> Int {
        entries.reduce(0) { $0 + estimate(text: ContextCompactor.content(of: $1.part)) + 4 }
    }
    public func estimate(tools: [ToolDefinition]) -> Int {
        tools.reduce(0) { total, tool in total + estimate(tool: tool) }
    }

    public func estimate(tool: ToolDefinition) -> Int {
        let rawHash = tool.rawInputSchema != nil ? 1 : 0
        let cacheKey = "\(tool.id.rawValue):\(tool.name):\(tool.description.hashValue):\(rawHash)"
        if let cached = Self.toolCache.get(cacheKey) {
            return cached
        }

        let tokens: Int
        if let rawSchema = tool.rawInputSchema, let data = try? JSONEncoder().encode(rawSchema) {
            tokens = estimate(text: tool.id.rawValue + " " + tool.description + " " + String(decoding: data, as: UTF8.self)) + 22
        } else {
            var text = "function: \(tool.name) \(tool.description) "
            for (name, prop) in tool.inputSchema.properties.sorted(by: { $0.key < $1.key }) {
                text += "\(name): \(prop.type.rawValue) \(prop.description) "
                if let enumValues = prop.enumValues {
                    text += "enum: [\(enumValues.joined(separator: ", "))] "
                }
            }
            if !tool.inputSchema.required.isEmpty {
                text += "required: [\(tool.inputSchema.required.joined(separator: ", "))] "
            }
            tokens = estimate(text: text) + 18
        }
        Self.toolCache.set(cacheKey, tokens: tokens)
        return tokens
    }

    public static func clearToolTokenCacheForTesting() {
        toolCache.clear()
    }
}

public struct ModelContextProfile: Sendable, Equatable, Codable {
    public let contextWindowTokens: Int
    public let maxOutputTokens: Int?
    public let recommendedOutputReserveTokens: Int?
    public let source: String

    public init(contextWindowTokens: Int = 32_768, maxOutputTokens: Int? = nil, recommendedOutputReserveTokens: Int? = nil, source: String = "conservative fallback") {
        self.contextWindowTokens = max(1, contextWindowTokens)
        self.maxOutputTokens = maxOutputTokens
        self.recommendedOutputReserveTokens = recommendedOutputReserveTokens
        self.source = source
    }
}

public struct ContextBudgetPolicy: Sendable, Equatable, Codable {
    public let preferredActiveTokens: Int?
    public let preferredRatio: Double
    public let defaultActiveCeiling: Int
    public let safetyMarginTokens: Int
    public let fixedOverheadTokens: Int

    public init(preferredActiveTokens: Int? = nil, preferredRatio: Double = 0.65, defaultActiveCeiling: Int = 64_000, safetyMarginTokens: Int = 1_024, fixedOverheadTokens: Int = 256) {
        self.preferredActiveTokens = preferredActiveTokens
        self.preferredRatio = preferredRatio
        self.defaultActiveCeiling = defaultActiveCeiling
        self.safetyMarginTokens = safetyMarginTokens
        self.fixedOverheadTokens = fixedOverheadTokens
    }

    public func with(preferredActiveTokens: Int?) -> ContextBudgetPolicy {
        ContextBudgetPolicy(
            preferredActiveTokens: preferredActiveTokens,
            preferredRatio: preferredRatio,
            defaultActiveCeiling: defaultActiveCeiling,
            safetyMarginTokens: safetyMarginTokens,
            fixedOverheadTokens: fixedOverheadTokens
        )
    }
}

public struct ContextBudget: Sendable, Equatable {
    public let hardInputLimit: Int
    public let preferredActiveTokens: Int
    public let highWaterTokens: Int
    public let lowWaterTokens: Int
    public let reservedOutputTokens: Int
    /// 协议固定开销。与 `ContextBudgetPolicy.fixedOverheadTokens` 同量，不含工具 schema。
    public let protocolOverheadTokens: Int
    /// 本轮动态测量的工具 schema 成本。单列而非并进 overhead：两者在 `hardInputLimit` 里各扣一次，
    /// 合成一个字段会让后来人以为再减一次 overhead 就够了，从而重复扣减。
    public let toolSchemaTokens: Int
    public let safetyMarginTokens: Int
}

public struct ContextBudgetPlanner: Sendable {
    public let policy: ContextBudgetPolicy
    public init(policy: ContextBudgetPolicy = ContextBudgetPolicy()) { self.policy = policy }

    public func with(preferredActiveTokens: Int?) -> ContextBudgetPlanner {
        ContextBudgetPlanner(policy: policy.with(preferredActiveTokens: preferredActiveTokens))
    }

    /// 每轮动态预算规划。语义见 `Docs/Decisions/PE-Core-Git-Semantics-Freeze-2026-09-30.md` 第十二节。
    ///
    /// `toolSchemaTokens` 是本轮实测的工具 schema 成本，不是任何固定预算线：架构里不存在 2000 这种
    /// 运行时阈值，它只作为减项参与 `hardInputLimit`。
    ///
    /// 刻意不在这里减 system 内容：system / 当前指令 / 未完成 batch 由 `compact` 作为 `mandatoryTokens`
    /// 直接与 `hardInputLimit` 比较（见该方法的 mandatory 判定），在两处各算一次会让 system 内容被
    /// 重复扣减。
    public func plan(profile: ModelContextProfile, requestedMaxOutputTokens: Int? = nil, toolSchemaTokens: Int = 0) -> ContextBudget {
        let reserve = max(requestedMaxOutputTokens ?? 0, profile.recommendedOutputReserveTokens ?? profile.maxOutputTokens ?? 4_096)
        let hard = max(0, profile.contextWindowTokens - reserve - policy.fixedOverheadTokens - toolSchemaTokens - policy.safetyMarginTokens)
        let preferred = min(hard, policy.preferredActiveTokens ?? min(policy.defaultActiveCeiling, Int(Double(hard) * policy.preferredRatio)))
        return ContextBudget(hardInputLimit: hard, preferredActiveTokens: preferred, highWaterTokens: min(hard, Int(Double(preferred) * 1.15)), lowWaterTokens: Int(Double(preferred) * 0.8), reservedOutputTokens: reserve, protocolOverheadTokens: policy.fixedOverheadTokens, toolSchemaTokens: toolSchemaTokens, safetyMarginTokens: policy.safetyMarginTokens)
    }
}

public enum DerivedContextSourceKind: String, Sendable, Equatable { case user, assistant, historicalTool }
public enum ToolExchangeBatchState: String, Sendable, Equatable, Codable {
    case pending
    case settledAwaitingConsumption
    case consumed
    /// 崩溃时 pending batch 从不自动重放，必须由上层显式恢复。
    case recoveryRequired
}

public enum DurableToolCallState: String, Sendable, Equatable, Codable {
    case requested
    case waitingForHuman
    case executing
    case completed
    case recoveryRequired
}

public struct ToolCallProvenance: Sendable, Equatable, Codable {
    public let batchID: String
    public let sessionID: SessionID
    public let agentRunID: AgentRunID?
    public let providerRequestID: ModelRequestID?
    public let providerStep: Int

    public init(batchID: String, sessionID: SessionID, agentRunID: AgentRunID?, providerRequestID: ModelRequestID?, providerStep: Int) {
        self.batchID = batchID
        self.sessionID = sessionID
        self.agentRunID = agentRunID
        self.providerRequestID = providerRequestID
        self.providerStep = providerStep
    }
}

public struct ToolExecutionClaim: Sendable, Equatable, Codable {
    public let claimID: String
    public let mutatesProject: Bool
    public let claimedAt: Date

    public init(claimID: String = UUID().uuidString, mutatesProject: Bool, claimedAt: Date = .now) {
        self.claimID = claimID
        self.mutatesProject = mutatesProject
        self.claimedAt = claimedAt
    }
}

public enum ToolCallHumanRequest: Sendable, Equatable, Codable {
    case permission(PermissionRequest)
    case question(QuestionRequest)
}

public enum ToolCallHumanReply: Sendable, Equatable, Codable {
    case permission(PermissionReply)
    case question(QuestionReply)
}

/// One durable state machine per provider ToolCall. A completed result is authoritative after restart.
public struct DurableToolCall: Sendable, Equatable, Codable {
    public let call: ToolCall
    public let state: DurableToolCallState
    public let request: ToolCallHumanRequest?
    public let reply: ToolCallHumanReply?
    public let executionClaim: ToolExecutionClaim?
    public let provenance: ToolCallProvenance
    public let result: ToolResult?

    public init(call: ToolCall, state: DurableToolCallState = .requested, request: ToolCallHumanRequest? = nil, reply: ToolCallHumanReply? = nil, executionClaim: ToolExecutionClaim? = nil, provenance: ToolCallProvenance, result: ToolResult? = nil) {
        self.call = call
        self.state = state
        self.request = request
        self.reply = reply
        self.executionClaim = executionClaim
        self.provenance = provenance
        self.result = result
    }

    public func with(state: DurableToolCallState? = nil, request: ToolCallHumanRequest? = nil, reply: ToolCallHumanReply? = nil, replaceHumanExchange: Bool = false, executionClaim: ToolExecutionClaim? = nil, result: ToolResult? = nil) -> DurableToolCall {
        DurableToolCall(call: call, state: state ?? self.state, request: replaceHumanExchange ? request : request ?? self.request, reply: replaceHumanExchange ? reply : reply ?? self.reply, executionClaim: executionClaim ?? self.executionClaim, provenance: provenance, result: result ?? self.result)
    }
}

public struct ToolExchangeBatch: Sendable, Equatable {
    public let batchID: String
    public let sessionID: SessionID
    public let assistantMessageID: MessageID
    public let resultMessageID: MessageID?
    public let toolCalls: [ToolCall]
    public let toolResults: [ToolResult]
    public let toolCallStates: [DurableToolCall]
    public let continuationRequestID: ModelRequestID?
    public let providerStep: Int
    public let state: ToolExchangeBatchState
    public let estimatedTokens: Int
    public let revision: UInt64?
    public let turnID: TurnID?
    public var isComplete: Bool { Set(toolCalls.map(\.callID)) == Set(toolResults.map(\.callID)) && toolCalls.count == toolResults.count }

    public init(batchID: String, sessionID: SessionID, assistantMessageID: MessageID, resultMessageID: MessageID? = nil, toolCalls: [ToolCall], toolResults: [ToolResult] = [], toolCallStates: [DurableToolCall]? = nil, continuationRequestID: ModelRequestID? = nil, providerStep: Int, state: ToolExchangeBatchState, estimatedTokens: Int, revision: UInt64? = nil, turnID: TurnID? = nil) {
        self.batchID = batchID
        self.sessionID = sessionID
        self.assistantMessageID = assistantMessageID
        self.resultMessageID = resultMessageID
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.toolCallStates = toolCallStates ?? toolCalls.map { DurableToolCall(call: $0, provenance: ToolCallProvenance(batchID: batchID, sessionID: sessionID, agentRunID: nil, providerRequestID: continuationRequestID, providerStep: providerStep)) }
        self.continuationRequestID = continuationRequestID
        self.providerStep = providerStep
        self.state = state
        self.estimatedTokens = estimatedTokens
        self.revision = revision
        self.turnID = turnID
    }

    public func with(state: ToolExchangeBatchState, resultMessageID: MessageID? = nil, toolResults: [ToolResult]? = nil, toolCallStates: [DurableToolCall]? = nil, estimatedTokens: Int? = nil, revision: UInt64? = nil, turnID: TurnID? = nil) -> ToolExchangeBatch {
        ToolExchangeBatch(batchID: batchID, sessionID: sessionID, assistantMessageID: assistantMessageID, resultMessageID: resultMessageID ?? self.resultMessageID, toolCalls: toolCalls, toolResults: toolResults ?? self.toolResults, toolCallStates: toolCallStates ?? self.toolCallStates, continuationRequestID: continuationRequestID, providerStep: providerStep, state: state, estimatedTokens: estimatedTokens ?? self.estimatedTokens, revision: revision ?? self.revision, turnID: turnID ?? self.turnID)
    }
}

public enum ProtocolSafeContextUnit: Sendable, Equatable {
    case userTurn([ContextEntry])
    case assistantText([ContextEntry])
    case toolExchangeBatch(ToolExchangeBatch, [ContextEntry])
    case projectContext(ContextEntry)
    case derivedContext(ContextEntry)
    public var entries: [ContextEntry] {
        switch self { case let .userTurn(entries), let .assistantText(entries), let .toolExchangeBatch(_, entries): entries; case let .projectContext(entry), let .derivedContext(entry): [entry] }
    }
}

public enum ModelRequestProtocolValidator {
    public static func validate(_ entries: [ContextEntry]) throws {
        var pending = Set<ToolCallID>()
        var expectingResults = false
        var activeAssistantMessageID: MessageID?
        var completedAssistantMessageIDs = Set<MessageID>()
        for entry in entries {
            switch entry.part {
            case let .toolCall(call):
                guard entry.role == .assistant, !expectingResults, !completedAssistantMessageIDs.contains(entry.messageID ?? MessageID("")), (pending.isEmpty || entry.messageID == activeAssistantMessageID), pending.insert(call.callID).inserted else {
                    throw CoreError(code: .contextProtocolViolation, message: "畸形或重复 ToolCall: \(call.callID.rawValue)")
                }
                activeAssistantMessageID = entry.messageID
            case let .toolResult(result):
                expectingResults = true
                guard entry.role == .tool, pending.remove(result.callID) != nil else { throw CoreError(code: .contextProtocolViolation, message: "孤立、未知或重复 ToolResult: \(result.callID.rawValue)") }
                if pending.isEmpty {
                    expectingResults = false
                    if let activeAssistantMessageID { completedAssistantMessageIDs.insert(activeAssistantMessageID) }
                    activeAssistantMessageID = nil
                }
            case .text, .observation:
                guard entry.role != .tool, pending.isEmpty else {
                    throw CoreError(code: .contextProtocolViolation, message: "ToolCall / ToolResult 顺序错误")
                }
            }
        }
        guard pending.isEmpty else { throw CoreError(code: .contextProtocolViolation, message: "ToolCall 缺少 ToolResult") }
    }
}
public struct DerivedContextPage: Sendable, Equatable, Hashable {
    public let id: String
    public let sessionID: SessionID
    public let sourceKind: DerivedContextSourceKind
    public let content: String
    public let locator: String?
    public let contentHash: String
    public let messageID: MessageID?
    public let tokenEstimate: Int
    public let createdAt: Date
    public let version: Int
    public let provenanceIDs: [String]
    public let metadata: [String: String]
    public init(id: String? = nil, sessionID: SessionID, sourceKind: DerivedContextSourceKind, content: String, messageID: MessageID?, tokenEstimate: Int, locator: String? = nil, provenanceIDs: [String] = [], metadata: [String: String] = [:], createdAt: Date = .now, version: Int = 1) {
        self.sessionID = sessionID; self.sourceKind = sourceKind; self.content = content; self.locator = locator; self.messageID = messageID; self.tokenEstimate = tokenEstimate; self.createdAt = createdAt; self.version = version; self.provenanceIDs = provenanceIDs; self.metadata = metadata
        contentHash = ContextPage.fingerprint(content.utf8)
        self.id = id ?? "derived:\(sessionID.rawValue):\(messageID?.rawValue ?? contentHash):\(contentHash)"
    }
}

public actor DerivedContextStore {
    private var pages: [SessionID: [DerivedContextPage]] = [:]
    private var recalledPageIDs: [SessionID: Set<String>] = [:]
    private var pageOutCount = 0
    private var pageInCount = 0
    private var projectIndexHits = 0
    private var recallCacheHits = 0
    private var recallCachePromotions = 0
    private let persistence: SQLitePersistenceStore?
    public init(persistence: SQLitePersistenceStore? = nil) { self.persistence = persistence }
    public func restore() async throws {
        guard let persistence else { return }
        pages = Dictionary(grouping: try await persistence.loadDerived(), by: \.sessionID)
    }
    /// Legacy read-fallback 的入口：只用于装载迁移前落盘的旧页面（含测试构造旧数据）。
    /// 这里刻意不叫 `pageOut` —— P → E 的 page-out 唯一入口是 `ECoreObjectStore.pageOut`，
    /// 本 store 不再承接任何新写入（契约第八节：禁止两套 store 并行写入）。
    public func insertLegacyPage(_ page: DerivedContextPage) async throws {
        if !(pages[page.sessionID] ?? []).contains(page) {
            pages[page.sessionID, default: []].append(page)
            pageOutCount += 1
        }
    }
    public func search(sessionID: SessionID, query: String, limit: Int) -> [DerivedContextPage] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let normalizedQuery = query.lowercased()
        let terms = Set(normalizedQuery.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let identifiers = normalizedQuery.split(whereSeparator: \.isWhitespace).filter { $0.contains("-") }
        let current = recalledPageIDs[sessionID] ?? []
        let candidates = pages[sessionID] ?? []
        let scored = candidates.enumerated().map { index, page in
            let content = page.content.lowercased()
            let lexical = terms.reduce(0) { $0 + (content.contains($1) ? 1 : 0) }
            let identifierMatch = identifiers.contains { content.contains($0) } ? 100 : 0
            let sourceWeight = page.sourceKind == .historicalTool ? 1 : 2
            let recallCacheBonus = current.contains(page.id) ? 2 : 0
            return (page, lexical, identifierMatch, lexical * 10 + sourceWeight + recallCacheBonus + index)
        }
        let lexicalMatches = scored.filter { !terms.isEmpty && $0.1 > 0 }
        let identifierMatches = scored.filter { $0.2 > 0 }
        let userIdentifierMatches = identifierMatches.filter { $0.0.sourceKind == .user }
        let candidatesForPageIn = !userIdentifierMatches.isEmpty ? userIdentifierMatches : (!identifierMatches.isEmpty ? identifierMatches : lexicalMatches)
        let matches = candidatesForPageIn.sorted { $0.3 > $1.3 }.prefix(limit).map(\.0)
        for page in matches {
            if current.contains(page.id) { recallCacheHits += 1 } else { recallCachePromotions += 1 }
        }
        projectIndexHits += matches.count
        recalledPageIDs[sessionID] = Set(matches.map(\.id))
        pageInCount += matches.count
        return Array(matches)
    }
    public func metrics(sessionID: SessionID) -> (recallCachePages: Int, projectIndexPages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, projectIndexHits: Int, recallCacheHits: Int, recallCachePromotions: Int) { (recalledPageIDs[sessionID]?.count ?? 0, pages[sessionID]?.count ?? 0, pageOutCount, pageInCount, (pages[sessionID] ?? []).filter { $0.sourceKind == .historicalTool }.count, projectIndexHits, recallCacheHits, recallCachePromotions) }
    public func allMetrics() -> (recallCachePages: Int, projectIndexPages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, projectIndexHits: Int, recallCacheHits: Int, recallCachePromotions: Int) {
        (recalledPageIDs.values.reduce(0) { $0 + $1.count }, pages.values.reduce(0) { $0 + $1.count }, pageOutCount, pageInCount, pages.values.flatMap { $0 }.filter { $0.sourceKind == .historicalTool }.count, projectIndexHits, recallCacheHits, recallCachePromotions)
    }
    public func pages(sessionID: SessionID) -> [DerivedContextPage] { pages[sessionID] ?? [] }
    public func allPages() -> [DerivedContextPage] { pages.values.flatMap { $0 } }
    public func reconcileAfterRevert(sessionID: SessionID, remainingMessageIDs: Set<MessageID>) {
        pages[sessionID] = pages[sessionID]?.filter { $0.messageID == nil || remainingMessageIDs.contains($0.messageID!) }
        recalledPageIDs[sessionID] = recalledPageIDs[sessionID]?.intersection(Set((pages[sessionID] ?? []).map(\.id)))
    }
    public func clear(sessionID: SessionID) {
        pages.removeValue(forKey: sessionID)
        recalledPageIDs.removeValue(forKey: sessionID)
    }
}

public enum CompactionTrigger: String, Sendable { case automaticHighWater, manual, emergencyHardLimit }

public struct CompactionResult: Sendable {
    public let entries: [ContextEntry]
    public let beforeTokens: Int
    public let afterTokens: Int
    public let pagedOut: Int
    public let derivedCreated: Int
    public let triggered: Bool
    public let triggerSource: CompactionTrigger
    public let mandatoryFloor: Int
    public let unitsKept: Int
    public let historicalToolBatchesPagedOut: Int
    public let projectBackedOffloads: Int
    public let redundantDrops: Int
    public let emergencyTrims: Int
    public let noEligibleReduction: Bool
}

public actor ContextCompactor {
    private let estimator: any TokenEstimator
    /// Legacy read fallback only: 重启后旧会话仍能读到迁移前落盘的 page-out 页面。
    /// 新的 page-out 一律只写 `ecoreStore`（契约第八节：不允许两套 store 长期并行写入）。
    public nonisolated let derivedStore: DerivedContextStore
    /// E-Core 唯一权威对象存储。P → E 的完整载荷、referenceID、Exact Restore 都在这里。
    public nonisolated let ecoreStore: ECoreObjectStore
    private var unitResidencies: [SessionID: [MessageID: ContextUnitDebugSnapshot]] = [:]
    /// recency / frequency / explicitReuse 的真实来源：本 compactor 对每个对象在各 turn 的观察。
    private var usageLedgers: [SessionID: [String: ContextUsageRecord]] = [:]
    /// 契约 4.20 的可观测性：最近一轮 eviction 的特征值与排名。
    private var evictionTraces: [SessionID: [ContextEvictionTraceEntry]] = [:]
    private var evictionScoringActiveBySession: [SessionID: Bool] = [:]
    private var activeWorksetsBySession: [SessionID: Set<String>] = [:]
    private var admittedPayloads: [SessionID: [String: ContextEntry]] = [:]
    /// 未注入目录时默认走内存后端：E-Core 依然是必选逻辑核心，page-out 照样返回稳定 referenceID，
    /// 只是载荷不跨进程存活。这样 `ContextCompactor()` 不会往用户 home 里写文件。
    public init(
        estimator: any TokenEstimator = ConservativeTokenEstimator(),
        derivedStore: DerivedContextStore = DerivedContextStore(),
        ecoreStore: ECoreObjectStore = ECoreObjectStore(configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: false))
    ) {
        self.estimator = estimator
        self.derivedStore = derivedStore
        self.ecoreStore = ecoreStore
    }
    public func restoreDerived() async throws {
        try await derivedStore.restore()
        for page in await derivedStore.allPages() { _ = await importHistoricalPage(page) }
    }

    /// Imports existing SQLite history without deleting it or creating another page-out store.
    func importHistoricalPage(_ page: DerivedContextPage) async -> ECoreReference {
        await ecoreStore.pageOut(sessionID: page.sessionID, content: page.content, origin: .message,
            contextOccurrenceID: "historical-import:\(page.id)", evictionEpoch: 0,
            summary: "Historical \(page.sourceKind.rawValue): " + String(page.content.prefix(240)),
            pageOutReason: "Import persisted historical context")
    }
    public func restoreResidencies(sessionID: SessionID, values: [ContextUnitDebugSnapshot]) async {
        unitResidencies[sessionID] = Dictionary(uniqueKeysWithValues: values.map { ($0.messageID, $0) })
        for state in values where state.residency == .active {
            guard let refID = state.derivedPageID, state.messageID.rawValue == refID,
                  let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: refID) else { continue }
            admittedPayloads[sessionID, default: [:]][refID] = ContextEntry(messageID: state.messageID, role: .system, source: .derivedPage, part: .text("[Restored session context]\n\(payload)"), segment: .recalledOccurrence)
        }
    }
    /// Retire only removed occurrences. Surviving E-Core-only history must not
    /// become resident merely because the latest user turn was withdrawn.
    public func reconcileAfterRevert(sessionID: SessionID, remainingMessages: [Message]) async {
        let remainingMessageIDs = Set(remainingMessages.map(\.id))
        let validCalls = Set(remainingMessages.flatMap(\.parts).compactMap { part -> ToolCallID? in
            switch part {
            case let .toolCall(call): return call.callID
            case let .toolResult(result): return result.callID
            default: return nil
            }
        })
        await ecoreStore.prune(sessionID: sessionID, keepingToolCallIDs: validCalls)
        let states = unitResidencies[sessionID] ?? [:]
        let removed = states.values.filter {
            !remainingMessageIDs.contains($0.messageID) && $0.messageID.rawValue != $0.derivedPageID
        }
        let survivingRefs = Set(states.values.filter { remainingMessageIDs.contains($0.messageID) }.compactMap(\.derivedPageID))
        for ref in Set(removed.compactMap(\.derivedPageID)).subtracting(survivingRefs) {
            await ecoreStore.dropReference(sessionID: sessionID, referenceID: ref)
        }
        let validRefs = Set(await ecoreStore.references(sessionID: sessionID).map(\.referenceID))
        unitResidencies[sessionID] = states.filter {
            remainingMessageIDs.contains($0.key) || ($0.key.rawValue == $0.value.derivedPageID && validRefs.contains($0.key.rawValue))
        }
        admittedPayloads[sessionID] = admittedPayloads[sessionID]?.filter { validRefs.contains($0.key) }
        evictionTraces.removeValue(forKey: sessionID)
        await derivedStore.reconcileAfterRevert(sessionID: sessionID, remainingMessageIDs: remainingMessageIDs)
    }

    public func reset(sessionID: SessionID) async {
        unitResidencies.removeValue(forKey: sessionID)
        usageLedgers.removeValue(forKey: sessionID)
        evictionTraces.removeValue(forKey: sessionID)
        evictionScoringActiveBySession.removeValue(forKey: sessionID)
        activeWorksetsBySession.removeValue(forKey: sessionID)
        admittedPayloads.removeValue(forKey: sessionID)
        await derivedStore.clear(sessionID: sessionID)
    }
    private struct Unit {
        let indices: [Int]
        let entries: [ContextEntry]
        let batch: ToolExchangeBatch?
        let priority: Int
        /// 账本与投影 turn 的索引键：unit 在投影里的第一个 entry 下标。
        static func indexKey(_ unit: Unit) -> String { "i:\(unit.indices.first ?? -1)" }
    }

    public func compact(sessionID: SessionID, entries: [ContextEntry], budget: ContextBudget, batches: [ToolExchangeBatch] = [], projectBackedContents: Set<String> = [], trigger: CompactionTrigger = .automaticHighWater, evictionEpoch: Int = 0, currentTurn: Int? = nil, activeTask: String = "") async throws -> CompactionResult {
        let entries = activeEntries(sessionID: sessionID, canonicalEntries: entries, batches: batches)
        let before = estimator.estimate(entries: entries)
        let units = makeUnits(entries: entries, batches: batches)
        let currentUser = entries.last { $0.source == .userMessage }?.messageID
        // 契约 4.2 / 第五节的 pinned 集合：pinned 不进入评分，而是直接从候选集排除。
        // 对应关系：system = 约束与安全/权限状态；当前用户指令 = 当前指令；
        // state != .consumed 的批次 = pending Tool Call、当前 Tool 执行状态与未完成因果链。
        // 「当前编辑对象的必要上下文」不额外 pin：它的 activeFileAffinity/dependency 已经是 1.0，
        // pin 只会让高预算下也无法收敛，反而触发 noEligibleReduction。
        let mandatory = units.filter { unit in
            unit.entries.contains { $0.source == .system || $0.messageID == currentUser } ||
            unit.batch.map { $0.state != .consumed } == true
        }
        let mandatoryTokens = mandatory.reduce(0) { $0 + estimator.estimate(entries: $1.entries) }
        guard mandatoryTokens <= budget.hardInputLimit else { throw CoreError(code: .contextBudgetExceeded, message: "必需上下文超出模型输入预算: estimated \(before), hardLimit \(budget.hardInputLimit), mandatory \(mandatoryTokens)") }
        guard trigger != .automaticHighWater || before > budget.highWaterTokens else {
            recordResidencies(sessionID: sessionID, kept: units, pagedOut: [])
            return CompactionResult(entries: entries, beforeTokens: before, afterTokens: before, pagedOut: 0, derivedCreated: 0, triggered: false, triggerSource: trigger, mandatoryFloor: mandatoryTokens, unitsKept: units.count, historicalToolBatchesPagedOut: 0, projectBackedOffloads: 0, redundantDrops: 0, emergencyTrims: 0, noEligibleReduction: true)
        }
        let target = trigger == .emergencyHardLimit ? budget.hardInputLimit : budget.lowWaterTokens
        var pagedOut = 0, historicalBatches = 0, projectBacked = 0, derivedCreated = 0, redundant = 0
        var evictedReferences: [(unit: Unit, reference: ECoreReference)] = []
        var nonDerivedPagedOut: [Unit] = []
        let mandatoryIndices = Set(mandatory.flatMap(\.indices))
        let evictable = units.filter { !Set($0.indices).isSubset(of: mandatoryIndices) }
        // 起点是「全部保留」，然后按 RetentionScore 从低到高逐个移出（契约 4.15），
        // 每移出一个就重算占用，降到 lowWater 立即停止。不按百分比预先决定移出多少对象。
        var keptIndices = Set(units.flatMap(\.indices))
        var tokens = units.reduce(0) { $0 + estimator.estimate(entries: $1.entries) }
        let plan = evictionPlan(sessionID: sessionID, evictable: evictable, entries: entries, batches: batches, budget: budget, activeTask: activeTask, currentTurn: currentTurn)
        var evictedKeys: Set<String> = []
        for candidate in plan.candidates {
            guard tokens > target else { break }
            guard let unit = plan.unitsByFirstIndex[candidate.unitIndices.first ?? -1] else { continue }
            pagedOut += 1
            evictedKeys.insert(candidate.key)
            keptIndices.subtract(unit.indices)
            tokens -= candidate.tokenCost
            if let batch = unit.batch {
                historicalBatches += 1
                let backed = batch.toolResults.allSatisfy { projectBackedContents.contains($0.content) }
                if backed { projectBacked += 1 }
                let evidence = batch.toolCalls.enumerated().map { offset, call in
                    let result = batch.toolResults.indices.contains(offset) ? batch.toolResults[offset] : nil
                    // Failure diagnostics and structured errors are evidence, even when a
                    // successful output can be reconstructed from a project page.
                    let archived = result.flatMap { result -> String? in
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        return try? String(decoding: encoder.encode(result), as: UTF8.self)
                    } ?? "null"
                    let resultSummary = backed && result?.success == true ? "projectPage=available contentHash=\(result.map { ContextPage.fingerprint($0.content.utf8) } ?? "")" : "result=\(archived)"
                    return "tool=\(call.toolID.rawValue) arguments=\(call.arguments) status=\(result?.success == true ? "ok" : "failed") \(resultSummary)"
                }.joined(separator: "\n")
                let reference = await ecoreStore.pageOut(
                    sessionID: sessionID,
                    content: "[Historical tool evidence]\n\(evidence)",
                    origin: .toolCall,
                    contextOccurrenceID: batch.batchID,
                    evictionEpoch: evictionEpoch,
                    summary: Self.summary(of: evidence, kind: "tool-batch"),
                    toolCallID: batch.toolCalls.first?.callID,
                    toolName: batch.toolCalls.first?.toolName,
                    createdTurn: plan.turn(forKey: Self.occurrenceKey(unit: unit)),
                    pageOutReason: trigger.rawValue
                )
                evictedReferences.append((unit, reference))
                derivedCreated += 1
            } else if let first = unit.entries.first, first.source != .projectPage, first.source != .derivedPage {
                let content = unit.entries.map { Self.content(of: $0.part) }.joined(separator: "\n")
                if !content.isEmpty, !projectBackedContents.contains(content) {
                    let reference = await ecoreStore.pageOut(
                        sessionID: sessionID,
                        content: content,
                        origin: Self.origin(of: first.source),
                        contextOccurrenceID: Self.occurrenceKey(unit: unit),
                        evictionEpoch: evictionEpoch,
                        summary: Self.summary(of: content, kind: first.source.rawValue),
                        toolCallID: Self.toolCallID(of: unit),
                        createdTurn: plan.turn(forKey: Self.occurrenceKey(unit: unit)),
                        pageOutReason: trigger.rawValue
                    )
                    evictedReferences.append((unit, reference))
                    derivedCreated += 1
                } else { nonDerivedPagedOut.append(unit) }
            } else { redundant += 1; nonDerivedPagedOut.append(unit) }
        }
        let keptUnits = units.filter { unit in Set(unit.indices).isSubset(of: keptIndices) }
        // 上一轮的索引投影由本轮整体重建：投影是 E-Core 引用的派生视图，不是会继续累积的正文。
        let output = entries.enumerated().compactMap { index, entry -> ContextEntry? in
            guard keptIndices.contains(index), entry.messageID != Self.eCoreIndexMessageID else { return nil }
            return entry
        }
        var finalOutput = output
        if let projection = await eCoreIndexProjection(sessionID: sessionID, kept: output, hardInputLimit: budget.hardInputLimit, query: activeTask.isEmpty ? Self.currentTask(entries) : activeTask) {
            finalOutput.append(projection)
        }
        recordResidencies(sessionID: sessionID, kept: keptUnits, pagedOut: nonDerivedPagedOut, evicted: evictedReferences)
        recordUsage(sessionID: sessionID, units: units, evictedKeys: evictedKeys, turn: plan.currentTurn)
        evictionTraces[sessionID] = plan.trace(evictedKeys: evictedKeys, trigger: plan.usesRetentionScoring ? trigger.rawValue : "scorerUnavailable-\(trigger.rawValue)")
        evictionScoringActiveBySession[sessionID] = plan.usesRetentionScoring
        return CompactionResult(entries: finalOutput, beforeTokens: before, afterTokens: estimator.estimate(entries: finalOutput), pagedOut: pagedOut, derivedCreated: derivedCreated, triggered: pagedOut > 0, triggerSource: trigger, mandatoryFloor: mandatoryTokens, unitsKept: keptUnits.count, historicalToolBatchesPagedOut: historicalBatches, projectBackedOffloads: projectBacked, redundantDrops: redundant, emergencyTrims: trigger == .emergencyHardLimit ? pagedOut : 0, noEligibleReduction: pagedOut == 0)
    }

    /// 一个候选对象在本轮 eviction 中的完整决策依据。契约 4.20：Debug / Inspector 必须能看到全部数值。
    private struct EvictionPlan {
        var currentTurn: Int
        var usesRetentionScoring: Bool
        var candidates: [ContextEvictionCandidate]
        var unitsByFirstIndex: [Int: Unit]
        var turnsByKey: [String: Int]
        var observationsByKey: [String: ContextEvictionTraceEntry]

        func turn(forKey key: String) -> Int { turnsByKey[key] ?? currentTurn }

        /// 按实际移出顺序补上 rank 与 reason；未被移出的候选 rank 为 nil，表示它留在了 P-Core。
        func trace(evictedKeys: Set<String>, trigger: String) -> [ContextEvictionTraceEntry] {
            var rank = 0
            return candidates.compactMap { candidate in
                observationsByKey[candidate.key].map { observation in
                    if evictedKeys.contains(candidate.key) {
                        rank += 1
                        return ContextEvictionTraceEntry(
                            objectKey: observation.objectKey,
                            objectType: observation.objectType,
                            tokenCost: observation.tokenCost,
                            features: observation.features,
                            retentionValue: observation.retentionValue,
                            retentionScore: observation.retentionScore,
                            evictionRank: rank,
                            evictionReason: trigger
                        )
                    }
                    return observation
                }
            }
        }
    }

    /// occurrence key：跨轮稳定的对象身份，同时是 usage 账本的键与 tie-break 的最后一级。
    /// batch 用 batchID，其余用 messageID；两者都没有时退到投影内的位置，保证同轮唯一。
    private static func occurrenceKey(unit: Unit) -> String {
        if let batch = unit.batch { return batch.batchID }
        if let messageID = unit.entries.first?.messageID { return messageID.rawValue }
        return "entry:" + unit.indices.map(String.init).joined(separator: ",")
    }

    /// 打分输入全部来自 compactor 已经掌握的数据：投影内容、批次的路径与 changedFiles、自身的使用账本。
    /// 故意不接 E-Core Heat —— 契约第六节明确 E-Core 热度不是 P-Core eviction 的信号。
    private func evictionPlan(
        sessionID: SessionID,
        evictable: [Unit],
        entries: [ContextEntry],
        batches: [ToolExchangeBatch],
        budget: ContextBudget,
        activeTask: String,
        currentTurn: Int?
    ) -> EvictionPlan {
        let projectionTurns = Self.turnIndices(of: entries)
        let queryText = entries.last { $0.source == .userMessage }.map { Self.content(of: $0.part) } ?? ""
        let turn = max(currentTurn ?? 0, projectionTurns.values.max() ?? 0)
        guard budget.preferredActiveTokens > 0 else {
            // 契约 4.19 Fail-Open：拿不到 pCoreTarget 就无法归一化 tokenCost，退回确定性旧顺序。
            return legacyPlan(units: evictable, turn: turn, projectionTurns: projectionTurns)
        }
        let taskTerms = ContextLexicalAffinity.terms(from: activeTask.isEmpty ? queryText : activeTask)
        let queryTerms = ContextLexicalAffinity.terms(from: queryText)
        let ledger = usageLedgers[sessionID] ?? [:]
        let workset = Self.activeWorkset(of: batches)
        recordActiveWorkset(sessionID: sessionID, workset: workset)
        var candidates: [ContextEvictionCandidate] = []
        var observations: [String: ContextEvictionTraceEntry] = [:]
        var turnsByKey: [String: Int] = [:]
        var unitsByFirstIndex: [Int: Unit] = [:]
        for unit in evictable {
            let key = Self.occurrenceKey(unit: unit)
            let projectedTurn = projectionTurns[Unit.indexKey(unit)] ?? turn
            let entry = ledger[key]
            let createdTurn = entry?.createdTurn ?? projectedTurn
            let lastUsedTurn = max(entry?.lastUsedTurn ?? projectedTurn, projectedTurn)
            let content = unit.entries.map { Self.content(of: $0.part) }.joined(separator: "\n")
            let paths = Self.paths(of: unit)
            let tokenCost = estimator.estimate(entries: unit.entries)
            let signals = ContextRetentionSignals(
                taskAffinity: ContextLexicalAffinity.score(content: content, terms: taskTerms),
                dependencyWeight: Self.dependencyWeight(unit: unit, paths: paths, workset: workset),
                deltaTurn: turn - lastUsedTurn,
                relevance: ContextLexicalAffinity.score(content: content, terms: queryTerms),
                accessCount: entry?.accessCount ?? 0,
                activeFileAffinity: Self.activeFileAffinity(paths: paths, workset: workset),
                explicitReuse: Self.explicitReuse(paths: paths, content: content, queryText: queryText, deltaTurn: turn - lastUsedTurn),
                reconstructability: Self.reconstructability(unit: unit, paths: paths),
                tokenCost: tokenCost
            )
            let estimate = ContextValueScorer.estimate(signals: signals, pCoreTarget: budget.preferredActiveTokens)
            turnsByKey[key] = createdTurn
            unitsByFirstIndex[unit.indices.first ?? -1] = unit
            candidates.append(ContextEvictionCandidate(
                key: key,
                tokenCost: tokenCost,
                lastUsedTurn: lastUsedTurn,
                createdTurn: createdTurn,
                estimate: estimate,
                unitIndices: unit.indices
            ))
            observations[key] = ContextEvictionTraceEntry(
                objectKey: key,
                objectType: unit.batch != nil ? "toolBatch" : (unit.entries.first?.source.rawValue ?? "unknown"),
                tokenCost: tokenCost,
                features: estimate.features,
                retentionValue: estimate.retentionValue,
                retentionScore: estimate.retentionScore,
                evictionRank: nil,
                evictionReason: nil
            )
        }
        return EvictionPlan(
            currentTurn: turn,
            usesRetentionScoring: true,
            candidates: ContextValueScorer.evictionOrder(candidates),
            unitsByFirstIndex: unitsByFirstIndex,
            turnsByKey: turnsByKey,
            observationsByKey: observations
        )
    }

    /// Fallback 顺序：低优先级先移出，同优先级靠前的先移出。完全确定性（契约 4.19），
    /// 且绝不按「token 最大优先」或「最新优先」淘汰 —— 那是被明确禁止的退路。
    private func legacyPlan(units: [Unit], turn: Int, projectionTurns: [String: Int]) -> EvictionPlan {
        var plan = EvictionPlan(currentTurn: turn, usesRetentionScoring: false, candidates: [], unitsByFirstIndex: [:], turnsByKey: [:], observationsByKey: [:])
        for unit in units.sorted(by: { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return (lhs.indices.first ?? 0) < (rhs.indices.first ?? 0)
        }) {
            let key = Self.occurrenceKey(unit: unit)
            let cost = estimator.estimate(entries: unit.entries)
            let created = projectionTurns[Unit.indexKey(unit)] ?? turn
            plan.turnsByKey[key] = created
            plan.unitsByFirstIndex[unit.indices.first ?? -1] = unit
            plan.candidates.append(ContextEvictionCandidate(
                key: key,
                tokenCost: cost,
                lastUsedTurn: created,
                createdTurn: created,
                estimate: .legacyFallback,
                unitIndices: unit.indices
            ))
            plan.observationsByKey[key] = ContextEvictionTraceEntry(
                objectKey: key,
                objectType: unit.batch != nil ? "toolBatch" : (unit.entries.first?.source.rawValue ?? "unknown"),
                tokenCost: cost,
                features: .zero,
                retentionValue: 0,
                retentionScore: 0,
                evictionRank: nil,
                evictionReason: "scorerUnavailable"
            )
        }
        return plan
    }

    /// usage 账本：留在 P-Core 的对象每轮记一次访问，被移出的对象冻结在最后状态。
    /// recency / frequency / explicitReuse 三个特征只能来源于真实观察，不接受常量占位。
    private func recordUsage(sessionID: SessionID, units: [Unit], evictedKeys: Set<String>, turn: Int) {
        var ledger = usageLedgers[sessionID] ?? [:]
        for unit in units {
            let key = Self.occurrenceKey(unit: unit)
            let existing = ledger[key]
            if evictedKeys.contains(key) { continue }
            ledger[key] = ContextUsageRecord(
                createdTurn: existing?.createdTurn ?? turn,
                lastUsedTurn: turn,
                accessCount: (existing?.accessCount ?? 0) + 1
            )
        }
        usageLedgers[sessionID] = ledger
    }

    /// 记录本轮工作集，供召回路径复用。eviction 之外不重复推导一次批次扫描。
    private func recordActiveWorkset(sessionID: SessionID, workset: ActiveWorkset) {
        activeWorksetsBySession[sessionID] = workset.allFiles
    }

    /// 契约 4.20：最近一轮 eviction 的全部特征值与排名，供 Debug / Runtime Inspector 读取。
    public func evictionTrace(sessionID: SessionID) -> [ContextEvictionTraceEntry] { evictionTraces[sessionID] ?? [] }
    /// 本轮走的是 RetentionScore 还是 Fail-Open 退路。可观测性必须区分两者，
    /// 否则退路长期生效会被误读成公式在起作用。
    public func evictionScoringActive(sessionID: SessionID) -> Bool { evictionScoringActiveBySession[sessionID] ?? false }

    /// 本 session 正在编辑 / 最近读写的文件集合。召回路径也用它，这样 activeFileAffinity
    /// 不再是一个恒为空数组的假参数（契约 4.9）。
    public func activeFilePaths(sessionID: SessionID) -> [String] {
        (activeWorksetsBySession[sessionID] ?? []).sorted()
    }

    private struct ContextUsageRecord: Sendable, Equatable {
        let createdTurn: Int
        let lastUsedTurn: Int
        let accessCount: Int
    }

    /// 当前工作集：会话正在编辑 / 读过的文件，以及当前任务直接依赖的路径。
    /// 数据来自 ToolExchangeBatch 的 arguments 与 changedFiles —— 这两个字段在生产里真实有值，
    /// 因此 activeFileAffinity 不再是恒为 0 的假特征（契约 4.9）。
    private struct ActiveWorkset {
        var editedFiles: Set<String> = []
        var openFiles: Set<String> = []
        var dependencyFiles: Set<String> = []

        var allFiles: Set<String> { editedFiles.union(openFiles).union(dependencyFiles) }
    }

    /// 工作集从真实批次数据推导：`ToolResult.changedFiles` 与 `ToolCall.arguments` 里的路径在生产里都有值，
    /// 所以 activeFileAffinity / dependencyWeight 不是恒为 0 的假特征（契约 4.9）。
    private static func activeWorkset(of batches: [ToolExchangeBatch]) -> ActiveWorkset {
        var workset = ActiveWorkset()
        // 最近一次产生过变更的批次 = 当前正在编辑的对象；不看 batch 生死状态，
        // 否则可淘汰候选永远拿不到 1.0 档（未完成任务的批次本来就是 pinned，不参与评分）。
        if let lastMutated = batches.last(where: { !$0.toolResults.flatMap(\.changedFiles).isEmpty }) {
            workset.editedFiles = Set(lastMutated.toolResults.flatMap(\.changedFiles))
        }
        let tail = Array(batches.suffix(4))
        for batch in tail {
            workset.openFiles.formUnion(paths(of: batch))
        }
        // 当前未完成任务 + 最近两个批次引用的路径，就是当前因果链的直接依赖。
        for batch in batches where batch.state != .consumed {
            workset.dependencyFiles.formUnion(paths(of: batch))
        }
        workset.dependencyFiles.formUnion(batches.suffix(2).flatMap { paths(of: $0) })
        return workset
    }

    private static func paths(of batch: ToolExchangeBatch) -> [String] {
        batch.toolResults.flatMap(\.changedFiles) + batch.toolCalls.flatMap { paths(in: $0.arguments) }
    }

    /// 从结构化的 Tool arguments 里取路径类字段。JSON 解析失败按 fail-open 返回空集。
    private static func paths(in arguments: String) -> [String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [] }
        let keys = ["path", "file_path", "file", "target", "cwd", "dir", "directory"]
        var result: [String] = []
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { result.append(value) }
            if let values = dictionary[key + "s"] as? [String] { result.append(contentsOf: values.filter { !$0.isEmpty }) }
        }
        return result
    }

    private static func paths(of unit: Unit) -> [String] {
        if let batch = unit.batch { return paths(of: batch) }
        if case let .toolResult(result) = unit.entries.first?.part { return result.changedFiles }
        if case let .toolCall(call) = unit.entries.first?.part { return paths(in: call.arguments) }
        return []
    }

    /// 契约 4.5：当前未完成因果链直接依赖 1.0，间接依赖 0.6，只有历史依赖 0.2，无依赖 0.0。
    private static func dependencyWeight(unit: Unit, paths: [String], workset: ActiveWorkset) -> Double {
        if !paths.isEmpty && paths.contains(where: { workset.dependencyFiles.contains($0) }) { return 1.0 }
        if !paths.isEmpty && paths.contains(where: { workset.allFiles.contains($0) }) { return 0.6 }
        if unit.batch != nil { return 0.2 }
        return 0.0
    }

    /// 契约 4.9：1.0 正在编辑，0.7 活跃/已打开，0.3 同目录相关，0.0 无文件关系。
    private static func activeFileAffinity(paths: [String], workset: ActiveWorkset) -> Double {
        guard !paths.isEmpty else { return 0 }
        if paths.contains(where: { workset.editedFiles.contains($0) }) { return 1.0 }
        if paths.contains(where: { workset.allFiles.contains($0) }) { return 0.7 }
        let directories = Set(workset.allFiles.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        if paths.contains(where: { directories.contains(URL(fileURLWithPath: $0).deletingLastPathComponent().path) }) { return 0.3 }
        return 0.0
    }

    /// 契约 4.10：当前 turn 明确再次引用 1.0，最近 4 turn 内被再次使用 0.6，否则 0。
    private static func explicitReuse(paths: [String], content: String, queryText: String, deltaTurn: Int) -> Double {
        let haystack = queryText.lowercased()
        if !haystack.isEmpty, paths.contains(where: { haystack.contains($0.lowercased()) }) { return 1.0 }
        if !haystack.isEmpty {
            let identifiers = ContextLexicalAffinity.terms(from: content).filter { $0.count > 6 }
            if identifiers.contains(where: { haystack.contains($0) }) { return 1.0 }
        }
        return deltaTurn <= 4 ? 0.6 : 0.0
    }

    /// 契约 4.11：reconstructability 0.0 无法重建 → 1.0 完全廉价重建。
    /// 判定只看来源类型与工具名，不看 E-Core 热度。
    private static func reconstructability(unit: Unit, paths: [String]) -> Double {
        let toolNames: [String]
        if let batch = unit.batch {
            toolNames = batch.toolCalls.map { $0.toolID.rawValue.lowercased() }
        } else if case let .toolResult(result) = unit.entries.first?.part {
            toolNames = [(result.toolName ?? "").lowercased()]
        } else if case let .toolCall(call) = unit.entries.first?.part {
            toolNames = [call.toolID.rawValue.lowercased()]
        } else {
            toolNames = []
        }
        if !toolNames.isEmpty {
            if toolNames.contains(where: { ["browser_screenshot", "browser_navigate", "browser_observe", "web_fetch", "web_search", "search"].contains($0) || $0.hasPrefix("browser_") || $0.hasPrefix("mcp/") }) { return 0.2 }
            if toolNames.contains(where: { ["shell", "exec", "run_command", "build", "test", "install"].contains($0) || $0.contains("test") }) { return 0.5 }
            if toolNames.contains(where: { $0 == "read_file" || $0 == "read" }) { return paths.isEmpty ? 0.7 : 0.7 }
            if toolNames.contains(where: { ["git", "status", "diff", "log", "list", "ls", "glob", "grep"].contains($0) }) { return 1.0 }
            return 0.5
        }
        switch unit.entries.first?.source {
        case .userMessage?: return 0.0
        case .assistantMessage?: return 0.1
        case .observation?: return 0.2
        case .projectPage?: return 0.7
        case .derivedPage?: return 0.3
        default: return 0.5
        }
    }

    /// 投影内的 turn 序号：以 user message 为分界，第一个 turn 记为 1。
    /// Agent Loop 的上下文变化以 turn 为单位，因此不用 wall-clock 算 recency（契约 4.6）。
    private static func turnIndices(of entries: [ContextEntry]) -> [String: Int] {
        var turn = 0
        var result: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if entry.source == .userMessage { turn += 1 }
            let current = max(1, turn)
            result["i:\(index)"] = current
            if let messageID = entry.messageID { result[messageID.rawValue] = max(result[messageID.rawValue] ?? 0, current) }
        }
        return result
    }

    /// P-Core 的 E-Core Index Projection：每轮从 E-Core 引用重建，只携带 metadata / summary / referenceID，
    /// 不携带已 page-out 的完整载荷（契约第一节）。
    /// 投影自己必须挤进预算：从最近的引用开始逐行加入，装不下就停。放不下的旧引用仍在 E-Core 里，
    /// 仍可由 `context_recall` 按 summary 召回 —— 极端压力下先牺牲索引，不牺牲正文。
    public static let eCoreIndexMessageID = MessageID("ecore:index")
    private static let eCoreIndexHeader = "[E-Core index]"
    private static let eCoreIndexGuide = "以下内容已移出当前上下文，完整载荷在 E-Core；按 reference 精确取回，不要凭摘要重构。"
    private static let eCoreIndexLineLimit = 8
    /// 索引是投影不是正文：最多占输入预算的 1/8，且绝对值不超过 512 tokens。
    public static func eCoreIndexTokenAllowance(hardInputLimit: Int) -> Int {
        min(512, max(0, hardInputLimit / 8))
    }

    private func eCoreIndexProjection(sessionID: SessionID, kept: [ContextEntry], hardInputLimit: Int, query: String) async -> ContextEntry? {
        // Reuse the existing retrieval ranking; the projection owns only selection size.
        let related = await ecoreStore.searchReferences(sessionID: sessionID, query: query, limit: Self.eCoreIndexLineLimit, recordTelemetry: false)
        let recent = await ecoreStore.references(sessionID: sessionID)
        var seen = Set<String>()
        let references = Array((related + recent).filter { seen.insert($0.contextOccurrenceID).inserted }.prefix(Self.eCoreIndexLineLimit))
        guard !references.isEmpty else { return nil }
        let keptTokens = estimator.estimate(entries: kept)
        let allowance = Self.eCoreIndexTokenAllowance(hardInputLimit: hardInputLimit)
        let ceiling = min(hardInputLimit, keptTokens + allowance)
        var lines: [String] = []
        for reference in references {
            lines.append(Self.indexLine(for: reference))
            if let entry = Self.indexEntry(header: Self.eCoreIndexHeader + "\n" + Self.eCoreIndexGuide, lines: lines),
               estimator.estimate(entries: [entry]) <= ceiling - keptTokens { continue }
            lines.removeLast()
            break
        }
        return Self.indexEntry(header: Self.eCoreIndexHeader + "\n" + Self.eCoreIndexGuide, lines: lines)
    }

    private static func indexEntry(header: String, lines: [String]) -> ContextEntry? {
        guard !lines.isEmpty else { return nil }
        return ContextEntry(
            messageID: eCoreIndexMessageID,
            role: .system,
            source: .derivedPage,
            part: .text(([header] + lines).joined(separator: "\n")),
            segment: .eCoreRetrievalProjection
        )
    }

    /// 模型可见行只带 Exact Restore 真正需要的 referenceID：objectID 属于引用元数据，
    /// 由 `ECoreReference` 携带并在 Debug / Inspector 展示（契约 4.20），不重复占用输入预算。
    private static func indexLine(for reference: ECoreReference) -> String {
        var fields = ["reference=\(reference.referenceID)", "origin=\(reference.origin.rawValue)"]
        if let toolCallID = reference.toolCallID { fields.append("toolCall=\(toolCallID.rawValue)") }
        if let createdTurn = reference.createdTurn { fields.append("turn=\(createdTurn)") }
        fields.append("summary=\(reference.summary.prefix(140))")
        return "- " + fields.joined(separator: " ")
    }

    private static func origin(of source: ContextSource) -> ECoreObjectOrigin {
        switch source {
        case .toolCall, .toolResult: return .toolCall
        case .projectPage, .derivedPage: return .page
        default: return .message
        }
    }

    private static func toolCallID(of unit: Unit) -> ToolCallID? {
        for entry in unit.entries {
            switch entry.part {
            case let .toolCall(call): return call.callID
            case let .toolResult(result): return result.callID
            default: continue
            }
        }
        return nil
    }

    /// 摘要必须是确定性的纯函数：同一内容在任何一轮得到同一字符串，否则同 occurrence 重试会写出
    /// 内容不同但 referenceID 相同的引用。
    private static func summary(of content: String, kind: String) -> String {
        let flattened = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let window = flattened.count > 140 ? String(flattened.prefix(140)) : flattened
        return "\(kind): \(window)"
    }

    /// Exact Restore：referenceID → ECoreReference → objectID → 完整载荷（契约第九节）。
    /// 不经过任何词法或语义检索。
    public func pageIn(sessionID: SessionID, referenceID: String, remainingTokens: Int) async -> [ContextEntry] {
        guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: referenceID) else { return [] }
        let entry = ContextEntry(messageID: MessageID(referenceID), role: .system, source: .derivedPage, part: .text("[Restored session context]\n\(payload)"))
        return estimator.estimate(entries: [entry]) <= max(0, remainingTokens) ? [entry] : []
    }

    /// Semantic Recall：query → E-Core 索引摘要 → Exact Restore 取回载荷。
    /// 只有 E-Core 无命中时才回落到 Legacy DerivedContextStore 的只读旧数据。
    public func pageIn(sessionID: SessionID, query: String, remainingTokens: Int) async -> [ContextEntry] {
        var remaining = max(0, remainingTokens)
        var entries: [ContextEntry] = []
        let normalizedQuery = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !normalizedQuery.isEmpty else { return [] }
        let matches = (await ecoreStore.references(sessionID: sessionID)).filter { reference in
            let summary = reference.summary.lowercased()
            return normalizedQuery.contains { summary.contains($0) }
        }.prefix(4)
        for reference in matches {
            guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: reference.referenceID) else { continue }
            let entry = ContextEntry(messageID: MessageID(reference.referenceID), role: .system, source: .derivedPage, part: .text("[Restored session context]\n\(payload)"))
            let cost = estimator.estimate(entries: [entry])
            guard cost <= remaining else { break }
            entries.append(entry)
            remaining -= cost
        }
        guard entries.isEmpty else { return entries }
        var legacyEntries: [ContextEntry] = []
        for page in await derivedStore.search(sessionID: sessionID, query: query, limit: 4) {
            let reference = await importHistoricalPage(page)
            guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: reference.referenceID) else { continue }
            let entry = ContextEntry(messageID: MessageID(page.id), role: .system, source: .derivedPage, part: .text("[Session context]\n\(payload)"))
            let cost = estimator.estimate(entries: [entry])
            guard cost <= remaining else { break }
            legacyEntries.append(entry)
            remaining -= cost
        }
        return legacyEntries
    }
    public func cacheMetrics(sessionID: SessionID) async -> (recallCachePages: Int, projectIndexPages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, projectIndexHits: Int, recallCacheHits: Int, recallCachePromotions: Int) { await derivedStore.metrics(sessionID: sessionID) }
    public func cacheMetrics() async -> (recallCachePages: Int, projectIndexPages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, projectIndexHits: Int, recallCacheHits: Int, recallCachePromotions: Int) { await derivedStore.allMetrics() }
    public func unitStates(sessionID: SessionID) -> [ContextUnitDebugSnapshot] { (unitResidencies[sessionID] ?? [:]).values.sorted { $0.messageID.rawValue < $1.messageID.rawValue } }

    /// Durable history is not the active working set. Live causal batches and the
    /// newest user instruction remain eligible regardless of an old snapshot.
    public func activeEntries(sessionID: SessionID, canonicalEntries: [ContextEntry], batches: [ToolExchangeBatch] = []) -> [ContextEntry] {
        let liveIDs = Set(batches.filter { $0.state != .consumed }.flatMap { [$0.assistantMessageID, $0.resultMessageID].compactMap { $0 } })
        let currentUser = canonicalEntries.last { $0.source == .userMessage }?.messageID
        let states = unitResidencies[sessionID] ?? [:]
        let active = canonicalEntries.filter { entry in
            guard let id = entry.messageID, id != Self.eCoreIndexMessageID else { return true }
            if id == currentUser || liveIDs.contains(id) || entry.source == .system { return true }
            switch states[id]?.residency {
            case .derived, .pagedOut, .superseded: return false
            case .active, nil: return true
            }
        }
        let resident = active.map { entry in
            guard let id = entry.messageID, states[id]?.residency == .active,
                  states[id]?.derivedPageID != nil else { return entry }
            return ContextEntry(messageID: id, role: entry.role, source: entry.source,
                                part: entry.part, page: entry.page, segment: .recalledOccurrence)
        }
        let ids = Set(resident.compactMap(\.messageID))
        return resident + (admittedPayloads[sessionID] ?? [:]).sorted { $0.key < $1.key }.map(\.value).filter {
            guard let id = $0.messageID else { return false }
            return !ids.contains(id) && (states[id]?.residency == nil || states[id]?.residency == .active)
        }
    }

    /// Rebuild the bounded segment on every assembly, including scheduler skip.
    public func projectIndex(sessionID: SessionID, entries: [ContextEntry], hardInputLimit: Int, query: String) async -> [ContextEntry] {
        let history = entries.filter { $0.segment != .eCoreRetrievalProjection && $0.messageID != Self.eCoreIndexMessageID }
        if let index = await eCoreIndexProjection(sessionID: sessionID, kept: history, hardInputLimit: hardInputLimit, query: query) { return history + [index] }
        return history
    }

    /// Called after normal pressure convergence. A resolved ref alone is not admission.
    /// Canonical occurrences are restored as complete causal units; imported payloads
    /// have an explicit active entry. No SessionStore mutation occurs here.
    public func admitRequestedRecalls(sessionID: SessionID, canonicalEntries: [ContextEntry], activeEntries: [ContextEntry], hardInputLimit: Int) async -> [ContextEntry] {
        var active = activeEntries
        for refID in await ecoreStore.takeRecallAdmissions(sessionID: sessionID) {
            guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: refID) else {
                await ecoreStore.noteLifecycle(sessionID: sessionID, phase: .recallRejected, referenceID: refID, reason: "payloadMissing")
                continue
            }
            let states = unitResidencies[sessionID] ?? [:]
            let ids = Set(states.values.filter { $0.derivedPageID == refID }.map(\.messageID))
            let alreadyActive = Set(active.compactMap(\.messageID))
            var restored = canonicalEntries.filter { ids.contains($0.messageID ?? MessageID("")) }
            let retained = active.filter { !ids.contains($0.messageID ?? MessageID("")) }
            if !ids.isEmpty && restored.isEmpty {
                await ecoreStore.noteLifecycle(sessionID: sessionID, phase: .recallRejected, referenceID: refID, reason: "canonicalOccurrenceMissing")
                continue
            }
            if ids.isEmpty && !alreadyActive.contains(MessageID(refID)) {
                restored = [ContextEntry(messageID: MessageID(refID), role: .system, source: .derivedPage, part: .text("[Restored session context]\n\(payload)"))]
            }
            let cost = estimator.estimate(entries: retained + restored)
            guard cost <= hardInputLimit else {
                await ecoreStore.noteLifecycle(sessionID: sessionID, phase: .recallRejected, referenceID: refID, reason: "inputBudgetExceeded: required=\(cost), hard=\(hardInputLimit)")
                continue
            }
            restored = restored.map { ContextEntry(messageID: $0.messageID, role: $0.role, source: $0.source, part: $0.part, page: $0.page, segment: .recalledOccurrence) }
            // Prepend restored historical units so a pending tail stays last.
            let prefix = retained.prefix { $0.source == .system }
            active = Array(prefix) + restored + retained.dropFirst(prefix.count)
            for entry in restored {
                guard let id = entry.messageID else { continue }
                let old = states[id]
                unitResidencies[sessionID, default: [:]][id] = .init(messageID: id, residency: .active, derivedPageID: refID, contentHash: old?.contentHash)
                if ids.isEmpty { admittedPayloads[sessionID, default: [:]][refID] = entry }
            }
            await ecoreStore.noteLifecycle(sessionID: sessionID, phase: .recallAdmitted, referenceID: refID)
        }
        return active
    }

    private static func currentTask(_ entries: [ContextEntry]) -> String {
        guard let last = entries.last(where: { $0.source == .userMessage }), case let .text(text) = last.part else { return "" }
        return text
    }
    static func content(of part: SessionMessagePart) -> String { switch part { case let .text(text): text; case let .toolCall(call): call.arguments; case let .toolResult(result): result.content + (result.error?.message ?? ""); case let .observation(id): "[Observation: \(id.description)]" } }

    private func makeUnits(entries: [ContextEntry], batches: [ToolExchangeBatch]) -> [Unit] {
        let byMessageID = Dictionary(uniqueKeysWithValues: batches.flatMap { batch in
            [batch.assistantMessageID, batch.resultMessageID].compactMap { $0 }.map { ($0, batch) }
        })
        var seen = Set<String>()
        var result: [Unit] = []
        for (index, entry) in entries.enumerated() {
            if let id = entry.messageID, let batch = byMessageID[id] {
                guard seen.insert(batch.batchID).inserted else { continue }
                let indices = entries.indices.filter { candidate in
                    guard let candidateID = entries[candidate].messageID else { return false }
                    return candidateID == batch.assistantMessageID || candidateID == batch.resultMessageID
                }
                let unitEntries = indices.map { entries[$0] }
                result.append(Unit(indices: indices, entries: unitEntries, batch: batch, priority: batch.state == .consumed ? 1 : 100))
            } else {
                let priority: Int
                switch entry.source {
                case .system: priority = 90
                case .userMessage: priority = 70
                // Between the user's own sentence and the assistant history that follows it:
                // the file they just handed us matters more than what the model said last turn,
                // and evicting it is a decision the P-side retention score makes here — not
                // something E-Core heat gets a vote on.
                case .attachment: priority = 65
                case .assistantMessage: priority = 60
                case .projectPage, .derivedPage: priority = 40
                case .toolCall, .toolResult: priority = 1
                case .observation: priority = 50
                }
                result.append(Unit(indices: [index], entries: [entry], batch: nil, priority: priority))
            }
        }
        return result
    }

    private func recordResidencies(sessionID: SessionID, kept: [Unit], pagedOut: [Unit], evicted: [(unit: Unit, reference: ECoreReference)] = []) {
        var values = unitResidencies[sessionID] ?? [:]
        for unit in kept {
            for id in unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .active, derivedPageID: values[id]?.derivedPageID, contentHash: values[id]?.contentHash)
            }
        }
        for unit in pagedOut {
            for id in unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .pagedOut)
            }
        }
        for pair in evicted {
            for id in pair.unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .derived, derivedPageID: pair.reference.referenceID, contentHash: pair.reference.objectID.rawValue)
            }
        }
        unitResidencies[sessionID] = values
    }
}
