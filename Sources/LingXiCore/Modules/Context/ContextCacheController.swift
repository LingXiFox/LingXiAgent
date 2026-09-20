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

/// Warm L2 / Derived L3 / E-Core 驻留状态与重复数据量化指标
public struct ContextResidencyTelemetry: Sendable, Codable, Equatable {
    public let sessionID: String
    public let l1ResidentCount: Int
    public let l1ResidentTokens: Int
    public let warmL2EntryCount: Int
    public let warmL2Tokens: Int
    public let residentDerivedCount: Int
    public let ecoreObjectCount: Int
    public let ecoreTotalBytes: Int
    public let duplicateResidencyBytes: Int

    public init(
        sessionID: String,
        l1ResidentCount: Int,
        l1ResidentTokens: Int,
        warmL2EntryCount: Int,
        warmL2Tokens: Int,
        residentDerivedCount: Int,
        ecoreObjectCount: Int,
        ecoreTotalBytes: Int,
        duplicateResidencyBytes: Int
    ) {
        self.sessionID = sessionID
        self.l1ResidentCount = l1ResidentCount
        self.l1ResidentTokens = l1ResidentTokens
        self.warmL2EntryCount = warmL2EntryCount
        self.warmL2Tokens = warmL2Tokens
        self.residentDerivedCount = residentDerivedCount
        self.ecoreObjectCount = ecoreObjectCount
        self.ecoreTotalBytes = ecoreTotalBytes
        self.duplicateResidencyBytes = duplicateResidencyBytes
    }
}

/// Cache Controller 负责三级缓存的加权调度与 L1/L2/L3 Residency 管理。
/// 模型只负责声明检索意图 (context_search)，调度决策完全由 Cache Controller 驱动。
public actor ContextCacheController {
    public let policy: EffectiveContextPolicy
    public nonisolated let ecoreStore: ECoreObjectStore
    public nonisolated let scheduler: CacheAwareContextScheduler
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
    // Last Provider prompt cache hit (cachedTokens, promptTokens)
    private var lastPromptCacheHitBySession: [SessionID: (cachedTokens: Int, promptTokens: Int)] = [:]
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
        weights: CachePriorityWeights = CachePriorityWeights(),
        ecoreStore: ECoreObjectStore? = nil,
        scheduler: CacheAwareContextScheduler? = nil
    ) {
        self.contextPager = contextPager
        self.scanner = scanner
        self.compactor = compactor
        self.policy = policy
        self.weights = weights
        self.ecoreStore = ecoreStore ?? ECoreObjectStore()
        self.scheduler = scheduler ?? CacheAwareContextScheduler()
    }

    // Convenience initializer preserving existing calls
    public init(
        contextPager: ContextPager,
        scanner: ProjectScanner,
        compactor: ContextCompactor? = nil,
        maxL1ResidentCharacters: Int,
        weights: CachePriorityWeights = CachePriorityWeights(),
        ecoreStore: ECoreObjectStore? = nil,
        scheduler: CacheAwareContextScheduler? = nil
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
        self.ecoreStore = ecoreStore ?? ECoreObjectStore()
        self.scheduler = scheduler ?? CacheAwareContextScheduler()
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

    public struct SessionCacheRecord: Sendable, Equatable {
        public var cachedTokens: Int
        public var promptTokens: Int
        public var previousPromptTokens: Int?
        public var status: String // "active", "coldNewEpoch", "unavailable"
        public var epoch: Int
        public var epochReason: String?
        public var stablePrefixHash: String?
        public var missDiagnostics: String?
        public var provider: String?
        public var model: String?
        public var cacheWriteTokens: Int?
        public var contextGrowthDelta: Int?

        public init(
            cachedTokens: Int,
            promptTokens: Int,
            previousPromptTokens: Int? = nil,
            status: String = "active",
            epoch: Int = 1,
            epochReason: String? = nil,
            stablePrefixHash: String? = nil,
            missDiagnostics: String? = nil,
            provider: String? = nil,
            model: String? = nil,
            cacheWriteTokens: Int? = nil,
            contextGrowthDelta: Int? = nil
        ) {
            self.cachedTokens = cachedTokens
            self.promptTokens = promptTokens
            self.previousPromptTokens = previousPromptTokens
            self.status = status
            self.epoch = epoch
            self.epochReason = epochReason
            self.stablePrefixHash = stablePrefixHash
            self.missDiagnostics = missDiagnostics
            self.provider = provider
            self.model = model
            self.cacheWriteTokens = cacheWriteTokens
            self.contextGrowthDelta = contextGrowthDelta ?? previousPromptTokens.map { promptTokens - $0 }
        }
    }

    private var sessionCacheRecords: [SessionID: SessionCacheRecord] = [:]
    private var sessionEpochs: [SessionID: Int] = [:]
    private var sessionEpochReasons: [SessionID: String] = [:]
    private var previousPromptTokensBySession: [SessionID: Int] = [:]
    private var currentTurnFingerprintBySession: [SessionID: PrefixFingerprint] = [:]
    private var lastTurnFingerprintBySession: [SessionID: PrefixFingerprint] = [:]
    private var lastHistorySignaturesBySession: [SessionID: [String]] = [:]
    private var clientStructuralHealthBySession: [SessionID: ClientStructuralCacheHealth] = [:]
    private var turnsInEpochBySession: [SessionID: Int] = [:]
    private var clientBustsInEpochBySession: [SessionID: Int] = [:]

    /// 推进 CacheEpoch（仅由实质语义变更触发，如 model switch / provider switch / context rollover）
    public func advanceEpoch(sessionID: SessionID, reason: String) {
        let current = sessionEpochs[sessionID] ?? 1
        sessionEpochs[sessionID] = current + 1
        sessionEpochReasons[sessionID] = reason
        previousPromptTokensBySession[sessionID] = nil
        currentTurnFingerprintBySession[sessionID] = nil
        lastTurnFingerprintBySession[sessionID] = nil
        lastHistorySignaturesBySession[sessionID] = nil
        turnsInEpochBySession[sessionID] = 0
        clientBustsInEpochBySession[sessionID] = 0
    }

    /// 记录当前推理前计算的 Prefix 指纹及客户端自身结构健康度
    public func recordFingerprint(
        sessionID: SessionID,
        fingerprint: PrefixFingerprint,
        prefixBytes: Int = 0,
        volatileBytes: Int = 0,
        historySignatures: [String]? = nil
    ) {
        let lastFP = lastTurnFingerprintBySession[sessionID] ?? currentTurnFingerprintBySession[sessionID]
        currentTurnFingerprintBySession[sessionID] = fingerprint
        let epoch = sessionEpochs[sessionID] ?? 1
        let turns = (turnsInEpochBySession[sessionID] ?? 0) + 1
        turnsInEpochBySession[sessionID] = turns

        let isBust: Bool
        let isAppendOnly: Bool
        let status: String

        if let lastFP {
            if lastFP.stablePrefixHash != fingerprint.stablePrefixHash {
                isBust = true
                clientBustsInEpochBySession[sessionID] = (clientBustsInEpochBySession[sessionID] ?? 0) + 1
                status = "bustDetected"
            } else {
                isBust = false
                status = "stable"
            }

            // 审计报告 #44：严格断言 Append-Only。杜绝任何 !isEmpty 的伪阳性掩盖！
            if lastFP.historyStableHash == fingerprint.historyStableHash {
                // 历史哈希完全相同
                isAppendOnly = true
            } else if let historySignatures, let lastSignatures = lastHistorySignaturesBySession[sessionID] {
                // 历史发生变动时，检查当前历史签名序列是否以前一次历史为前缀 (Prefix Extension)
                if historySignatures.count >= lastSignatures.count &&
                   historySignatures.prefix(lastSignatures.count).elementsEqual(lastSignatures) {
                    isAppendOnly = true
                } else {
                    // 发生了旧条目修改、历史删除、压缩或重排，真实判定非 append-only
                    isAppendOnly = false
                }
            } else {
                // 未提供前缀签名且哈希发生突变，不能直接断定为 append-only
                isAppendOnly = false
            }
        } else {
            isBust = false
            isAppendOnly = true
            status = "newEpoch"
        }

        if let historySignatures {
            lastHistorySignaturesBySession[sessionID] = historySignatures
        }

        let totalBusts = clientBustsInEpochBySession[sessionID] ?? 0
        let bustRate = turns > 0 ? Double(totalBusts) / Double(turns) : 0.0

        let health = ClientStructuralCacheHealth(
            stablePrefixHash: fingerprint.stablePrefixHash,
            stablePrefixBytes: prefixBytes,
            stablePrefixSegments: 2,
            appendOnlyHistory: isAppendOnly,
            prefixMutationDetected: isBust,
            cacheEpoch: epoch,
            clientCausedBustRate: bustRate,
            appendOnlyRatio: isAppendOnly ? 1.0 : 0.5,
            volatileTailBytes: volatileBytes,
            status: status,
            clientCausedBusts: totalBusts,
            comparableRequests: turns,
            appendOnlyViolations: isAppendOnly ? 0 : 1
        )
        clientStructuralHealthBySession[sessionID] = health
    }

    /// 获取客户端自身结构化缓存健康指标（第一权威真相）
    public func lastClientHealth(for sessionID: SessionID) -> ClientStructuralCacheHealth? {
        clientStructuralHealthBySession[sessionID]
    }

    /// 记录最近一次 Provider 推理返回的真实 Prefix Cache 命中情况
    public func recordProviderCacheHit(
        sessionID: SessionID,
        cachedTokens: Int,
        promptTokens: Int,
        cacheWriteTokens: Int? = nil,
        provider: String? = nil,
        model: String? = nil,
        isUnavailable: Bool = false
    ) async {
        let epoch = sessionEpochs[sessionID] ?? 1
        let reason = sessionEpochReasons[sessionID] ?? "initial_turn"
        let prev = previousPromptTokensBySession[sessionID]
        let currentFP = currentTurnFingerprintBySession[sessionID]
        let lastFP = lastTurnFingerprintBySession[sessionID]

        let status: String
        var missDiagnostics: String? = nil

        if isUnavailable {
            status = "unavailable"
            if let currentFP, let lastFP, currentFP.stablePrefixHash != lastFP.stablePrefixHash {
                missDiagnostics = "CLIENT CACHE BUST DETECTED: stablePrefixHash changed unexpectedly within Epoch \(epoch)"
            }
        } else if prev == nil || prev == 0 {
            status = "coldNewEpoch"
        } else {
            status = "active"
            if let prev, prev > 0 {
                let reuseEfficiency = Double(cachedTokens) / Double(prev)
                let isSignificantHit = cachedTokens >= 1024 || reuseEfficiency >= 0.5
                if !isSignificantHit {
                    missDiagnostics = generateMissDiagnostics(old: lastFP, new: currentFP, prevTokens: prev, cachedTokens: cachedTokens)
                    let isClientBust = (lastFP != nil && currentFP != nil && lastFP?.stablePrefixHash != currentFP?.stablePrefixHash)
                    if isClientBust {
                        await scheduler.recordBust(sessionID: sessionID)
                    }
                } else {
                    if reuseEfficiency < 0.9 {
                        missDiagnostics = generateMissDiagnostics(old: lastFP, new: currentFP, prevTokens: prev, cachedTokens: cachedTokens)
                    }
                    await scheduler.recordHit(sessionID: sessionID)
                }
            }
        }

        let record = SessionCacheRecord(
            cachedTokens: cachedTokens,
            promptTokens: promptTokens,
            previousPromptTokens: prev,
            status: status,
            epoch: epoch,
            epochReason: reason,
            stablePrefixHash: currentFP?.stablePrefixHash,
            missDiagnostics: missDiagnostics,
            provider: provider ?? "provider",
            model: model,
            cacheWriteTokens: cacheWriteTokens
        )
        sessionCacheRecords[sessionID] = record
        let currentDebt = await scheduler.debtState(for: sessionID).cacheDebt
        savePersistedTelemetry(sessionID: sessionID, record: record, debt: currentDebt)
        lastPromptCacheHitBySession[sessionID] = (cachedTokens, promptTokens)

        // 为下一轮更新上一轮理论可复用 token 数及上一轮指纹
        previousPromptTokensBySession[sessionID] = promptTokens
        if let currentFP {
            lastTurnFingerprintBySession[sessionID] = currentFP
        }
    }

    private func generateMissDiagnostics(old: PrefixFingerprint?, new: PrefixFingerprint?, prevTokens: Int, cachedTokens: Int) -> String {
        guard let old, let new else {
            let diff = max(0, prevTokens - cachedTokens)
            return "Prefix miss: ~\(diff) tokens dropped (first tracked turn)"
        }
        var changes: [String] = []
        if old.systemHash != new.systemHash {
            changes.append("systemHash changed (\(old.systemHash.prefix(8)) -> \(new.systemHash.prefix(8)))")
        }
        if old.coreToolsHash != new.coreToolsHash {
            changes.append("coreToolsHash changed (\(old.coreToolsHash.prefix(8)) -> \(new.coreToolsHash.prefix(8)))")
        }
        if old.leasedToolsHash != new.leasedToolsHash {
            changes.append("leasedToolsHash changed (\(old.leasedToolsHash.prefix(8)) -> \(new.leasedToolsHash.prefix(8)))")
        }
        if old.skillPrefixHash != new.skillPrefixHash {
            changes.append("skillPrefixHash changed (\(old.skillPrefixHash.prefix(8)) -> \(new.skillPrefixHash.prefix(8)))")
        }
        if old.requestProfileHash != new.requestProfileHash {
            changes.append("requestProfileHash changed (\(old.requestProfileHash.prefix(8)) -> \(new.requestProfileHash.prefix(8)))")
        }
        if old.historyStableHash != new.historyStableHash {
            changes.append("historyStableHash changed (\(old.historyStableHash.prefix(8)) -> \(new.historyStableHash.prefix(8)))")
        }
        let diff = max(0, prevTokens - cachedTokens)
        if changes.isEmpty {
            return "status: upstream cache variance suspected (Client structural prefix 100% stable, missed ~\(diff) tokens)"
        } else {
            let bustNote = changes.contains(where: { $0.contains("coreToolsHash") || $0.contains("systemHash") }) ? " [CLIENT CACHE BUST DETECTED]" : ""
            return "Prefix miss source:\(bustNote) " + changes.joined(separator: ", ") + " (missed ~\(diff) tokens)"
        }
    }

    /// 获取最近一次 Provider 推理返回的真实详细 Cache 记录
    public func lastProviderCacheRecord(for sessionID: SessionID) -> SessionCacheRecord? {
        if let record = sessionCacheRecords[sessionID] {
            return record
        }
        if let hydrated = loadPersistedTelemetry(sessionID: sessionID) {
            sessionCacheRecords[sessionID] = hydrated
            return hydrated
        }
        return nil
    }

    private func telemetryFileURL(sessionID: SessionID) -> URL {
        let safeSessionID = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let dir = ecoreStore.baseDirectory.appendingPathComponent(safeSessionID, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("telemetry.json", isDirectory: false)
    }

    /// 获取指定会话的 Warm L2 / Derived L3 / E-Core 驻留状态与重复驻留数据量化统计
    public func residencyTelemetry(sessionID: SessionID) async -> ContextResidencyTelemetry {
        let l1 = residentPagesBySession[sessionID] ?? [:]
        let l1Tokens = l1.values.reduce(0) { $0 + $1.tokens }
        let l2 = warmL2EntriesBySession[sessionID] ?? [:]
        let l2Tokens = l2.values.reduce(0) { $0 + $1.tokens }
        let derived = residentDerivedPagesBySession[sessionID] ?? [:]
        
        let ecoreObjects = await ecoreStore.listObjects(sessionID: sessionID)
        let ecoreBytes = ecoreObjects.reduce(0) { $0 + $1.totalBytes }
        
        var dupBytes = 0
        let ecoreNames = Set(ecoreObjects.map { $0.toolName.lowercased() })
        for entry in l2.values {
            if let content = entry.page?.content ?? entry.derivedPage?.content {
                if ecoreNames.contains(entry.id.lowercased()) {
                    dupBytes += content.utf8.count
                }
            }
        }

        return ContextResidencyTelemetry(
            sessionID: sessionID.rawValue,
            l1ResidentCount: l1.count,
            l1ResidentTokens: l1Tokens,
            warmL2EntryCount: l2.count,
            warmL2Tokens: l2Tokens,
            residentDerivedCount: derived.count,
            ecoreObjectCount: ecoreObjects.count,
            ecoreTotalBytes: ecoreBytes,
            duplicateResidencyBytes: dupBytes
        )
    }

    private func savePersistedTelemetry(sessionID: SessionID, record: SessionCacheRecord, debt: Int) {
        struct DTO: Codable {
            let cachedTokens: Int
            let promptTokens: Int
            let previousPromptTokens: Int?
            let status: String
            let epoch: Int
            let epochReason: String?
            let stablePrefixHash: String?
            let missDiagnostics: String?
            let provider: String?
            let model: String?
            let cacheWriteTokens: Int?
            let cacheDebt: Int
            let warmL2Count: Int?
            let ecoreObjectCount: Int?
            let duplicateResidencyBytes: Int?
        }
        let l2Count = warmL2EntriesBySession[sessionID]?.count ?? 0
        let dto = DTO(
            cachedTokens: record.cachedTokens,
            promptTokens: record.promptTokens,
            previousPromptTokens: record.previousPromptTokens,
            status: record.status,
            epoch: record.epoch,
            epochReason: record.epochReason,
            stablePrefixHash: record.stablePrefixHash,
            missDiagnostics: record.missDiagnostics,
            provider: record.provider,
            model: record.model,
            cacheWriteTokens: record.cacheWriteTokens,
            cacheDebt: debt,
            warmL2Count: l2Count,
            ecoreObjectCount: nil,
            duplicateResidencyBytes: nil
        )
        if let data = try? JSONEncoder().encode(dto) {
            let url = telemetryFileURL(sessionID: sessionID)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadPersistedTelemetry(sessionID: SessionID) -> SessionCacheRecord? {
        struct DTO: Codable {
            let cachedTokens: Int
            let promptTokens: Int
            let previousPromptTokens: Int?
            let status: String
            let epoch: Int
            let epochReason: String?
            let stablePrefixHash: String?
            let missDiagnostics: String?
            let provider: String?
            let model: String?
            let cacheWriteTokens: Int?
            let cacheDebt: Int?
        }
        let url = telemetryFileURL(sessionID: sessionID)
        guard let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return nil
        }
        let record = SessionCacheRecord(
            cachedTokens: dto.cachedTokens,
            promptTokens: dto.promptTokens,
            previousPromptTokens: dto.previousPromptTokens,
            status: dto.status,
            epoch: dto.epoch,
            epochReason: dto.epochReason,
            stablePrefixHash: dto.stablePrefixHash,
            missDiagnostics: dto.missDiagnostics,
            provider: dto.provider,
            model: dto.model,
            cacheWriteTokens: dto.cacheWriteTokens
        )
        if let debt = dto.cacheDebt, debt > 0 {
            Task { await scheduler.restoreDebtState(sessionID: sessionID, debt: debt) }
        }
        return record
    }

    /// 获取最近一次 Provider 推理返回的真实 Prefix Cache 命中情况（兼容旧调用）
    public func lastProviderCacheHit(for sessionID: SessionID) -> (cachedTokens: Int, promptTokens: Int)? {
        lastPromptCacheHitBySession[sessionID]
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

    /// P-Core 活跃上下文 Token 数
    public func pCoreUsageTokens(for sessionID: SessionID) -> Int {
        lastProviderCacheRecord(for: sessionID)?.promptTokens ?? l1UsageTokens(for: sessionID)
    }

    /// E-Core 对象总数（O(1) 读取）
    public func eCoreObjectCount(for sessionID: SessionID) async -> Int {
        let metrics = await ecoreStore.storageMetrics(for: sessionID)
        return metrics.count
    }

    /// E-Core 存储总字节数（O(1) 读取）
    public func eCoreTotalBytes(for sessionID: SessionID) async -> Int {
        let metrics = await ecoreStore.storageMetrics(for: sessionID)
        return metrics.totalBytes
    }

    /// [Legacy Compatibility] 旧 L2 工作集占用数
    public func l2UsageTokens(for sessionID: SessionID) -> Int {
        warmL2EntriesBySession[sessionID]?.values.reduce(0) { $0 + $1.tokens } ?? 0
    }

    /// [Legacy Compatibility] 旧 L2 条目数
    public func l2Count(for sessionID: SessionID) -> Int {
        warmL2EntriesBySession[sessionID]?.count ?? 0
    }

    /// [Legacy Compatibility] 旧 L3 占用数
    public func l3UsageTokens(for sessionID: SessionID) async -> Int {
        0
    }

    /// [Legacy Compatibility] 旧 L3 条目数
    public func l3Count(for sessionID: SessionID) async -> Int {
        0
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

        // 4. Search E-Core Object Fabric (权威沉淀观测与大对象织物)
        let ecoreMatches = await ecoreStore.search(sessionID: sessionID, query: query, limit: limit)
        var ecoreResults: [(ObservationMetadata, String)] = []
        for meta in ecoreMatches {
            let content = (try? await ecoreStore.fetch(sessionID: sessionID, objectID: meta.objectID)) ?? ""
            let snippet = content.count > 500 ? String(content.prefix(500)) + "..." : content
            ecoreResults.append((meta, snippet))
        }

        // Check if anything matched across all sources
        guard !l2Candidates.isEmpty || !l3Candidates.isEmpty || !codebaseCandidates.isEmpty || !ecoreResults.isEmpty else {
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
        if !ecoreResults.isEmpty {
            let formatted = ecoreResults.map { meta, snippet in
                "- [\(meta.toolName)] (\(meta.objectID.rawValue), \(meta.totalBytes) bytes):\n```\n\(snippet)\n```"
            }.joined(separator: "\n")
            outputSections.append("## E-Core Fabric Objects (\(ecoreResults.count) objects recalled)\n" + formatted)
        }

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

    /// 撤回（undo）操作后对齐 P-E 双核心架构状态与缓存基线
    public func reconcileAfterRevert(sessionID: SessionID, remainingMessages: [Message]) async {
        // 1. 提取剩余消息中所有有效的 ToolCallID
        var validToolCallIDs = Set<ToolCallID>()
        for msg in remainingMessages {
            for part in msg.parts {
                if case let .toolCall(tc) = part {
                    validToolCallIDs.insert(tc.callID)
                }
                if case let .toolResult(res) = part {
                    validToolCallIDs.insert(res.callID)
                }
            }
        }

        // 2. E-Core 存储裁剪：清理已被撤回的 Tool 所生成的大对象文件
        await ecoreStore.prune(sessionID: sessionID, keepingToolCallIDs: validToolCallIDs)

        // 3. P-Core (L1) 状态重置：撤回导致上一次 Provider 调用的 Cache Record 失效
        lastProviderInputTokensBySession.removeValue(forKey: sessionID)
        previousPromptTokensBySession.removeValue(forKey: sessionID)
        currentTurnFingerprintBySession.removeValue(forKey: sessionID)
        lastTurnFingerprintBySession.removeValue(forKey: sessionID)
        sessionCacheRecords.removeValue(forKey: sessionID)
        let telemetryFile = telemetryFileURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: telemetryFile)
        residentDerivedPagesBySession.removeValue(forKey: sessionID)
        sessionEpochs[sessionID] = (sessionEpochs[sessionID] ?? 1) + 1
        sessionEpochReasons[sessionID] = "revert_turn"

        // 4. 重新基于剩余有效消息精确估算 L1 / P-Core 常驻 Tokens
        if remainingMessages.isEmpty {
            await clearSessionState(sessionID: sessionID)
            return
        } else {
            let estimator = ConservativeTokenEstimator()
            var entries: [ContextEntry] = []
            for msg in remainingMessages {
                let ctxRole: ContextRole
                let src: ContextSource
                switch msg.role {
                case .user: ctxRole = .user; src = .userMessage
                case .assistant: ctxRole = .assistant; src = .assistantMessage
                case .tool: ctxRole = .tool; src = .toolResult
                }
                for part in msg.parts {
                    entries.append(ContextEntry(
                        messageID: msg.id,
                        role: ctxRole,
                        source: src,
                        part: part
                    ))
                }
            }
            let tokens = estimator.estimate(entries: entries)
            sessionL1BaseTokens[sessionID] = tokens
            sessionL1BaseCount[sessionID] = entries.count
            previousPromptTokensBySession[sessionID] = tokens
            lastProviderInputTokensBySession[sessionID] = tokens

            // 建立撤回后的合成基线记录，确保前缀复用与 P-Core 状态平滑衔接，不发生归零或乱跳
            let revertEpoch = sessionEpochs[sessionID] ?? 1
            let revertRecord = SessionCacheRecord(
                cachedTokens: 0,
                promptTokens: tokens,
                previousPromptTokens: tokens,
                status: "coldNewEpoch",
                epoch: revertEpoch,
                epochReason: "revert_turn",
                stablePrefixHash: nil,
                missDiagnostics: nil,
                provider: nil,
                model: nil,
                cacheWriteTokens: nil
            )
            sessionCacheRecords[sessionID] = revertRecord
            savePersistedTelemetry(sessionID: sessionID, record: revertRecord, debt: 0)
        }

        // 5. 调度器经济学债务状态对齐
        await scheduler.reset(sessionID: sessionID)
    }

    /// 统一彻底清理指定 Session 的所有级别状态、指标与缓存记录
    public func clearSessionState(sessionID: SessionID) async {
        residentPagesBySession.removeValue(forKey: sessionID)
        residentDerivedPagesBySession.removeValue(forKey: sessionID)
        sessionL1BaseTokens.removeValue(forKey: sessionID)
        sessionL1BaseCount.removeValue(forKey: sessionID)
        lastProviderInputTokensBySession.removeValue(forKey: sessionID)
        lastPromptCacheHitBySession.removeValue(forKey: sessionID)
        warmL2EntriesBySession.removeValue(forKey: sessionID)
        pageInsBySession.removeValue(forKey: sessionID)
        pageOutsBySession.removeValue(forKey: sessionID)
        promotionsBySession.removeValue(forKey: sessionID)
        demotionsBySession.removeValue(forKey: sessionID)

        sessionCacheRecords.removeValue(forKey: sessionID)
        sessionEpochs.removeValue(forKey: sessionID)
        sessionEpochReasons.removeValue(forKey: sessionID)
        previousPromptTokensBySession.removeValue(forKey: sessionID)
        currentTurnFingerprintBySession.removeValue(forKey: sessionID)
        lastTurnFingerprintBySession.removeValue(forKey: sessionID)
        lastHistorySignaturesBySession.removeValue(forKey: sessionID)
        clientStructuralHealthBySession.removeValue(forKey: sessionID)
        turnsInEpochBySession.removeValue(forKey: sessionID)
        clientBustsInEpochBySession.removeValue(forKey: sessionID)

        await scheduler.reset(sessionID: sessionID)
        await ecoreStore.cleanSession(sessionID: sessionID)
        let url = telemetryFileURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: url)
    }

    /// 重置指定 Session 的所有级别缓存（用于 /new 或 session 清理）
    public func resetSession(_ sessionID: SessionID) async {
        await clearSessionState(sessionID: sessionID)
    }

    /// 检查指定会话是否残留任何内存状态（供测试与诊断使用）
    public func hasResidualSessionState(sessionID: SessionID) -> Bool {
        residentPagesBySession[sessionID] != nil ||
        residentDerivedPagesBySession[sessionID] != nil ||
        sessionL1BaseTokens[sessionID] != nil ||
        sessionL1BaseCount[sessionID] != nil ||
        lastProviderInputTokensBySession[sessionID] != nil ||
        lastPromptCacheHitBySession[sessionID] != nil ||
        warmL2EntriesBySession[sessionID] != nil ||
        pageInsBySession[sessionID] != nil ||
        pageOutsBySession[sessionID] != nil ||
        promotionsBySession[sessionID] != nil ||
        demotionsBySession[sessionID] != nil ||
        sessionCacheRecords[sessionID] != nil ||
        sessionEpochs[sessionID] != nil ||
        sessionEpochReasons[sessionID] != nil ||
        previousPromptTokensBySession[sessionID] != nil ||
        currentTurnFingerprintBySession[sessionID] != nil ||
        lastTurnFingerprintBySession[sessionID] != nil ||
        clientStructuralHealthBySession[sessionID] != nil ||
        turnsInEpochBySession[sessionID] != nil ||
        clientBustsInEpochBySession[sessionID] != nil
    }

    /// 获取指定会话的 E-Core 热度调试与可观测性快照（只读旁路接口）
    /// 架构边界红线：E-Core Hot/Cold 仅属于 E-Core 内部存储与检索优化，
    /// 绝对禁止操纵 L1/L2 缓存，绝对禁止与 L1/L2 生命周期联动，绝对不影响 Prefix Cache 与 P-Core。
    public func eCoreHeatSnapshot(sessionID: SessionID, topN: Int = 10) async -> ECoreHeatSnapshot? {
        await ecoreStore.heatSnapshot(sessionID: sessionID, topN: topN)
    }

    /// 获取指定会话的 E-Core 观测期指标（只读旁路接口）
    public func eCoreObservationMetrics(sessionID: SessionID) async -> ECoreObservationMetrics {
        await ecoreStore.exportObservationMetrics(sessionID: sessionID)
    }
}

