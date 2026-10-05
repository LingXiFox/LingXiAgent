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

public struct PCoreResidentPage: Sendable, Equatable {
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

/// P-Core resident pages and authoritative E-Core storage metrics.
public struct ContextResidencyTelemetry: Sendable, Codable, Equatable {
    public let sessionID: String
    public let pCoreResidentCount: Int
    public let pCoreResidentTokens: Int
    public let residentDerivedCount: Int
    public let ecoreObjectCount: Int
    public let ecoreTotalBytes: Int
    public let duplicateResidencyBytes: Int

    public init(
        sessionID: String,
        pCoreResidentCount: Int,
        pCoreResidentTokens: Int,
        residentDerivedCount: Int,
        ecoreObjectCount: Int,
        ecoreTotalBytes: Int,
        duplicateResidencyBytes: Int
    ) {
        self.sessionID = sessionID
        self.pCoreResidentCount = pCoreResidentCount
        self.pCoreResidentTokens = pCoreResidentTokens
        self.residentDerivedCount = residentDerivedCount
        self.ecoreObjectCount = ecoreObjectCount
        self.ecoreTotalBytes = ecoreTotalBytes
        self.duplicateResidencyBytes = duplicateResidencyBytes
    }
}

/// Schedules P-Core residency and E-Core page-out/recall against one runtime policy.
/// 模型只负责声明检索意图 (context_search)，调度决策完全由 Cache Controller 驱动。
public actor ContextCacheController {
    public nonisolated let runtimeContext: ModelRuntimeContextState
    public nonisolated var policy: EffectiveContextPolicy { runtimeContext.snapshot().policy }
    public nonisolated let ecoreStore: ECoreObjectStore
    public nonisolated let scheduler: CacheAwareContextScheduler
    private let weights: CachePriorityWeights
    private let contextPager: ContextPager
    private let scanner: ProjectScanner
    public nonisolated let compactor: ContextCompactor?
    private var clock: UInt64 = 0

    // Per-session PCore resident dynamic pages
    private var residentPagesBySession: [SessionID: [String: PCoreResidentPage]] = [:]
    // Per-session session-level base PCore tokens (messages + system prompt)
    private var sessionPCoreBaseTokens: [SessionID: Int] = [:]
    private var sessionPCoreBaseCount: [SessionID: Int] = [:]
    // Last Provider input tokens recorded during context build for inference
    private var lastProviderInputTokensBySession: [SessionID: Int] = [:]
    // Last Provider prompt cache hit (cachedTokens, promptTokens)
    private var lastPromptCacheHitBySession: [SessionID: (cachedTokens: Int, promptTokens: Int)] = [:]
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
        scheduler: CacheAwareContextScheduler? = nil,
        runtimeContext: ModelRuntimeContextState? = nil
    ) {
        self.contextPager = contextPager
        self.scanner = scanner
        self.compactor = compactor
        self.runtimeContext = runtimeContext ?? ModelRuntimeContextState(policy: policy)
        self.weights = weights
        self.ecoreStore = ecoreStore ?? ECoreObjectStore()
        self.scheduler = scheduler ?? CacheAwareContextScheduler()
    }

    // Convenience initializer preserving existing calls
    public init(
        contextPager: ContextPager,
        scanner: ProjectScanner,
        compactor: ContextCompactor? = nil,
        maxPCoreResidentCharacters: Int,
        weights: CachePriorityWeights = CachePriorityWeights(),
        ecoreStore: ECoreObjectStore? = nil,
        scheduler: CacheAwareContextScheduler? = nil
    ) {
        self.contextPager = contextPager
        self.scanner = scanner
        self.compactor = compactor
        self.runtimeContext = ModelRuntimeContextState(policy: EffectiveContextPolicy(
            addressableBudget: 1_048_576,
            modelWindow: 1_048_576,
            economicThreshold: 272_000,
            reserve: 22_000,
            pCoreTarget: max(1, maxPCoreResidentCharacters / 3),
            pCoreSoftLimit: max(2, Int(Double(maxPCoreResidentCharacters / 3) * 1.07)),
            pCoreHardLimit: max(3, Int(Double(maxPCoreResidentCharacters / 3) * 1.14)),
            eCoreStorageBudget: 456_576,
            eCoreRecallBudget: 350_000,
            eCorePressureThreshold: 0.85
        ))
        self.weights = weights
        self.ecoreStore = ecoreStore ?? ECoreObjectStore()
        self.scheduler = scheduler ?? CacheAwareContextScheduler()
    }

    /// Replaces only the policy. Residency, object storage, epochs and prefix records are untouched.
    @discardableResult
    public nonisolated func updatePolicy(_ policy: EffectiveContextPolicy) -> Bool {
        runtimeContext.updatePolicy(policy)
    }

    @discardableResult
    nonisolated func updateRuntimeContext(assembly: ModelRuntimeAssembly, policy: EffectiveContextPolicy) -> Bool {
        runtimeContext.apply(assembly: assembly, policy: policy)
    }

    /// Reuses the retrieval pressure path without admitting or restoring any pages.
    public func reconcilePolicyPressure() async {
        let sessions = Set(residentPagesBySession.keys).union(sessionPCoreBaseTokens.keys)
        for sessionID in sessions {
            let activeFiles = await compactor?.activeFilePaths(sessionID: sessionID) ?? []
            await enforceResidentBudget(sessionID: sessionID, query: "", activeTask: "",
                                  activeFiles: activeFiles, currentClock: clock)
        }
    }

    /// 记录指定 Session 的基础 PCore token 数与条目数（当前 resident working set）
    public func recordPCoreBaseTokens(sessionID: SessionID, tokens: Int, count: Int? = nil) {
        sessionPCoreBaseTokens[sessionID] = tokens
        if let count { sessionPCoreBaseCount[sessionID] = count }
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
        historySignatures: [String]? = nil,
        canonicalStablePrefix: String? = nil
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
        recordDebugPrefixAudit(sessionID: sessionID,
                               fingerprint: fingerprint,
                               previous: lastFP,
                               health: health,
                               canonical: canonicalStablePrefix,
                               isBust: isBust,
                               status: status)
    }

    // MARK: - Developer Debug Mode（纯旁路）

    /// Developer Debug Mode 旁路。nil 表示未开启。
    private var debugHub: DebugTelemetryHub?

    /// 上一轮 canonical stable prefix 全文，只为算字节公共前缀而留。
    ///
    /// 每会话一份，且随会话重置清空。绝不可改成保存历史列表：稳定前缀可到两百 KB，
    /// 几百轮就是上百 MB，而这个面板的存在意义恰恰是发现这类泄漏。
    private var lastCanonicalPrefixBySession: [SessionID: String] = [:]

    func attachDebugHub(_ hub: DebugTelemetryHub?) {
        debugHub = hub
    }

    /// Answers the question this whole surface exists for: after an E-Core page-out or restore,
    /// did the stable prefix actually change — and if so, at which byte.
    ///
    /// Runs only while the hub exists. When debug mode is off this returns at the first line, and
    /// nothing below it — including the O(prefix) byte scan — is reached.
    private func recordDebugPrefixAudit(
        sessionID: SessionID,
        fingerprint: PrefixFingerprint,
        previous: PrefixFingerprint?,
        health: ClientStructuralCacheHealth,
        canonical: String?,
        isBust: Bool,
        status: String
    ) {
        guard let hub = debugHub else {
            lastCanonicalPrefixBySession[sessionID] = nil
            return
        }
        let previousCanonical = lastCanonicalPrefixBySession[sessionID]
        lastCanonicalPrefixBySession[sessionID] = canonical

        // Byte-wise common prefix. Reported as bytes, never as tokens: Core estimates token counts
        // but has no tokenizer, and calling a byte offset a token position would be the confident
        // wrongness this panel is supposed to make impossible.
        let commonBytes: Int
        let currentBytes: Int
        if let canonical {
            let current = Array(canonical.utf8)
            currentBytes = current.count
            if let previousCanonical {
                let prior = Array(previousCanonical.utf8)
                var shared = 0
                let limit = min(current.count, prior.count)
                while shared < limit && current[shared] == prior[shared] {
                    shared += 1
                }
                commonBytes = shared
            } else {
                // First turn observed: nothing to compare against, which is not the same as
                // "changed completely".
                commonBytes = current.count
            }
        } else {
            commonBytes = 0
            currentBytes = 0
        }

        hub.recordPrefixAudit(DebugPrefixByteAudit(
            stablePrefixCommonBytes: commonBytes,
            promptFirstChangedByteOffset: commonBytes,
            stablePrefixBytes: currentBytes,
            previousStablePrefixHash: previous?.stablePrefixHash,
            currentStablePrefixHash: fingerprint.stablePrefixHash,
            bustReason: isBust ? status : nil,
            clientCaused: isBust ? true : nil,
            requestProfileHash: fingerprint.requestProfileHash,
            canonicalDefinition: canonical == nil ? .fingerprintProfile : .epochCanonical
        ), sessionID: sessionID)

        hub.record(DebugTelemetryEvent(
            sequence: 0,
            timestamp: .now,
            category: isBust ? .cacheBust : (previous == nil ? .cacheEpochAdvanced : .contextPromptBuilt),
            sessionID: sessionID,
            promptAudit: hub.prefixAudit(sessionID: sessionID)
        ))

        hub.recordCache(DebugCacheSampleMapper.from(health: health, audit: hub.prefixAudit(sessionID: sessionID)),
                        sessionID: sessionID)
    }

    /// Forgets a session's debug scratch state. Core calls this on session reset so the retained
    /// canonical text cannot outlive the session it describes.
    public func forgetDebugSession(_ sessionID: SessionID) {
        lastCanonicalPrefixBySession[sessionID] = nil
        debugHub?.forgetSession(sessionID)
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

    /// Reports resident P-Core pages and stored E-Core objects.
    public func residencyTelemetry(sessionID: SessionID) async -> ContextResidencyTelemetry {
        let pCore = residentPagesBySession[sessionID] ?? [:]
        let pCoreTokens = pCore.values.reduce(0) { $0 + $1.tokens }
        let derived = residentDerivedPagesBySession[sessionID] ?? [:]
        
        let ecoreObjects = await ecoreStore.listObjects(sessionID: sessionID)
        let ecoreBytes = ecoreObjects.reduce(0) { $0 + $1.totalBytes }
        
        return ContextResidencyTelemetry(
            sessionID: sessionID.rawValue,
            pCoreResidentCount: pCore.count,
            pCoreResidentTokens: pCoreTokens,
            residentDerivedCount: derived.count,
            ecoreObjectCount: ecoreObjects.count,
            ecoreTotalBytes: ecoreBytes,
            duplicateResidencyBytes: 0
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
            let ecoreObjectCount: Int?
            let duplicateResidencyBytes: Int?
        }
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
        // Old rewind code persisted a full-history estimate as measured usage.
        // Invalidation markers retain epoch identity without inventing an inference.
        if dto.status == "invalidated" || (dto.status == "coldNewEpoch" && dto.epochReason == "revert_turn" && dto.provider == nil && dto.model == nil) {
            sessionEpochs[sessionID] = max(sessionEpochs[sessionID] ?? 1, dto.epoch)
            sessionEpochReasons[sessionID] = dto.epochReason
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

    /// PCore 当前占用 token 数
    public func pCoreResidentTokens(for sessionID: SessionID) -> Int {
        let dynamicTokens = residentPagesBySession[sessionID]?.values.reduce(0) { $0 + $1.tokens } ?? 0
        let baseTokens = sessionPCoreBaseTokens[sessionID] ?? 0
        return dynamicTokens + baseTokens
    }

    /// PCore 条目数
    public func pCoreResidentCount(for sessionID: SessionID) -> Int {
        let dynamicCount = residentPagesBySession[sessionID]?.count ?? 0
        let baseCount = sessionPCoreBaseCount[sessionID] ?? ((sessionPCoreBaseTokens[sessionID] ?? 0) > 0 ? 1 : 0)
        return dynamicCount + baseCount
    }

    /// P-Core 活跃上下文 Token 数
    public func pCoreUsageTokens(for sessionID: SessionID) -> Int {
        lastProviderCacheRecord(for: sessionID)?.promptTokens ?? pCoreResidentTokens(for: sessionID)
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

    /// 调度统计指标
    public func pagingStats(for sessionID: SessionID) -> ContextPagingStats {
        ContextPagingStats(
            pageIns: pageInsBySession[sessionID] ?? 0,
            pageOuts: pageOutsBySession[sessionID] ?? 0,
            promotions: promotionsBySession[sessionID] ?? 0,
            demotions: demotionsBySession[sessionID] ?? 0
        )
    }

    /// 执行明确检索并将高权重条目调度到当前 Session 的 PCore Working Set
    /// `activeFiles` 不再是调用方参数：此前所有调用点都传 `[]`，activeFileAffinity 因此恒为 0。
    /// 现在由 eviction 同一份真实工作集推导（契约 4.9）。
    public func handleSearch(sessionID: SessionID, query: String, activeTask: String = "", limit: Int = 5) async throws -> String {
        clock &+= 1
        let currentClock = clock
        let activeFiles = await compactor?.activeFilePaths(sessionID: sessionID) ?? []

        // Import matching historical SQLite pages through the E-Core entrance.
        var historicalCandidates: [(DerivedContextPage, Double)] = []
        if let compactor {
            let derivedMatches = await compactor.derivedStore.search(sessionID: sessionID, query: query, limit: limit)
            for page in derivedMatches {
                _ = await compactor.importHistoricalPage(page)
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
                historicalCandidates.append((page, score))
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
        // The unified universe, so a paged-out object is found by the same query that finds an
        // artifact. A snippet here is a preview of a hit, never proof the model saw the occurrence.
        let ecoreMatches = await ecoreStore.searchObjects(sessionID: sessionID, query: query, limit: limit)
        var ecoreResults: [(ECoreObjectStore.ECoreSearchableObject, String)] = []
        for object in ecoreMatches {
            let content = await ecoreStore.payloadText(sessionID: sessionID, objectID: object.objectID) ?? ""
            let snippet = content.count > 500 ? String(content.prefix(500)) + "..." : content
            ecoreResults.append((object, snippet))
        }

        // Search reference-backed E-Core objects from history and retrieved pages.
        // 召回按 summary 命中，载荷一律按 referenceID 走 Exact Restore 取，不靠检索内容猜。
        var pagedOutResults: [(ECoreReference, String)] = []
        for reference in await ecoreStore.searchReferences(sessionID: sessionID, query: query, limit: limit) {
            guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: reference.referenceID) else { continue }
            let snippet = payload.count > 500 ? String(payload.prefix(500)) + "..." : payload
            pagedOutResults.append((reference, snippet))
            pageInsBySession[sessionID, default: 0] += 1
            if reference.origin == .page { promotionsBySession[sessionID, default: 0] += 1 }
        }

        // Check if anything matched across all sources
        guard !historicalCandidates.isEmpty || !codebaseCandidates.isEmpty || !ecoreResults.isEmpty || !pagedOutResults.isEmpty else {
            return "No matching context found for query: \"\(query)\"."
        }

        var currentPCore = residentPagesBySession[sessionID] ?? [:]
        var pagedInCodebasePages: [ContextPage] = []
        var pagedInDerivedPages: [DerivedContextPage] = []

        // Admit imported historical pages into the active P-Core.
        for (historicalEntry, _) in historicalCandidates.prefix(limit) {
            pageInsBySession[sessionID, default: 0] += 1
            pagedInDerivedPages.append(historicalEntry)
            residentDerivedPagesBySession[sessionID, default: [:]][historicalEntry.id] = historicalEntry
        }

        // Admit Codebase entries
        codebaseCandidates.sort { $0.1 > $1.1 }
        for (page, _, reason) in codebaseCandidates.prefix(limit) {
            currentPCore[page.id] = PCoreResidentPage(
                page: page,
                tokens: max(1, page.characterCount / 3),
                lastUsed: currentClock,
                accessCount: (currentPCore[page.id]?.accessCount ?? 0) + 1,
                retrievalRelevance: 1.0,
                isPinned: false,
                inclusionReason: reason
            )
            pagedInCodebasePages.append(page)
            pageInsBySession[sessionID, default: 0] += 1
        }

        // Record admission into context pager
        await contextPager.recordInjection(pagedInCodebasePages)

        residentPagesBySession[sessionID] = currentPCore
        await enforceResidentBudget(sessionID: sessionID, query: query, activeTask: activeTask,
                              activeFiles: activeFiles, currentClock: currentClock)

        var outputSections: [String] = []
        if !ecoreResults.isEmpty {
            let formatted = ecoreResults.map { object, snippet in
                "- [\(object.kind.rawValue)] [\(object.toolName)] (\(object.objectID.rawValue), \(object.totalBytes) bytes)"
                + (object.referenceID.map { ", reference=\($0)" } ?? "") + ":\n```\n\(snippet)\n```"
            }.joined(separator: "\n")
            outputSections.append("## E-Core Fabric Objects (\(ecoreResults.count) objects recalled)\n" + formatted)
        }

        if !pagedOutResults.isEmpty {
            let formatted = pagedOutResults.map { reference, snippet in
                "- [\(reference.origin.rawValue)] reference=\(reference.referenceID) object=\(reference.objectID.rawValue):\n```\n\(snippet)\n```"
            }.joined(separator: "\n")
            outputSections.append("## E-Core Paged-Out Context (\(pagedOutResults.count) objects restored by reference)\n" + formatted)
        }

        if !pagedInCodebasePages.isEmpty {
            let formatted = pagedInCodebasePages.map { page in
                "### \(page.path):\(page.startLine)-\(page.endLine)\n```\n\(page.content)\n```"
            }.joined(separator: "\n\n")
            outputSections.append("## Codebase Context (\(pagedInCodebasePages.count) pages paged into PCore)\n" + formatted)
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

    private func enforceResidentBudget(sessionID: SessionID, query: String, activeTask: String,
                                       activeFiles: [String], currentClock: UInt64) async {
        let policy = self.policy
        var currentPCore = residentPagesBySession[sessionID] ?? [:]
        // Select pages using the existing priority formula; payloads page out only to E-Core.
        var pageOuts: [PCoreResidentPage] = []
        let baseTokens = sessionPCoreBaseTokens[sessionID] ?? 0
        var dynamicTokens = currentPCore.values.reduce(0) { $0 + $1.tokens }

        while (dynamicTokens + baseTokens) > policy.pCoreSoftLimit && currentPCore.count > 1 {
            let lowest = currentPCore.values.filter { !$0.isPinned }.min { lhs, rhs in
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
            currentPCore.removeValue(forKey: victim.page.id)
            dynamicTokens -= victim.tokens

            pageOuts.append(victim)
            demotionsBySession[sessionID, default: 0] += 1
            pageOutsBySession[sessionID, default: 0] += 1
        }

        residentPagesBySession[sessionID] = currentPCore
        for victim in pageOuts {
            _ = await ecoreStore.pageOut(sessionID: sessionID, content: victim.page.content,
                origin: .page, contextOccurrenceID: "retrieval:\(victim.page.id):\(victim.lastUsed)",
                evictionEpoch: Int(clamping: currentClock),
                summary: "\(victim.page.path):\(victim.page.startLine)-\(victim.page.endLine) " + String(victim.page.content.prefix(200)),
                pageOutReason: "P-Core resident soft limit")
        }
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

    /// PCore 常驻 Working Set 中的动态页面（由 Cache Controller 严格管理）
    public func residentPages(for sessionID: SessionID) -> [ContextPage] {
        guard let pages = residentPagesBySession[sessionID] else { return [] }
        return Array(pages.values.map(\.page))
    }

    /// PCore 常驻 Working Set 中的衍生页面
    public func residentDerivedPages(for sessionID: SessionID) -> [DerivedContextPage] {
        guard let pages = residentDerivedPagesBySession[sessionID] else { return [] }
        return Array(pages.values)
    }

    /// PCore 常驻详细状态
    public func residentEntries(for sessionID: SessionID) -> [PCoreResidentPage] {
        guard let pages = residentPagesBySession[sessionID] else { return [] }
        return Array(pages.values)
    }

    /// 撤回（undo）操作后对齐 P-E 双核心架构状态与缓存基线
    public func reconcileAfterRevert(sessionID: SessionID, activeSnapshot: PCoreSnapshot) async {
        // 3. P-Core (PCore) 状态重置：撤回导致上一次 Provider 调用的 Cache Record 失效
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

        // Only the authoritative residency-filtered assembly is a resident baseline.
        // No inference has occurred after rewind: never fabricate provider usage/cache hits.
        residentPagesBySession.removeValue(forKey: sessionID)
        lastPromptCacheHitBySession.removeValue(forKey: sessionID)
        clientStructuralHealthBySession.removeValue(forKey: sessionID)
        lastHistorySignaturesBySession.removeValue(forKey: sessionID)
        sessionPCoreBaseTokens[sessionID] = activeSnapshot.metrics.estimatedTokens
        sessionPCoreBaseCount[sessionID] = activeSnapshot.entries.count
        savePersistedTelemetry(sessionID: sessionID, record: SessionCacheRecord(
            cachedTokens: 0, promptTokens: 0, previousPromptTokens: nil, status: "invalidated",
            epoch: sessionEpochs[sessionID] ?? 1, epochReason: "revert_turn", stablePrefixHash: nil,
            missDiagnostics: nil, provider: nil, model: nil, cacheWriteTokens: nil), debt: 0)

        // 5. 调度器经济学债务状态对齐
        await scheduler.reset(sessionID: sessionID)
    }

    /// 统一彻底清理指定 Session 的所有级别状态、指标与缓存记录
    public func clearSessionState(sessionID: SessionID) async {
        residentPagesBySession.removeValue(forKey: sessionID)
        residentDerivedPagesBySession.removeValue(forKey: sessionID)
        sessionPCoreBaseTokens.removeValue(forKey: sessionID)
        sessionPCoreBaseCount.removeValue(forKey: sessionID)
        lastProviderInputTokensBySession.removeValue(forKey: sessionID)
        lastPromptCacheHitBySession.removeValue(forKey: sessionID)
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
        sessionPCoreBaseTokens[sessionID] != nil ||
        sessionPCoreBaseCount[sessionID] != nil ||
        lastProviderInputTokensBySession[sessionID] != nil ||
        lastPromptCacheHitBySession[sessionID] != nil ||
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
    /// 绝对禁止操纵 PCore/RecallCache 缓存，绝对禁止与 PCore/RecallCache 生命周期联动，绝对不影响 Prefix Cache 与 P-Core。
    public func eCoreHeatSnapshot(sessionID: SessionID, topN: Int = 10) async -> ECoreHeatSnapshot? {
        await ecoreStore.heatSnapshot(sessionID: sessionID, topN: topN)
    }

    /// 获取指定会话的 E-Core 观测期指标（只读旁路接口）
    public func eCoreObservationMetrics(sessionID: SessionID) async -> ECoreObservationMetrics {
        await ecoreStore.exportObservationMetrics(sessionID: sessionID)
    }
}
