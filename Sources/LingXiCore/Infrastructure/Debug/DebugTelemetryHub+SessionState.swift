import Foundation
import LingXiProtocol

/// What the hub believes about one session right now.
///
/// The ring answers "what happened, in order"; this answers "what is true for this session", which
/// is what the Observatory's panels render. Both are bypass state — nothing in an agent decision
/// path reads either.
///
/// `pageOutOnly*` exists because of a real blind spot in Core: `ECoreObjectStore.pageOut` writes
/// only `<objectID>.txt` and never a `.meta.json`, while `listObjects` enumerates `*.meta.json`.
/// So the store's own census cannot see anything P-Core evicted — precisely the population an
/// endurance run is measuring. Tallying it here makes that population knowable without changing a
/// number that existing consumers assert on.
/// Mutable tally state.
///
/// Deliberately not `DebugECoreCounters`: that is the wire DTO and, like every other response type
/// in this product, its fields are `let`. Increments happen on the recording path, so the mutable
/// form stays here and the immutable DTO is assembled once, at read time.
struct DebugECoreCounterState {
    var pageOuts = 0
    var exactRestores = 0
    var semanticRecalls = 0
    var danglingReferenceRestores = 0
    var payloadMissingRestores = 0
    var objectsStored = 0

    func asDTO() -> DebugECoreCounters {
        DebugECoreCounters(pageOuts: pageOuts,
                           exactRestores: exactRestores,
                           semanticRecalls: semanticRecalls,
                           danglingReferenceRestores: danglingReferenceRestores,
                           payloadMissingRestores: payloadMissingRestores,
                           objectsStored: objectsStored)
    }
}

struct DebugSessionState {
    var runID: AgentRunID?
    var turnID: TurnID?
    var cache: DebugCacheSample?
    var prefixAudit: DebugPrefixByteAudit?
    var scheduler: DebugSchedulerDecision?
    /// Stable prefix size in bytes as Core last measured it.
    var stablePrefixBytes: Int?
    var counters = DebugECoreCounterState()
    var pageOutOnlyObjectCount = 0
    var pageOutOnlyBytes = 0
    /// Distinct ids paged out, so re-paging one object does not inflate the census.
    var pageOutObjectIDs: Set<String> = []
}

extension DebugTelemetryHub {

    // MARK: - Correlation

    /// Records which run and turn is current, so events raised by subsystems that know neither can
    /// still be tied to the step that caused them.
    public func beginTurn(sessionID: SessionID, runID: AgentRunID?, turnID: TurnID?) {
        mutateSessionState(sessionID) { state in
            state.runID = runID
            state.turnID = turnID
        }
    }

    public func correlation(sessionID: SessionID) -> (runID: AgentRunID?, turnID: TurnID?) {
        readSessionState(sessionID) { ($0.runID, $0.turnID) } ?? (nil, nil)
    }

    // MARK: - Panel state

    public func recordCache(_ sample: DebugCacheSample, sessionID: SessionID) {
        mutateSessionState(sessionID) { $0.cache = sample }
    }

    public func cacheSample(sessionID: SessionID) -> DebugCacheSample? {
        readSessionState(sessionID) { $0.cache } ?? nil
    }

    /// Stores an audit and the prefix length that came with it, so the two cannot disagree.
    public func recordPrefixAudit(_ audit: DebugPrefixByteAudit, sessionID: SessionID) {
        mutateSessionState(sessionID) { state in
            state.prefixAudit = audit
            state.stablePrefixBytes = audit.stablePrefixBytes
        }
    }

    public func prefixAudit(sessionID: SessionID) -> DebugPrefixByteAudit? {
        readSessionState(sessionID) { $0.prefixAudit } ?? nil
    }

    public func stablePrefixBytes(sessionID: SessionID) -> Int? {
        readSessionState(sessionID) { $0.stablePrefixBytes } ?? nil
    }

    public func recordSchedulerDecision(_ decision: DebugSchedulerDecision, sessionID: SessionID) {
        mutateSessionState(sessionID) { $0.scheduler = decision }
    }

    public func schedulerDecision(sessionID: SessionID) -> DebugSchedulerDecision? {
        readSessionState(sessionID) { $0.scheduler } ?? nil
    }

    // MARK: - E-Core tallies

    public func noteObjectStored(sessionID: SessionID) {
        record(.eCoreObjectStored, sessionID: sessionID)
        mutateSessionState(sessionID) { $0.counters.objectsStored += 1 }
    }

    /// Records a page-out.
    ///
    /// `pageOuts` counts every call while the census counts distinct objects, because a run that
    /// pages the same object out forty times is a finding, and collapsing the two numbers would
    /// hide it.
    public func notePageOut(sessionID: SessionID, objectID: String?, bytes: Int,
                            referenceID: String? = nil, toolName: String? = nil,
                            reason: String? = nil, failOpen: Bool? = nil) {
        record(DebugTelemetryEvent(
            sequence: 0,
            timestamp: .now,
            category: .eCorePageOut,
            sessionID: sessionID,
            objectID: objectID,
            referenceID: referenceID,
            eCoreEvent: DebugECoreEvent(objectID: objectID, referenceID: referenceID,
                                        toolName: toolName, pageOutReason: reason,
                                        failOpen: failOpen)
        ))
        mutateSessionState(sessionID) { state in
            state.counters.pageOuts += 1
            let counted = max(0, bytes)
            guard let objectID else {
                state.pageOutOnlyBytes += counted
                return
            }
            if !state.pageOutObjectIDs.contains(objectID) {
                state.pageOutObjectIDs.insert(objectID)
                state.pageOutOnlyObjectCount += 1
                state.pageOutOnlyBytes += counted
            }
        }
    }

    public func noteExactRestore(sessionID: SessionID, referenceID: String?) {
        record(.eCoreExactRestore, sessionID: sessionID, referenceID: referenceID)
        mutateSessionState(sessionID) { $0.counters.exactRestores += 1 }
    }

    public func noteSemanticRecall(sessionID: SessionID) {
        record(.eCoreSemanticRecall, sessionID: sessionID)
        mutateSessionState(sessionID) { $0.counters.semanticRecalls += 1 }
    }

    /// Records a restore that could not be satisfied.
    ///
    /// `dangling` keeps the two ways this happens apart: a reference that no longer resolves points
    /// at a lifecycle or purge fault, while a reference that resolves but whose payload is gone
    /// points at the store losing data. One combined failure number cannot tell those apart, and a
    /// long run needs it to.
    public func noteRestoreFailure(sessionID: SessionID, referenceID: String?, dangling: Bool) {
        record(DebugTelemetryEvent(
            sequence: 0,
            timestamp: .now,
            category: .eCoreRecallFailed,
            sessionID: sessionID,
            referenceID: referenceID,
            eCoreEvent: DebugECoreEvent(referenceID: referenceID,
                                        pageOutReason: dangling ? "danglingReference" : "payloadMissing")
        ))
        mutateSessionState(sessionID) { state in
            if dangling {
                state.counters.danglingReferenceRestores += 1
            } else {
                state.counters.payloadMissingRestores += 1
            }
        }
    }

    public func eCoreCounters(sessionID: SessionID) -> DebugECoreCounters {
        readSessionState(sessionID) { $0.counters.asDTO() } ?? DebugECoreCounters()
    }

    public func pageOutCensus(sessionID: SessionID) -> (objects: Int, bytes: Int) {
        readSessionState(sessionID) { ($0.pageOutOnlyObjectCount, $0.pageOutOnlyBytes) } ?? (0, 0)
    }

    // MARK: - Lifetime

    /// Drops everything known about a session. Core calls this when it resets one, so a long-lived
    /// process cycling through many sessions cannot accumulate dead state — the exact leak class
    /// this feature exists to detect in others.
    public func forgetSession(_ sessionID: SessionID) {
        removeSessionKey(sessionID)
    }

    /// Sessions the hub is holding, for an Observatory session picker.
    public func knownSessions() -> [SessionID] {
        knownSessionKeys()
    }
}
