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

/// One winner per run. The reservation happens before the first suspension point, so concurrent
/// terminalization attempts cannot both pass the guard, and a durability failure leaves the run
/// non-terminal in memory (LOOP-001, LOOP-002, STORE-001).
public actor RunRegistry {
    private var records: [RunID: RunRecord] = [:]

    public init() {}

    public func create(id: RunID, sessionID: SessionID, turnID: TurnID) throws {
        guard records[id] == nil else { throw TerminalizationError.unknownRun(id) }
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

    public func append(_ entry: ContextEntry, to sessionID: SessionID) {
        history[sessionID, default: []].append(entry)
    }

    public func sessionIDs() -> [SessionID] {
        Array(history.keys)
    }
}
