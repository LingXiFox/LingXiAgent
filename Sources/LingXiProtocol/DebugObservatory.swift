import Foundation

// MARK: - Provenance
//
// Everything in this file exists for one job: let an engineer correlate an E-Core page-out with a
// Provider prefix-cache bust across a several-hundred-turn run. That only works if every number on
// screen says how it was obtained, because several metrics Core already publishes are real but not
// what their names suggest:
//
//   - `observedGranularity` is hardcoded nil in CoreHost and no code path produces a value.
//   - `structuralPrefixStability` is typed Double but can only ever be 0.0 or 1.0.
//   - `volatileTailBytes` is a token estimate multiplied by four, not a byte count.
//
// Rendering those next to genuinely measured values is how a debug panel teaches its reader to
// distrust itself. So each one carries a `DebugMetric`, whose provenance is data rather than UI
// copy, and the Observatory renders the label off the provenance instead of per-panel wording.

/// How a debug metric was obtained.
public enum DebugMetricProvenance: String, Sendable, Equatable, Codable {
    /// Computed by Core from bytes or tokens it actually holds.
    case measured
    /// Reported by the provider upstream; Core only forwards it.
    case coreReported
    /// Computed from other metrics by the formula named in `basis`.
    case derived
    /// An approximation. `basis` says what it approximates and how.
    case estimated
    /// A true value at deliberately low resolution, e.g. a flag typed as a ratio.
    case coarse
    /// Core cannot produce this right now. `basis` says why. Distinct from zero and from absent.
    case unavailable
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = DebugMetricProvenance(rawValue: raw) ?? .unknown
    }
}

/// A metric paired with the terms on which it should be believed.
///
/// `value` is nil exactly when `provenance == .unavailable`. It is never nil-and-also-unmeasured:
/// an unknown has to look unknown, which is the rule the closure contract already applies to the
/// context policy read (`RuntimeFrontend` refuses to show an unread policy as zero).
public struct DebugMetric<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let value: Value?
    public let provenance: DebugMetricProvenance
    /// Why the value has that provenance: the estimation basis, the derivation formula, or the
    /// reason Core cannot produce it.
    public let basis: String?

    public init(
        value: Value?,
        provenance: DebugMetricProvenance,
        basis: String? = nil
    ) {
        self.value = value
        self.provenance = provenance
        self.basis = basis
    }

    public static func measured(_ value: Value) -> DebugMetric<Value> {
        DebugMetric(value: value, provenance: .measured)
    }

    /// A metric Core publishes but cannot actually produce. Carries no value on purpose: the
    /// Observatory must be able to tell "no data" apart from "data that happens to be zero".
    public static func unavailable(because reason: String) -> DebugMetric<Value> {
        DebugMetric(value: nil, provenance: .unavailable, basis: reason)
    }
}

// MARK: - Which stable prefix
//
// Core canonicalises the stable prefix two different ways and they do not agree. The fingerprint
// path folds model identity and reasoning effort into `stablePrefixHash`; the epoch path hashes
// only system prompt plus core tool schema. A byte offset is meaningless without saying which one
// it came from, and correlating against the wrong one is exactly the sort of finding a long run
// would produce confidently and wrongly.

/// Which canonicalisation a prefix measurement was taken over.
public enum DebugCanonicalDefinition: String, Sendable, Equatable, Codable {
    /// `SessionRuntime.computePrefixFingerprint`: system hash, core tool hash and request profile
    /// folded together. Includes model identity and reasoning effort.
    case fingerprintProfile
    /// `SessionRuntime.cacheEpoch(for:)`: system prompt plus core tool schema only. Excludes model,
    /// reasoning and dynamically leased tools.
    case epochCanonical
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = DebugCanonicalDefinition(rawValue: raw) ?? .unknown
    }
}

// MARK: - Telemetry events

/// Categories emitted on the debug telemetry bypass.
///
/// Raw values are dot-namespaced to match the event names already used by `RuntimeTraceEvent.event`
/// (`"provider.call"`, `"ecore.access"`, `"terminal.state"`).
public enum DebugTelemetryCategory: String, Sendable, Equatable, Codable {
    case contextPromptBuilt = "context.prompt_built"
    case contextEviction = "context.eviction"
    case contextFailOpen = "context.fail_open"
    case cacheHit = "cache.hit"
    case cacheMiss = "cache.miss"
    case cacheBust = "cache.bust"
    case cacheEpochAdvanced = "cache.epoch_advanced"
    case eCorePageOut = "ecore.page_out"
    case eCoreExactRestore = "ecore.exact_restore"
    case eCoreSemanticRecall = "ecore.semantic_recall"
    case eCoreRecallFailed = "ecore.recall_failed"
    case eCoreObjectStored = "ecore.object_stored"
    case agentTurnStarted = "agent.turn_started"
    case agentTurnCompleted = "agent.turn_completed"
    case toolStarted = "tool.started"
    case toolCompleted = "tool.completed"
    case providerRequestStarted = "provider.request_started"
    case providerFirstDelta = "provider.first_delta"
    case providerCompleted = "provider.completed"
    case schedulerDecision = "scheduler.decision"
    case recorderFault = "recorder.fault"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = DebugTelemetryCategory(rawValue: raw) ?? .unknown
    }
}

/// One record on the debug bypass.
///
/// Deliberately NOT a `RuntimeTraceEvent`. Two reasons, both load-bearing:
///
/// 1. `TraceEmitter.redactAttributes` treats any attribute key containing the substring "token" as
///    a secret and replaces its value with "[redacted]" — so `promptTokens` and `cacheReadTokens`
///    would be silently destroyed on the way in.
/// 2. `TraceAttributeValue` has no nested case, so a typed panel cannot be expressed there at all.
///
/// This type carries typed panels as fields instead, which keeps the numbers intact and the schema
/// checkable.
public struct DebugTelemetryEvent: Codable, Sendable, Equatable {
    /// Core-assigned monotonic order within this hub instance.
    ///
    /// Events are recorded from several actors and reach the hub out of call order, and their
    /// timestamps can tie; the hub assigns this under its own lock, so it — not `timestamp` — is
    /// what makes "did the page-out precede the cache bust" answerable. Whatever a caller passes
    /// here is overwritten, which is why it is mutable despite everything else in this file being
    /// a `let`.
    public var sequence: UInt64
    public let timestamp: Date
    public let category: DebugTelemetryCategory
    /// The raw category string as recorded, preserved so an older client that decodes a newer
    /// Core's category as `.unknown` can still display what it was.
    public let categoryRaw: String
    public let sessionID: SessionID?
    public let runID: AgentRunID?
    public let turnID: TurnID?
    public let objectID: String?
    public let referenceID: String?
    public let toolCallID: ToolCallID?
    public let eventSchemaVersion: Int

    // Exactly one of these is populated for a given category. Optional typed panels rather than a
    // deep tagged union, so adding a category cannot break decoding for an existing peer.
    public let promptAudit: DebugPrefixByteAudit?
    public let cacheSample: DebugCacheSample?
    public let eCoreEvent: DebugECoreEvent?
    public let eviction: DebugEvictionEntry?
    public let scheduler: DebugSchedulerDecision?

    public init(
        sequence: UInt64,
        timestamp: Date,
        category: DebugTelemetryCategory,
        categoryRaw: String? = nil,
        sessionID: SessionID? = nil,
        runID: AgentRunID? = nil,
        turnID: TurnID? = nil,
        objectID: String? = nil,
        referenceID: String? = nil,
        toolCallID: ToolCallID? = nil,
        eventSchemaVersion: Int = 1,
        promptAudit: DebugPrefixByteAudit? = nil,
        cacheSample: DebugCacheSample? = nil,
        eCoreEvent: DebugECoreEvent? = nil,
        eviction: DebugEvictionEntry? = nil,
        scheduler: DebugSchedulerDecision? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.category = category
        self.categoryRaw = categoryRaw ?? category.rawValue
        self.sessionID = sessionID
        self.runID = runID
        self.turnID = turnID
        self.objectID = objectID
        self.referenceID = referenceID
        self.toolCallID = toolCallID
        self.eventSchemaVersion = eventSchemaVersion
        self.promptAudit = promptAudit
        self.cacheSample = cacheSample
        self.eCoreEvent = eCoreEvent
        self.eviction = eviction
        self.scheduler = scheduler
    }
}

// MARK: - Panels

/// Byte-level diff between this turn's stable prefix and the previous turn's.
///
/// These are byte offsets into the canonical string, not token positions — Core has a conservative
/// token estimator but no tokenizer, and naming a byte offset a "token" would be the exact kind of
/// confident wrongness this whole surface exists to avoid.
public struct DebugPrefixByteAudit: Codable, Sendable, Equatable {
    /// Bytes shared by the previous and current canonical stable prefix. 0 means full rewrite.
    public let stablePrefixCommonBytes: Int
    /// Byte offset of the first difference, i.e. equal to `stablePrefixCommonBytes`.
    /// Kept as its own field because the two are conceptually distinct and readers ask separately.
    public let promptFirstChangedByteOffset: Int
    /// Length of the current canonical stable prefix in bytes.
    public let stablePrefixBytes: Int
    public let previousStablePrefixHash: String?
    public let currentStablePrefixHash: String?
    /// Free-form reason recorded when the epoch advanced or a bust was detected.
    public let bustReason: String?
    /// True when Core attributed the change to a client-side structural mutation
    /// (prefix rewrite or tool reordering) rather than to a legitimate epoch advance.
    public let clientCaused: Bool?
    /// The request profile hash, which Core computes every turn and until now never published
    /// anywhere: it was only ever reachable inside `PrefixFingerprint`.
    public let requestProfileHash: String?
    /// Whether `requestProfileHash` was measured or Core could not supply it this turn.
    public let requestProfileProvenance: DebugMetricProvenance
    /// Which of Core's two canonicalisations these bytes are offsets into. Required.
    public let canonicalDefinition: DebugCanonicalDefinition

    public init(
        stablePrefixCommonBytes: Int = 0,
        promptFirstChangedByteOffset: Int = 0,
        stablePrefixBytes: Int = 0,
        previousStablePrefixHash: String? = nil,
        currentStablePrefixHash: String? = nil,
        bustReason: String? = nil,
        clientCaused: Bool? = nil,
        requestProfileHash: String? = nil,
        requestProfileProvenance: DebugMetricProvenance = .measured,
        canonicalDefinition: DebugCanonicalDefinition = .fingerprintProfile
    ) {
        self.stablePrefixCommonBytes = stablePrefixCommonBytes
        self.promptFirstChangedByteOffset = promptFirstChangedByteOffset
        self.stablePrefixBytes = stablePrefixBytes
        self.previousStablePrefixHash = previousStablePrefixHash
        self.currentStablePrefixHash = currentStablePrefixHash
        self.bustReason = bustReason
        self.clientCaused = clientCaused
        self.requestProfileHash = requestProfileHash
        self.requestProfileProvenance = requestProfileProvenance
        self.canonicalDefinition = canonicalDefinition
    }
}

/// One turn's cache outcome, sampled from state Core already maintains.
///
/// Per-turn scalars only. The expensive aggregates (`eCoreObservationMetrics` reads and decodes
/// the whole E-Core telemetry log plus a per-object metadata scan) stay pull-on-demand.
public struct DebugCacheSample: Codable, Sendable, Equatable {
    public let cacheEpoch: Int?
    public let epochReason: String?
    public let cacheStatus: String?
    public let stablePrefixHash: String?
    /// Human-readable prose Core already generates for cache misses. Not parseable — Core embeds
    /// truncated hashes in it — so it is carried for reading, not for charting.
    public let missDiagnostics: String?
    public let cacheDebt: DebugMetric<Int>
    public let promptTokens: DebugMetric<Int>
    public let previousPromptTokens: DebugMetric<Int>
    public let cacheReadTokens: DebugMetric<Int>
    /// `cacheReadTokens / previousPromptTokens`, only meaningful when both came from the provider.
    public let prefixReuseRatio: DebugMetric<Double>
    public let clientCausedBustRate: DebugMetric<Double>
    public let clientCausedBusts: Int?
    public let comparableRequests: Int?
    public let appendOnlyContextRatio: DebugMetric<Double>
    public let appendOnlyViolations: Int?
    /// Core's own note is that this is an approximation; the provenance carries it.
    public let volatileTailBytes: DebugMetric<Int>
    /// Core's note is that this is only ever 0.0 or 1.0 despite being typed Double.
    public let structuralPrefixStability: DebugMetric<Double>
    /// Core hardcodes this nil and nothing produces a value; surfaced so the run can confirm that
    /// rather than infer it from a missing row.
    public let observedGranularity: DebugMetric<Int>

    public init(
        cacheEpoch: Int? = nil,
        epochReason: String? = nil,
        cacheStatus: String? = nil,
        stablePrefixHash: String? = nil,
        missDiagnostics: String? = nil,
        cacheDebt: DebugMetric<Int> = .unavailable(because: "no scheduler state recorded this turn"),
        promptTokens: DebugMetric<Int> = .unavailable(because: "provider reported no usage"),
        previousPromptTokens: DebugMetric<Int> = .unavailable(because: "provider reported no usage"),
        cacheReadTokens: DebugMetric<Int> = .unavailable(because: "provider reported no usage"),
        prefixReuseRatio: DebugMetric<Double> = .unavailable(because: "needs two provider-reported token counts"),
        clientCausedBustRate: DebugMetric<Double> = .unavailable(because: "no epoch history"),
        clientCausedBusts: Int? = nil,
        comparableRequests: Int? = nil,
        appendOnlyContextRatio: DebugMetric<Double> = .unavailable(because: "no epoch history"),
        appendOnlyViolations: Int? = nil,
        volatileTailBytes: DebugMetric<Int> = .unavailable(because: "no volatile tail recorded"),
        structuralPrefixStability: DebugMetric<Double> = .unavailable(because: "no structural health sampled"),
        observedGranularity: DebugMetric<Int> = .unavailable(
            because: "Core never produces this; provider block granularity is an external fact")
    ) {
        self.cacheEpoch = cacheEpoch
        self.epochReason = epochReason
        self.cacheStatus = cacheStatus
        self.stablePrefixHash = stablePrefixHash
        self.missDiagnostics = missDiagnostics
        self.cacheDebt = cacheDebt
        self.promptTokens = promptTokens
        self.previousPromptTokens = previousPromptTokens
        self.cacheReadTokens = cacheReadTokens
        self.prefixReuseRatio = prefixReuseRatio
        self.clientCausedBustRate = clientCausedBustRate
        self.clientCausedBusts = clientCausedBusts
        self.comparableRequests = comparableRequests
        self.appendOnlyContextRatio = appendOnlyContextRatio
        self.appendOnlyViolations = appendOnlyViolations
        self.volatileTailBytes = volatileTailBytes
        self.structuralPrefixStability = structuralPrefixStability
        self.observedGranularity = observedGranularity
    }
}

/// An E-Core lifecycle transition.
public struct DebugECoreEvent: Codable, Sendable, Equatable {
    public let objectID: String?
    public let referenceID: String?
    public let toolName: String?
    public let tokenCost: Int?
    /// Why this object left P-Core, verbatim from the compaction trigger.
    public let pageOutReason: String?
    /// True when the eviction ran without a live retention scorer. This is a per-session flag in
    /// Core, not a per-object one, so it means "the scorer was off when this was decided".
    public let failOpen: Bool?

    public init(
        objectID: String? = nil,
        referenceID: String? = nil,
        toolName: String? = nil,
        tokenCost: Int? = nil,
        pageOutReason: String? = nil,
        failOpen: Bool? = nil
    ) {
        self.objectID = objectID
        self.referenceID = referenceID
        self.toolName = toolName
        self.tokenCost = tokenCost
        self.pageOutReason = pageOutReason
        self.failOpen = failOpen
    }
}

/// One entry from the compactor's eviction trace.
///
/// `ContextEvictionTraceEntry` carries no timestamp and no record of whether the object actually
/// reached E-Core, so those are supplied here: `observedAt` is stamped by the hub, and
/// `enteredECore` comes from the counters added alongside the page-out call. The field is named
/// `observedAt` and not `evictedAt` because it is the hub's clock at record time, not an eviction
/// time Core ever stored.
public struct DebugEvictionEntry: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let objectKey: String
    public let objectType: String
    public let tokenCost: Int
    public let retentionValue: Double
    public let retentionScore: Double
    public let evictionRank: Int?
    public let evictionReason: String?
    public let enteredECore: Bool
    /// Core exposes this per-session, so it is reported as such rather than per-entry.
    public let scoringActiveAtSessionLevel: Bool

    public init(
        observedAt: Date,
        objectKey: String,
        objectType: String,
        tokenCost: Int,
        retentionValue: Double,
        retentionScore: Double,
        evictionRank: Int? = nil,
        evictionReason: String? = nil,
        enteredECore: Bool = false,
        scoringActiveAtSessionLevel: Bool = true
    ) {
        self.observedAt = observedAt
        self.objectKey = objectKey
        self.objectType = objectType
        self.tokenCost = tokenCost
        self.retentionValue = retentionValue
        self.retentionScore = retentionScore
        self.evictionRank = evictionRank
        self.evictionReason = evictionReason
        self.enteredECore = enteredECore
        self.scoringActiveAtSessionLevel = scoringActiveAtSessionLevel
    }
}

/// The cache-aware scheduler's decision for one step, with its inputs.
///
/// This exists so a long run can test the scheduler's *model* of prefix cost against what actually
/// happened. Two of its inputs are known to be placeholders — `estimatedEvictionTokens` subtracts
/// numbers from two different estimators, and `stablePrefixTokens` is half the budget's low-water
/// mark rather than the real prefix size. They are reported as given; changing them would change
/// agent behaviour, which this whole bypass is not permitted to do.
public struct DebugSchedulerDecision: Codable, Sendable, Equatable {
    public let kind: Kind
    public let reason: String?
    public let currentTokens: Int?
    public let economicThreshold: DebugMetric<Int>
    public let estimatedEvictionTokens: DebugMetric<Int>
    public let stablePrefixTokens: DebugMetric<Int>
    public let horizon: Int?
    public let neededHorizon: Double?
    public let cacheDebt: Int?

    public enum Kind: String, Sendable, Equatable, Codable {
        case skip
        case economicCompact
        case emergencyWindowProtection
        case unknown

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public init(
        kind: Kind,
        reason: String? = nil,
        currentTokens: Int? = nil,
        economicThreshold: DebugMetric<Int> = .unavailable(because: "policy supplied no threshold"),
        estimatedEvictionTokens: DebugMetric<Int> = .unavailable(because: "no budget computed"),
        stablePrefixTokens: DebugMetric<Int> = .unavailable(because: "no budget computed"),
        horizon: Int? = nil,
        neededHorizon: Double? = nil,
        cacheDebt: Int? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.currentTokens = currentTokens
        self.economicThreshold = economicThreshold
        self.estimatedEvictionTokens = estimatedEvictionTokens
        self.stablePrefixTokens = stablePrefixTokens
        self.horizon = horizon
        self.neededHorizon = neededHorizon
        self.cacheDebt = cacheDebt
    }
}

// MARK: - Aggregate read models

/// Live E-Core counters maintained by the debug bypass.
///
/// These do not exist anywhere in Core today: `pageOut`, `restore`, `searchReferences` and `search`
/// emit no events and keep no tallies. The two restore failures are tracked apart because a
/// reference that no longer resolves and a reference whose payload file is gone are different
/// faults, and a page-out/restore endurance test has to tell them apart.
public struct DebugECoreCounters: Codable, Sendable, Equatable {
    public let pageOuts: Int
    public let exactRestores: Int
    public let semanticRecalls: Int
    public let danglingReferenceRestores: Int
    public let payloadMissingRestores: Int
    public let objectsStored: Int

    public init(
        pageOuts: Int = 0,
        exactRestores: Int = 0,
        semanticRecalls: Int = 0,
        danglingReferenceRestores: Int = 0,
        payloadMissingRestores: Int = 0,
        objectsStored: Int = 0
    ) {
        self.pageOuts = pageOuts
        self.exactRestores = exactRestores
        self.semanticRecalls = semanticRecalls
        self.danglingReferenceRestores = danglingReferenceRestores
        self.payloadMissingRestores = payloadMissingRestores
        self.objectsStored = objectsStored
    }
}

/// E-Core census, with the known blind spot stated rather than hidden.
///
/// `ECoreObjectStore.pageOut` writes only `<objectID>.txt` and never a `.meta.json`, while
/// `listObjects` enumerates `*.meta.json`. So `objectCount` and `totalBytes` systematically omit
/// everything P-Core evicted — which is precisely the population an endurance run is measuring.
/// Rather than quietly fix that here (it would move `storageMetrics`, `dropReference`, `purge` and
/// every existing `objectCount` assertion), the panel reports both figures and says which one the
/// census cannot see.
public struct DebugECorePanel: Codable, Sendable, Equatable {
    public let objectCount: Int
    public let totalBytes: Int
    public let referenceCount: Int
    public let pageOutOnlyObjectCount: Int
    public let pageOutOnlyBytes: Int
    /// False while page-out payloads stay out of the metadata index.
    public let pageOutsVisibleViaMetaIndex: Bool
    public let counters: DebugECoreCounters
    public let recentEvictions: [DebugEvictionEntry]
    public let heat: DebugHeatSummary?
    /// Whether Core's heat tracking was on, which gates whether `heat` can exist at all.
    public let heatTrackingEnabled: Bool

    public init(
        objectCount: Int = 0,
        totalBytes: Int = 0,
        referenceCount: Int = 0,
        pageOutOnlyObjectCount: Int = 0,
        pageOutOnlyBytes: Int = 0,
        pageOutsVisibleViaMetaIndex: Bool = false,
        counters: DebugECoreCounters = DebugECoreCounters(),
        recentEvictions: [DebugEvictionEntry] = [],
        heat: DebugHeatSummary? = nil,
        heatTrackingEnabled: Bool = false
    ) {
        self.objectCount = objectCount
        self.totalBytes = totalBytes
        self.referenceCount = referenceCount
        self.pageOutOnlyObjectCount = pageOutOnlyObjectCount
        self.pageOutOnlyBytes = pageOutOnlyBytes
        self.pageOutsVisibleViaMetaIndex = pageOutsVisibleViaMetaIndex
        self.counters = counters
        self.recentEvictions = recentEvictions
        self.heat = heat
        self.heatTrackingEnabled = heatTrackingEnabled
    }
}

/// Pull-only heat distribution. Pulled, never pushed: Core recomputes it in full per call.
public struct DebugHeatSummary: Codable, Sendable, Equatable {
    public let objectCount: Int
    public let hotCount: Int
    public let coldCount: Int
    public let medianHeat: Double
    public let madHeat: Double
    public let p80: Double
    public let p95: Double
    public let topObjects: [DebugHeatObject]

    public init(
        objectCount: Int = 0,
        hotCount: Int = 0,
        coldCount: Int = 0,
        medianHeat: Double = 0,
        madHeat: Double = 0,
        p80: Double = 0,
        p95: Double = 0,
        topObjects: [DebugHeatObject] = []
    ) {
        self.objectCount = objectCount
        self.hotCount = hotCount
        self.coldCount = coldCount
        self.medianHeat = medianHeat
        self.madHeat = madHeat
        self.p80 = p80
        self.p95 = p95
        self.topObjects = topObjects
    }
}

public struct DebugHeatObject: Codable, Sendable, Equatable {
    public let objectID: String
    public let accessCount: Int
    public let recallCount: Int
    public let lastAccessedAt: Date
    public let rawHeatScore: Double
    public let percentile: Double
    public let candidateZone: String

    public init(
        objectID: String,
        accessCount: Int = 0,
        recallCount: Int = 0,
        lastAccessedAt: Date,
        rawHeatScore: Double = 0,
        percentile: Double = 0,
        candidateZone: String = "cold"
    ) {
        self.objectID = objectID
        self.accessCount = accessCount
        self.recallCount = recallCount
        self.lastAccessedAt = lastAccessedAt
        self.rawHeatScore = rawHeatScore
        self.percentile = percentile
        self.candidateZone = candidateZone
    }
}

/// P-Core occupancy. Mirrors `PCoreStateSnapshot`; kept separate so the Observatory can attach
/// provenance without changing a frozen wire type.
public struct DebugPCorePanel: Codable, Sendable, Equatable {
    public let usedTokens: Int
    public let targetTokens: Int
    public let softLimitTokens: Int
    public let hardLimitTokens: Int
    public let stablePrefixBytes: Int?
    public let growingContextTokens: Int?
    public let eCoreIndexTokens: Int?

    public init(
        usedTokens: Int = 0,
        targetTokens: Int = 0,
        softLimitTokens: Int = 0,
        hardLimitTokens: Int = 0,
        stablePrefixBytes: Int? = nil,
        growingContextTokens: Int? = nil,
        eCoreIndexTokens: Int? = nil
    ) {
        self.usedTokens = usedTokens
        self.targetTokens = targetTokens
        self.softLimitTokens = softLimitTokens
        self.hardLimitTokens = hardLimitTokens
        self.stablePrefixBytes = stablePrefixBytes
        self.growingContextTokens = growingContextTokens
        self.eCoreIndexTokens = eCoreIndexTokens
    }
}

/// Everything the Observatory shows for one session, assembled on demand from Core's own state.
///
/// This is a projection over authoritative Core data, never a second store. Each field is nil when
/// Core has nothing to say, so the UI has to render "unknown" rather than defaulting to zero.
public struct RuntimeObservatorySnapshot: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let sessionID: SessionID
    /// The session's revision counter as Core reported it, so a reader can tell a stale panel from
    /// a live one.
    public let revision: UInt64
    public let runID: AgentRunID?
    public let turnID: TurnID?
    public let pCore: DebugPCorePanel?
    public let eCore: DebugECorePanel?
    public let cache: DebugCacheSample?
    public let prefixAudit: DebugPrefixByteAudit?
    public let scheduler: DebugSchedulerDecision?
    /// Branch prediction. Core has produced this every turn and macOS has never displayed it; it
    /// belongs here because it is observability and reads nothing back into the loop.
    public let prediction: PredictionRuntimeSnapshot?

    /// The session's model is deliberately absent: the frontends already carry it in the
    /// authoritative pushed state, and repeating it here would create a second place for it to be
    /// wrong.
    public init(
        generatedAt: Date = .now,
        sessionID: SessionID,
        revision: UInt64 = 0,
        runID: AgentRunID? = nil,
        turnID: TurnID? = nil,
        pCore: DebugPCorePanel? = nil,
        eCore: DebugECorePanel? = nil,
        cache: DebugCacheSample? = nil,
        prefixAudit: DebugPrefixByteAudit? = nil,
        scheduler: DebugSchedulerDecision? = nil,
        prediction: PredictionRuntimeSnapshot? = nil
    ) {
        self.generatedAt = generatedAt
        self.sessionID = sessionID
        self.revision = revision
        self.runID = runID
        self.turnID = turnID
        self.pCore = pCore
        self.eCore = eCore
        self.cache = cache
        self.prefixAudit = prefixAudit
        self.scheduler = scheduler
        self.prediction = prediction
    }
}

// MARK: - Requests and status

/// Hub and recorder state. The only thing readable while debug mode is off.
public struct DebugObservatoryStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let recording: Bool
    public let runName: String?
    public let ringCapacity: Int
    public let eventsBuffered: Int
    /// Events discarded by the bounded ring. Reported rather than swallowed: an Observatory that
    /// drops its own evidence silently is worse than no Observatory.
    public let eventsDropped: Int
    /// Failures to append to the on-disk archive. The recorder never fails a run for these.
    public let archiveWriteFailures: Int
    public let hubSchemaVersion: Int

    public init(
        enabled: Bool = false,
        recording: Bool = false,
        runName: String? = nil,
        ringCapacity: Int = 0,
        eventsBuffered: Int = 0,
        eventsDropped: Int = 0,
        archiveWriteFailures: Int = 0,
        hubSchemaVersion: Int = 1
    ) {
        self.enabled = enabled
        self.recording = recording
        self.runName = runName
        self.ringCapacity = ringCapacity
        self.eventsBuffered = eventsBuffered
        self.eventsDropped = eventsDropped
        self.archiveWriteFailures = archiveWriteFailures
        self.hubSchemaVersion = hubSchemaVersion
    }
}

/// Turns debug mode on or off, and drives the recorder and the archive.
///
/// One command rather than four, so debug state has exactly one writer. Its receipt carries the
/// authoritative post-change status, which is what makes "re-read Core after a successful write"
/// structural instead of a convention every call site has to remember.
public struct UpdateDebugModeRequest: Codable, Sendable, Equatable {
    public enum Action: String, Sendable, Equatable, Codable {
        case setEnabled
        case startRecording
        case stopRecording
        case clear
        case export
        /// A newer peer's action, unrecognized here. Core rejects it outright: the fallback must
        /// not be one of the destructive members, or an unreadable request would delete the archive
        /// it was never asked to touch.
        case unknown

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Action(rawValue: raw) ?? .unknown
        }
    }

    public let action: Action
    public let enabled: Bool?
    public let runName: String?
    /// Where `export` should write. Only honoured for `export`.
    public let destinationPath: String?

    public init(
        action: Action,
        enabled: Bool? = nil,
        runName: String? = nil,
        destinationPath: String? = nil
    ) {
        self.action = action
        self.enabled = enabled
        self.runName = runName
        self.destinationPath = destinationPath
    }
}

public struct GetObservatoryRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    /// How many recent evictions and hot objects to include. Bounded server-side; the client's
    /// preference is a request, never a guarantee.
    public let topN: Int

    public init(sessionID: SessionID, topN: Int = 10) {
        self.sessionID = sessionID
        self.topN = topN
    }
}

public struct GetObservatoryEventsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID?
    /// Resume point: events with `sequence` strictly greater than this are returned.
    public let afterSequence: UInt64?
    public let categories: [String]?
    public let runID: AgentRunID?
    public let turnID: TurnID?
    public let limit: Int

    public init(
        sessionID: SessionID? = nil,
        afterSequence: UInt64? = nil,
        categories: [String]? = nil,
        runID: AgentRunID? = nil,
        turnID: TurnID? = nil,
        limit: Int = 500
    ) {
        self.sessionID = sessionID
        self.afterSequence = afterSequence
        self.categories = categories
        self.runID = runID
        self.turnID = turnID
        self.limit = limit
    }
}

/// A page of telemetry, oldest first.
public struct DebugEventPage: Codable, Sendable, Equatable {
    public let events: [DebugTelemetryEvent]
    /// Highest sequence the hub holds at the time of the read, so a poller can resume without
    /// re-reading what it already has.
    public let latestSequence: UInt64
    /// True when the ring had already discarded events older than what is being asked for. The
    /// Observatory shows this instead of letting a gap look like a quiet period.
    public let truncated: Bool

    public init(
        events: [DebugTelemetryEvent] = [],
        latestSequence: UInt64 = 0,
        truncated: Bool = false
    ) {
        self.events = events
        self.latestSequence = latestSequence
        self.truncated = truncated
    }
}
