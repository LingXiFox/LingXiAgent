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
    }

    private var goals: [SessionID: State] = [:]

    /// Sets the anchor, or clears it when `goal` is nil/blank. Returns the effective goal.
    public func set(_ sessionID: SessionID, goal: String?) -> String? {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            goals[sessionID] = nil
            return nil
        }
        let previous = goals[sessionID]
        goals[sessionID] = State(text: trimmed, since: previous?.since ?? .now, steps: previous?.steps ?? 0)
        return trimmed
    }

    public func goal(_ sessionID: SessionID) -> String? {
        goals[sessionID]?.text
    }

    /// Counts model steps against the live goal so progress is observable, not just intent.
    public func noteStep(_ sessionID: SessionID) {
        guard var state = goals[sessionID] else { return }
        state.steps += 1
        goals[sessionID] = state
    }

    public func progress(_ sessionID: SessionID) -> (text: String, steps: Int)? {
        guard let state = goals[sessionID] else { return nil }
        return (state.text, state.steps)
    }

    public func clear(_ sessionID: SessionID) {
        goals[sessionID] = nil
    }
}
