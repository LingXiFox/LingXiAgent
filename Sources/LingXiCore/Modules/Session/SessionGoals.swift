import Foundation
import LingXiProtocol

/// Session-scoped Goal Mode state: an anchor the agent keeps driving toward.
///
/// Deliberately volatile — keyed by session id in memory, never persisted, so it cannot
/// leak into the durable Session value type or the SQLite schema. A Core restart clears it.
public actor SessionGoalRegistry {
    public static let shared = SessionGoalRegistry()

    private struct State {
        var text: String
        var since: Date
        var steps: Int
        var paused = false
        var activeSeconds: Double = 0
        var resumedAt: Date?
    }

    private var goals: [SessionID: State] = [:]

    /// Sets the anchor, or clears it when `goal` is nil/blank. Returns the effective goal.
    /// Editing a goal keeps its clock, step count and paused state.
    public func set(_ sessionID: SessionID, goal: String?) -> String? {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            goals[sessionID] = nil
            return nil
        }
        if var existing = goals[sessionID] {
            existing.text = trimmed
            goals[sessionID] = existing
        } else {
            let now = Date()
            goals[sessionID] = State(text: trimmed, since: now, steps: 0, resumedAt: now)
        }
        return trimmed
    }

    /// Pauses or resumes. A paused goal stops being injected into model requests and its
    /// running clock stops; resuming picks both up again.
    public func setPaused(_ sessionID: SessionID, paused: Bool) {
        guard var state = goals[sessionID], state.paused != paused else { return }
        let now = Date()
        if paused {
            state.activeSeconds += state.resumedAt.map { now.timeIntervalSince($0) } ?? 0
            state.resumedAt = nil
        } else {
            state.resumedAt = now
        }
        state.paused = paused
        goals[sessionID] = state
    }

    /// The goal text, paused or not — what a summary or a compaction should name.
    public func goal(_ sessionID: SessionID) -> String? {
        goals[sessionID]?.text
    }

    /// The goal the model should be driven toward right now: nil while paused.
    public func activeGoal(_ sessionID: SessionID) -> String? {
        guard let state = goals[sessionID], !state.paused else { return nil }
        return state.text
    }

    /// Counts model steps against the live goal so progress is observable, not just intent.
    public func noteStep(_ sessionID: SessionID) {
        guard var state = goals[sessionID], !state.paused else { return }
        state.steps += 1
        goals[sessionID] = state
    }

    public func progress(_ sessionID: SessionID) -> (text: String, steps: Int)? {
        guard let state = goals[sessionID] else { return nil }
        return (state.text, state.steps)
    }

    /// The projected form every frontend consumes.
    public func snapshot(_ sessionID: SessionID) -> GoalRuntimeSnapshot? {
        guard let state = goals[sessionID] else { return nil }
        return GoalRuntimeSnapshot(text: state.text, since: state.since, steps: state.steps,
                                   paused: state.paused, activeSeconds: state.activeSeconds,
                                   resumedAt: state.resumedAt)
    }

    public func clear(_ sessionID: SessionID) {
        goals[sessionID] = nil
    }
}
