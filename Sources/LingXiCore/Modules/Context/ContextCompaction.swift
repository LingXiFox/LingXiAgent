import Foundation
import LingXiProtocol

public protocol TokenEstimator: Sendable {
    func estimate(text: String) -> Int
    func estimate(entries: [ContextEntry]) -> Int
    func estimate(tools: [ToolDefinition]) -> Int
}

public struct ConservativeTokenEstimator: TokenEstimator {
    public init() {}
    public func estimate(text: String) -> Int { max(1, (text.utf8.count + 2) / 3) }
    public func estimate(entries: [ContextEntry]) -> Int {
        entries.reduce(0) { $0 + estimate(text: ContextCompactor.content(of: $1.part)) + 4 }
    }
    public func estimate(tools: [ToolDefinition]) -> Int {
        tools.reduce(0) { $0 + estimate(text: "\($1.id.rawValue) \($1.description) \($1.inputSchema)") + 12 }
    }
}

public struct ModelContextProfile: Sendable, Equatable {
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

public struct ContextBudgetPolicy: Sendable, Equatable {
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
}

public struct ContextBudget: Sendable, Equatable {
    public let hardInputLimit: Int
    public let preferredActiveTokens: Int
    public let highWaterTokens: Int
    public let lowWaterTokens: Int
    public let reservedOutputTokens: Int
    public let fixedOverheadTokens: Int
    public let safetyMarginTokens: Int
}

public struct ContextBudgetPlanner: Sendable {
    public let policy: ContextBudgetPolicy
    public init(policy: ContextBudgetPolicy = ContextBudgetPolicy()) { self.policy = policy }
    public func plan(profile: ModelContextProfile, requestedMaxOutputTokens: Int? = nil, toolTokens: Int = 0) -> ContextBudget {
        let reserve = max(requestedMaxOutputTokens ?? 0, profile.recommendedOutputReserveTokens ?? profile.maxOutputTokens ?? 4_096)
        let hard = max(0, profile.contextWindowTokens - reserve - policy.fixedOverheadTokens - toolTokens - policy.safetyMarginTokens)
        let preferred = min(hard, policy.preferredActiveTokens ?? min(policy.defaultActiveCeiling, Int(Double(hard) * policy.preferredRatio)))
        return ContextBudget(hardInputLimit: hard, preferredActiveTokens: preferred, highWaterTokens: min(hard, Int(Double(preferred) * 1.15)), lowWaterTokens: Int(Double(preferred) * 0.8), reservedOutputTokens: reserve, fixedOverheadTokens: policy.fixedOverheadTokens + toolTokens, safetyMarginTokens: policy.safetyMarginTokens)
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
public struct ToolExchangeBatch: Sendable, Equatable {
    public let batchID: String
    public let sessionID: SessionID
    public let assistantMessageID: MessageID
    public let resultMessageID: MessageID?
    public let toolCalls: [ToolCall]
    public let toolResults: [ToolResult]
    public let providerStep: Int
    public let state: ToolExchangeBatchState
    public let estimatedTokens: Int
    public var isComplete: Bool { Set(toolCalls.map(\.callID)) == Set(toolResults.map(\.callID)) && toolCalls.count == toolResults.count }

    public init(batchID: String, sessionID: SessionID, assistantMessageID: MessageID, resultMessageID: MessageID? = nil, toolCalls: [ToolCall], toolResults: [ToolResult] = [], providerStep: Int, state: ToolExchangeBatchState, estimatedTokens: Int) {
        self.batchID = batchID
        self.sessionID = sessionID
        self.assistantMessageID = assistantMessageID
        self.resultMessageID = resultMessageID
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.providerStep = providerStep
        self.state = state
        self.estimatedTokens = estimatedTokens
    }

    public func with(state: ToolExchangeBatchState, resultMessageID: MessageID? = nil, toolResults: [ToolResult]? = nil, estimatedTokens: Int? = nil) -> ToolExchangeBatch {
        ToolExchangeBatch(batchID: batchID, sessionID: sessionID, assistantMessageID: assistantMessageID, resultMessageID: resultMessageID ?? self.resultMessageID, toolCalls: toolCalls, toolResults: toolResults ?? self.toolResults, providerStep: providerStep, state: state, estimatedTokens: estimatedTokens ?? self.estimatedTokens)
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
            case .text:
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
    private var l2: [SessionID: [DerivedContextPage]] = [:]
    private var pageOutCount = 0
    private var pageInCount = 0
    private var l3Hits = 0
    private var l2Hits = 0
    private var l2Promotions = 0
    private let persistence: SQLitePersistenceStore?
    public init(persistence: SQLitePersistenceStore? = nil) { self.persistence = persistence }
    public func restore() async throws {
        guard let persistence else { return }
        pages = Dictionary(grouping: try await persistence.loadDerived(), by: \.sessionID)
    }
    public func pageOut(_ page: DerivedContextPage) async throws {
        if !(pages[page.sessionID] ?? []).contains(page) {
            pages[page.sessionID, default: []].append(page)
            pageOutCount += 1
        }
    }
    public func search(sessionID: SessionID, query: String, limit: Int) -> [DerivedContextPage] {
        let normalizedQuery = query.lowercased()
        let terms = Set(normalizedQuery.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let identifiers = normalizedQuery.split(whereSeparator: \.isWhitespace).filter { $0.contains("-") }
        let current = l2[sessionID] ?? []
        let candidates = pages[sessionID] ?? []
        let scored = candidates.enumerated().map { index, page in
            let content = page.content.lowercased()
            let lexical = terms.reduce(0) { $0 + (content.contains($1) ? 1 : 0) }
            let identifierMatch = identifiers.contains { content.contains($0) } ? 100 : 0
            let sourceWeight = page.sourceKind == .historicalTool ? 1 : 2
            let l2Bonus = current.contains(page) ? 2 : 0
            return (page, lexical, identifierMatch, lexical * 10 + sourceWeight + l2Bonus + index)
        }
        let lexicalMatches = scored.filter { terms.isEmpty || $0.1 > 0 }
        let identifierMatches = scored.filter { $0.2 > 0 }
        let userIdentifierMatches = identifierMatches.filter { $0.0.sourceKind == .user }
        // Chinese prompts without a literal marker still need a bounded Session fallback.
        let hasChinese = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let candidatesForPageIn = !userIdentifierMatches.isEmpty ? userIdentifierMatches : (!identifierMatches.isEmpty ? identifierMatches : (lexicalMatches.isEmpty && hasChinese ? scored : lexicalMatches))
        let matches = candidatesForPageIn.sorted { $0.3 > $1.3 }.prefix(limit).map(\.0)
        for page in matches {
            if current.contains(page) { l2Hits += 1 } else { l2Promotions += 1 }
        }
        l3Hits += matches.count
        l2[sessionID] = Array(matches)
        pageInCount += matches.count
        return Array(matches)
    }
    public func metrics(sessionID: SessionID) -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) { (l2[sessionID]?.count ?? 0, pages[sessionID]?.count ?? 0, pageOutCount, pageInCount, (pages[sessionID] ?? []).filter { $0.sourceKind == .historicalTool }.count, l3Hits, l2Hits, l2Promotions) }
    public func allMetrics() -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) {
        (l2.values.reduce(0) { $0 + $1.count }, pages.values.reduce(0) { $0 + $1.count }, pageOutCount, pageInCount, pages.values.flatMap { $0 }.filter { $0.sourceKind == .historicalTool }.count, l3Hits, l2Hits, l2Promotions)
    }
    public func pages(sessionID: SessionID) -> [DerivedContextPage] { pages[sessionID] ?? [] }
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
    public nonisolated let derivedStore: DerivedContextStore
    private var unitResidencies: [SessionID: [MessageID: ContextUnitDebugSnapshot]] = [:]
    public init(estimator: any TokenEstimator = ConservativeTokenEstimator(), derivedStore: DerivedContextStore = DerivedContextStore()) { self.estimator = estimator; self.derivedStore = derivedStore }
    public func restoreDerived() async throws { try await derivedStore.restore() }
    public func restoreResidencies(sessionID: SessionID, values: [ContextUnitDebugSnapshot]) {
        unitResidencies[sessionID] = Dictionary(uniqueKeysWithValues: values.map { ($0.messageID, $0) })
    }
    private struct Unit {
        let indices: [Int]
        let entries: [ContextEntry]
        let batch: ToolExchangeBatch?
        let priority: Int
    }

    public func compact(sessionID: SessionID, entries: [ContextEntry], budget: ContextBudget, batches: [ToolExchangeBatch] = [], projectBackedContents: Set<String> = [], trigger: CompactionTrigger = .automaticHighWater) async throws -> CompactionResult {
        let before = estimator.estimate(entries: entries)
        let units = makeUnits(entries: entries, batches: batches)
        let currentUser = entries.last { $0.source == .userMessage }?.messageID
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
        var kept = mandatory
        var tokens = mandatoryTokens
        var pagedOut = 0, historicalBatches = 0, projectBacked = 0, derivedCreated = 0, redundant = 0
        var derivedUnits: [(unit: Unit, page: DerivedContextPage)] = []
        var nonDerivedPagedOut: [Unit] = []
        let mandatoryIndices = Set(mandatory.flatMap(\.indices))
        let optional = units.filter { !Set($0.indices).isSubset(of: mandatoryIndices) }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return ($0.indices.max() ?? 0) > ($1.indices.max() ?? 0)
        }
        for unit in optional {
            let cost = estimator.estimate(entries: unit.entries)
            if tokens + cost <= target {
                kept.append(unit)
                tokens += cost
            } else {
                pagedOut += 1
                if let batch = unit.batch {
                    historicalBatches += 1
                    let backed = batch.toolResults.allSatisfy { projectBackedContents.contains($0.content) }
                    if backed { projectBacked += 1 }
                    let evidence = batch.toolCalls.enumerated().map { offset, call in
                        let result = batch.toolResults.indices.contains(offset) ? batch.toolResults[offset] : nil
                        let resultSummary = backed ? "projectPage=available contentHash=\(result.map { ContextPage.fingerprint($0.content.utf8) } ?? "")" : "result=\(result?.content ?? "")"
                        return "tool=\(call.toolID.rawValue) arguments=\(call.arguments) status=\(result?.success == true ? "ok" : "failed") \(resultSummary)"
                    }.joined(separator: "\n")
                    let page = DerivedContextPage(sessionID: sessionID, sourceKind: .historicalTool, content: "[Historical tool evidence]\n\(evidence)", messageID: batch.assistantMessageID, tokenEstimate: cost, provenanceIDs: [batch.batchID])
                    try await derivedStore.pageOut(page)
                    derivedUnits.append((unit, page))
                    derivedCreated += 1
                } else if let first = unit.entries.first, first.source != .projectPage, first.source != .derivedPage {
                    let content = unit.entries.map { Self.content(of: $0.part) }.joined(separator: "\n")
                    if !content.isEmpty, !projectBackedContents.contains(content) {
                        let kind: DerivedContextSourceKind = first.source == .userMessage ? .user : .assistant
                        let page = DerivedContextPage(sessionID: sessionID, sourceKind: kind, content: content, messageID: first.messageID, tokenEstimate: cost, provenanceIDs: first.messageID.map { [$0.rawValue] } ?? [])
                        try await derivedStore.pageOut(page)
                        derivedUnits.append((unit, page))
                        derivedCreated += 1
                    } else { nonDerivedPagedOut.append(unit) }
                } else { redundant += 1; nonDerivedPagedOut.append(unit) }
            }
        }
        let keptIndices = Set(kept.flatMap(\.indices))
        let output = entries.enumerated().compactMap { keptIndices.contains($0.offset) ? $0.element : nil }
        recordResidencies(sessionID: sessionID, kept: kept, pagedOut: nonDerivedPagedOut, derived: derivedUnits)
        return CompactionResult(entries: output, beforeTokens: before, afterTokens: estimator.estimate(entries: output), pagedOut: pagedOut, derivedCreated: derivedCreated, triggered: pagedOut > 0, triggerSource: trigger, mandatoryFloor: mandatoryTokens, unitsKept: kept.count, historicalToolBatchesPagedOut: historicalBatches, projectBackedOffloads: projectBacked, redundantDrops: redundant, emergencyTrims: trigger == .emergencyHardLimit ? pagedOut : 0, noEligibleReduction: pagedOut == 0)
    }
    public func pageIn(sessionID: SessionID, query: String, remainingTokens: Int) async -> [ContextEntry] {
        var remaining = max(0, remainingTokens)
        var entries: [ContextEntry] = []
        for page in await derivedStore.search(sessionID: sessionID, query: query, limit: 4) {
            let entry = ContextEntry(messageID: MessageID(page.id), role: .system, source: .derivedPage, part: .text("[Session context]\n\(page.content)"))
            let cost = estimator.estimate(entries: [entry])
            guard cost <= remaining else { break }
            entries.append(entry)
            remaining -= cost
        }
        return entries
    }
    public func cacheMetrics(sessionID: SessionID) async -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) { await derivedStore.metrics(sessionID: sessionID) }
    public func cacheMetrics() async -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) { await derivedStore.allMetrics() }
    public func unitStates(sessionID: SessionID) -> [ContextUnitDebugSnapshot] { (unitResidencies[sessionID] ?? [:]).values.sorted { $0.messageID.rawValue < $1.messageID.rawValue } }
    static func content(of part: SessionMessagePart) -> String { switch part { case let .text(text): text; case let .toolCall(call): call.arguments; case let .toolResult(result): result.content + (result.error?.message ?? "") } }

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
                case .assistantMessage: priority = 60
                case .projectPage, .derivedPage: priority = 40
                case .toolCall, .toolResult: priority = 1
                }
                result.append(Unit(indices: [index], entries: [entry], batch: nil, priority: priority))
            }
        }
        return result
    }

    private func recordResidencies(sessionID: SessionID, kept: [Unit], pagedOut: [Unit], derived: [(unit: Unit, page: DerivedContextPage)] = []) {
        var values = unitResidencies[sessionID] ?? [:]
        for unit in kept {
            for id in unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .active)
            }
        }
        for unit in pagedOut {
            for id in unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .pagedOut)
            }
        }
        for pair in derived {
            for id in pair.unit.entries.compactMap(\.messageID) {
                values[id] = ContextUnitDebugSnapshot(messageID: id, residency: .derived, derivedPageID: pair.page.id, contentHash: pair.page.contentHash)
            }
        }
        unitResidencies[sessionID] = values
    }
}
