public enum RunStatus: String, Sendable, Codable {
    case pending
    case running
    case interrupted
    case completed
    case cancelled
    case failed
    case stepLimitReached
    case deadlineExceeded
    case budgetExceeded

    public var isTerminal: Bool {
        switch self {
        case .pending, .running, .interrupted: false
        default: true
        }
    }
}

public enum TerminalCause: String, Sendable, Codable {
    case none
    case completedWithText
    case completedWithEmptyText
    case cancelledByUser
    case providerFailure
    case streamProtocolViolation
    case stepLimitReached
    case deadlineExceeded
    case budgetExceeded
    case runtimeFailure
    /// The provider cut the reply off at the output-token limit; the reply is incomplete and must
    /// not be reported as a normal completion (LOOP-022).
    case outputTruncated
    /// The provider filtered the response (LOOP-022).
    case contentFiltered
    /// The model refused to answer (LOOP-022).
    case refused
    /// The run was interrupted while a tool batch may have partially executed; recovery never
    /// replays it and leaves verification to the next turn (LOOP-025).
    case executionStateUnknown
    /// A second Run for the same Session was rejected while one was still active (LOOP-021).
    case concurrentRunRejected
}

public struct RunRecord: Sendable {
    public let id: RunID
    public let sessionID: SessionID
    public let turnID: TurnID
    public fileprivate(set) var status: RunStatus
    public fileprivate(set) var cause: TerminalCause
    public fileprivate(set) var detail: String?

    fileprivate enum Phase: Sendable {
        case open
        case reserved
        case closed
    }

    fileprivate var phase: Phase = .open
}

public enum TerminalizationError: Error, Equatable {
    case unknownRun(RunID)
    case durabilityFailed(RunID)
}

public enum RunAdmissionError: Error, Equatable {
    case duplicateRun(RunID)
    case sessionHasActiveRun(session: SessionID, active: RunID)
}

/// One winner per run. The reservation happens before the first suspension point, so concurrent
/// terminalization attempts cannot both pass the guard, and a durability failure leaves the run
/// non-terminal in memory (LOOP-001, LOOP-002, STORE-001).
///
/// Admission also enforces the single-active-Run-per-session rule (D1, LOOP-021): one session has
/// at most one non-terminal run, so two runs can never race on the same history.
public actor RunRegistry {
    private var records: [RunID: RunRecord] = [:]

    public init() {}

    public func create(id: RunID, sessionID: SessionID, turnID: TurnID) throws {
        guard records[id] == nil else { throw RunAdmissionError.duplicateRun(id) }
        if let active = records.values.first(where: { $0.sessionID == sessionID && !$0.status.isTerminal }) {
            throw RunAdmissionError.sessionHasActiveRun(session: sessionID, active: active.id)
        }
        records[id] = RunRecord(id: id, sessionID: sessionID, turnID: turnID, status: .pending, cause: .none)
    }

    public func markRunning(_ id: RunID) throws {
        try mutate(id) { record in
            guard record.phase == .open, !record.status.isTerminal else { return false }
            record.status = .running
            return true
        }
    }

    public func markInterrupted(_ id: RunID) throws {
        try mutate(id) { record in
            guard record.phase == .open else { return false }
            record.status = .interrupted
            return true
        }
    }

    public func record(_ id: RunID) -> RunRecord? {
        records[id]
    }

    public var openRunIDs: [RunID] {
        records.values.filter { !$0.status.isTerminal }.map(\.id)
    }

    public func activeRun(for sessionID: SessionID) -> RunID? {
        records.values.first { $0.sessionID == sessionID && !$0.status.isTerminal }?.id
    }

    /// Drops a run that never made it into the journal. Used when the begin transaction rolled back,
    /// so a later run in the same session is not blocked by a record that no longer exists on disk.
    public func discard(_ id: RunID) {
        records[id] = nil
    }

    /// Returns false when another attempt already owns the terminal transition.
    @discardableResult
    public func terminalize(
        _ id: RunID,
        status: RunStatus,
        cause: TerminalCause,
        detail: String?,
        via log: DurableEventLog
    ) async throws -> Bool {
        guard records[id] != nil else { throw TerminalizationError.unknownRun(id) }
        guard records[id]!.phase == .open, !records[id]!.status.isTerminal else { return false }
        update(id) { $0.phase = .reserved }

        let marker = await log.beginMarker()
        do {
            try await log.append(.runTerminal(id, status, cause))
        } catch {
            try? await log.rollBack(to: marker)
            update(id) { record in
                record.phase = .open
            }
            throw TerminalizationError.durabilityFailed(id)
        }

        update(id) { record in
            record.status = status
            record.cause = cause
            record.detail = detail
            record.phase = .closed
        }
        return true
    }

    /// A run that was started but never terminalized is failed on restart and never re-queued:
    /// replaying side effects is worse than reporting an unknown outcome (LOOP-003).
    @discardableResult
    public func recoverUnfinishedRuns(via log: DurableEventLog) async throws -> [RunID] {
        var recovered: [RunID] = []
        for id in openRunIDs {
            do {
                _ = try await terminalize(id, status: .failed, cause: .runtimeFailure, detail: "recovered after restart", via: log)
                recovered.append(id)
            } catch TerminalizationError.durabilityFailed {
                continue
            }
        }
        return recovered
    }

    /// Journal replay hook: installs a record exactly as the journal says it was. Recovery owns this
    /// path and always builds a fresh registry, never reusing live state.
    func restore(id: RunID, sessionID: SessionID, turnID: TurnID, status: RunStatus, cause: TerminalCause, detail: String?) {
        var record = RunRecord(id: id, sessionID: sessionID, turnID: turnID, status: status, cause: cause, detail: detail)
        record.phase = status.isTerminal ? .closed : .open
        records[id] = record
    }

    private func mutate(_ id: RunID, _ body: (inout RunRecord) -> Bool) throws {
        guard var record = records[id] else { throw TerminalizationError.unknownRun(id) }
        guard body(&record) else { return }
        records[id] = record
    }

    private func update(_ id: RunID, _ body: (inout RunRecord) -> Void) {
        guard var record = records[id] else { return }
        body(&record)
        records[id] = record
    }
}

public actor SessionStore {
    private var history: [SessionID: [ContextEntry]] = [:]

    public init() {}

    public func entries(for sessionID: SessionID) -> [ContextEntry] {
        history[sessionID] ?? []
    }

    /// Only the user input of the request that is currently running is mandatory. Appending a new
    /// current-user entry demotes every earlier one to history, so old user turns participate in the
    /// budget like any other history (CTX-017). Journal replay uses this same rule, which makes the
    /// rebuilt store identical to the live one.
    public func append(_ entry: ContextEntry, to sessionID: SessionID) {
        var entries = history[sessionID] ?? []
        if entry.segment == .currentUser {
            entries = entries.map(Self.demoted)
        }
        entries.append(entry)
        history[sessionID] = entries
    }

    public func sessionIDs() -> [SessionID] {
        Array(history.keys)
    }

    func replace(_ entries: [ContextEntry], for sessionID: SessionID) {
        history[sessionID] = entries
    }

    private static func demoted(_ entry: ContextEntry) -> ContextEntry {
        guard entry.segment == .currentUser else { return entry }
        return ContextEntry(id: entry.id, segment: .history, role: entry.role, payload: entry.payload, unit: entry.unit)
    }
}
