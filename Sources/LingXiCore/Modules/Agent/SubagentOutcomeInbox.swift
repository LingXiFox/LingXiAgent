import Foundation
import LingXiProtocol

/// Holds subagent outcomes that reached a terminal state while no originating turn was
/// still waiting on them. Volatile by design: the durable copy lives in the child
/// session's persisted transcript and terminal AgentRun row.
public actor SubagentOutcomeInbox {
    public static let shared = SubagentOutcomeInbox()

    private static let maxEntriesPerSession = 8
    private var pending: [SessionID: [String]] = [:]

    public init() {}

    public func record(sessionID: SessionID, text: String) {
        var entries = pending[sessionID] ?? []
        entries.append(text)
        if entries.count > Self.maxEntriesPerSession {
            entries.removeFirst(entries.count - Self.maxEntriesPerSession)
        }
        pending[sessionID] = entries
    }

    /// Consumed on delivery so a result is projected into model context exactly once.
    public func drain(_ sessionID: SessionID) -> [String] {
        pending.removeValue(forKey: sessionID) ?? []
    }

    public func peek(_ sessionID: SessionID) -> [String] {
        pending[sessionID] ?? []
    }
}
