/// Recovery report: what a fresh process rebuilt from the journal and which runs needed a decision.
public struct RecoveryReport: Sendable {
    public let eventsReplayed: Int
    public let sessionCount: Int
    public let restoredRunCount: Int
    /// Runs THIS recovery had to terminalize; empty when replaying a journal whose runs already
    /// reached a terminal record (a second recovery reports none).
    public let failedRunIDs: [RunID]
    /// Runs that were interrupted while a tool batch may have partially executed. Never replayed;
    /// the next turn must verify side effects (LOOP-025). Derived from the journal, so it is stable
    /// across repeated recoveries.
    public let executionStateUnknownRunIDs: [RunID]
    /// Deterministic history-healing count (missing result records + unknown/not-started batches).
    public let synthesizedResultEntryCount: Int
    /// Torn journal records dropped by `DurableEventLog` when this process opened the journal.
    public let repairedTailRecordCount: Int
}

public struct RecoveredKernel: Sendable {
    public let runs: RunRegistry
    public let store: SessionStore
    public let report: RecoveryReport
}

public enum RecoveryError: Error, Equatable {
    case duplicateRunCreated(RunID)
    case recordWithoutRun(RunID)
    case batchWithoutRun(BatchID)
}

/// Rebuilds the kernel's in-memory state from the append-only journal.
///
/// Policy (Kernel-Design §六, STORE-008/009, LOOP-025):
/// 1. Every event is replayed in order into a brand-new `SessionStore` and `RunRegistry`; no live
///    object is reused, which is what makes this a real "new process" recovery.
/// 2. Only the final journal record may be torn (it is truncated by `DurableEventLog` on open).
/// 3. Batches are reconciled deterministically: settled-but-unrecorded results are restored from
///    the durable outcomes; a started-but-unsettled batch is marked `executionStateUnknown` and
///    gets an explicit error result so the history pairing stays valid.
/// 4. Open runs are failed and never resumed. No tool is executed and no model request is sent.
public enum KernelRecovery {
    private struct BatchState {
        let runID: RunID
        let sessionID: SessionID
        var calls: [ToolCall]
        var outcomes: [ToolOutcome]?
        var consumed: Bool
    }

    public static func recover(log: DurableEventLog) async throws -> RecoveredKernel {
        let events = try await log.events()
        let repairedTailCount = await log.repairedTailRecordCount

        let runs = RunRegistry()
        let store = SessionStore()

        var runInfo: [RunID: (sessionID: SessionID, turnID: TurnID)] = [:]
        var createdOrder: [RunID] = []
        var openRunIDs: Set<RunID> = []
        var batchStates: [BatchID: BatchState] = [:]
        var batchOrder: [BatchID] = []
        var recordedEntryIDs: [SessionID: Set<EntryID>] = [:]

        for event in events {
            switch event {
            case .runCreated(let runID, let sessionID, let turnID):
                guard runInfo[runID] == nil else { throw RecoveryError.duplicateRunCreated(runID) }
                runInfo[runID] = (sessionID, turnID)
                createdOrder.append(runID)
                openRunIDs.insert(runID)
                await runs.restore(
                    id: runID, sessionID: sessionID, turnID: turnID,
                    status: .pending, cause: .none, detail: nil
                )

            case .runStarted(let runID):
                guard let info = runInfo[runID] else { throw RecoveryError.recordWithoutRun(runID) }
                await runs.restore(
                    id: runID, sessionID: info.sessionID, turnID: info.turnID,
                    status: .running, cause: .none, detail: nil
                )

            case .entryRecorded(let runID, let entry):
                guard let info = runInfo[runID] else { throw RecoveryError.recordWithoutRun(runID) }
                await store.append(entry, to: info.sessionID)
                recordedEntryIDs[info.sessionID, default: []].insert(entry.id)

            case .batchStarted(let runID, let batchID, let calls):
                guard let info = runInfo[runID] else { throw RecoveryError.batchWithoutRun(batchID) }
                if batchStates[batchID] == nil { batchOrder.append(batchID) }
                batchStates[batchID] = BatchState(
                    runID: runID, sessionID: info.sessionID, calls: calls, outcomes: nil, consumed: false
                )

            case .batchSettled(let runID, let batchID, let outcomes):
                guard let info = runInfo[runID] else { throw RecoveryError.batchWithoutRun(batchID) }
                var state = batchStates[batchID] ?? BatchState(
                    runID: runID, sessionID: info.sessionID, calls: [], outcomes: nil, consumed: false
                )
                if batchStates[batchID] == nil { batchOrder.append(batchID) }
                state.outcomes = outcomes
                batchStates[batchID] = state

            case .batchConsumed(_, let batchID):
                if var state = batchStates[batchID] {
                    state.consumed = true
                    batchStates[batchID] = state
                }

            case .runTerminal(let runID, let status, let cause):
                guard let info = runInfo[runID] else { throw RecoveryError.recordWithoutRun(runID) }
                openRunIDs.remove(runID)
                await runs.restore(
                    id: runID, sessionID: info.sessionID, turnID: info.turnID,
                    status: status, cause: cause, detail: nil
                )
            }
        }

        var synthesizedResultCount = 0
        var unknownExecutionRunIDs: Set<RunID> = []

        // A recorded call whose batch never started crashed before dispatch: nothing ran, but the
        // call must not dangle in history or the next request would fail protocol validation.
        for sessionID in await store.sessionIDs() {
            var entries = await store.entries(for: sessionID)
            var known = recordedEntryIDs[sessionID] ?? []
            for callEntry in entries where !callEntry.payload.toolCalls.isEmpty {
                guard let unit = callEntry.unit else { continue }
                let batchID = BatchID(unit)
                guard batchStates[batchID] == nil else { continue }
                let resultID = EntryID("result-\(unit)")
                guard !known.contains(resultID) else { continue }
                let entry = synthesizedResult(
                    batchID: batchID,
                    calls: callEntry.payload.toolCalls,
                    content: "batch was not started (crash before dispatch); no side effect occurred; safe to retry"
                )
                insert(entry, after: callEntry.id, into: &entries)
                known.insert(resultID)
                synthesizedResultCount += 1
            }
            await store.replace(entries, for: sessionID)
        }

        for batchID in batchOrder {
            guard let state = batchStates[batchID] else { continue }
            var entries = await store.entries(for: state.sessionID)
            var known = recordedEntryIDs[state.sessionID] ?? []
            let unit = batchID.rawValue
            let callEntryID = EntryID("call-\(unit)")
            let resultID = EntryID("result-\(unit)")

            if let outcomes = state.outcomes {
                // Durable results whose entry record was lost with the crash: restore them instead of
                // re-running anything (recovery matrix "settled but unconsumed").
                if !known.contains(resultID) {
                    let entry = ContextEntry(
                        id: resultID,
                        segment: .history,
                        role: .tool,
                        payload: .toolResult(outcomes: outcomes),
                        unit: unit
                    )
                    insert(entry, after: callEntryID, into: &entries)
                    known.insert(resultID)
                    synthesizedResultCount += 1
                }
            } else {
                // batchStarted without batchSettled: the side effects may have landed. Never replay;
                // leave an explicit unknown-state result for the next turn to verify (LOOP-025).
                unknownExecutionRunIDs.insert(state.runID)
                if !known.contains(resultID) {
                    let ids = state.calls.map(\.callID.rawValue).joined(separator: ", ")
                    let entry = synthesizedResult(
                        batchID: batchID,
                        calls: state.calls,
                        content: "executionStateUnknown: batch may have partially executed before the crash; verificationRequired before retrying (calls: \(ids.isEmpty ? "unknown" : ids))"
                    )
                    insert(entry, after: callEntryID, into: &entries)
                    known.insert(resultID)
                    synthesizedResultCount += 1
                }
            }
            await store.replace(entries, for: state.sessionID)
        }

        var failedRunIDs: [RunID] = []
        for runID in createdOrder where openRunIDs.contains(runID) {
            guard runInfo[runID] != nil else { continue }
            let unknown = unknownExecutionRunIDs.contains(runID)
            let detail = unknown
                ? "recovered after restart; executionStateUnknown: verify side effects before retrying"
                : "recovered after restart"
            let cause: TerminalCause = unknown ? .executionStateUnknown : .runtimeFailure
            let won = try await runs.terminalize(
                runID, status: .failed, cause: cause, detail: detail, via: log
            )
            if won { failedRunIDs.append(runID) }
        }

        let report = RecoveryReport(
            eventsReplayed: events.count,
            sessionCount: await store.sessionIDs().count,
            restoredRunCount: runInfo.count,
            failedRunIDs: failedRunIDs,
            executionStateUnknownRunIDs: createdOrder.filter { unknownExecutionRunIDs.contains($0) },
            synthesizedResultEntryCount: synthesizedResultCount,
            repairedTailRecordCount: repairedTailCount
        )
        return RecoveredKernel(runs: runs, store: store, report: report)
    }

    private static func synthesizedResult(batchID: BatchID, calls: [ToolCall], content: String) -> ContextEntry {
        let outcomes = calls.map {
            ToolOutcome(callID: $0.callID, content: content, isError: true, effect: .unknown)
        }
        return ContextEntry(
            id: EntryID("result-\(batchID.rawValue)"),
            segment: .history,
            role: .tool,
            payload: .toolResult(outcomes: outcomes),
            unit: batchID.rawValue
        )
    }

    private static func insert(_ entry: ContextEntry, after callEntryID: EntryID, into entries: inout [ContextEntry]) {
        if let index = entries.firstIndex(where: { $0.id == callEntryID }) {
            entries.insert(entry, at: index + 1)
        } else {
            entries.append(entry)
        }
    }
}
