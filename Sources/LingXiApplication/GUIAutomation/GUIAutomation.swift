import Foundation

public enum SubmissionSource: String, Codable, Sendable { case cli, benchmark }

public struct GUIAutomationTask: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public init(id: String = UUID().uuidString, text: String) { self.id = id; self.text = text }
}

public struct GUIAutomationRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case send, batch, cancel, resume, status, trace }
    public let action: Action
    public let tasks: [GUIAutomationTask]
    public let source: SubmissionSource
    /// Explicit debug inspection gate; normal sends always proceed after presentation.
    public let pauseBeforeSend: Bool
    public init(action: Action, tasks: [GUIAutomationTask] = [], source: SubmissionSource = .cli,
                pauseBeforeSend: Bool = false) {
        self.action = action; self.tasks = tasks; self.source = source; self.pauseBeforeSend = pauseBeforeSend
    }
}

public struct ComposerAutomationEvent: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let name: String
    public let taskID: String
    public let source: SubmissionSource
    public let composerRevision: UInt64
    public let timestamp: Date
    public init(sequence: UInt64, name: String, taskID: String, source: SubmissionSource, composerRevision: UInt64) {
        self.sequence = sequence; self.name = name; self.taskID = taskID; self.source = source
        self.composerRevision = composerRevision; self.timestamp = .now
    }
}

public struct GUIAutomationResult: Codable, Sendable, Equatable {
    public let taskID: String
    public let draftRevision: UInt64
    public let presentedRevision: UInt64
    public let sessionID: String
    public let turnID: String
    public let terminal: String?
    public init(taskID: String, draftRevision: UInt64, presentedRevision: UInt64,
                sessionID: String, turnID: String, terminal: String? = nil) {
        self.taskID = taskID; self.draftRevision = draftRevision; self.presentedRevision = presentedRevision
        self.sessionID = sessionID; self.turnID = turnID; self.terminal = terminal
    }
}

public struct GUIAutomationResponse: Codable, Sendable {
    public let accepted: Bool
    public let reason: String?
    public let results: [GUIAutomationResult]
    public let events: [ComposerAutomationEvent]
    public let draftRevision: UInt64?
    public let presentedRevision: UInt64?
    public let pendingTaskID: String?
    public let draftText: String?
    public init(accepted: Bool, reason: String? = nil, results: [GUIAutomationResult] = [],
                events: [ComposerAutomationEvent] = [], draftRevision: UInt64? = nil,
                presentedRevision: UInt64? = nil, pendingTaskID: String? = nil, draftText: String? = nil) {
        self.accepted = accepted; self.reason = reason; self.results = results; self.events = events
        self.draftRevision = draftRevision; self.presentedRevision = presentedRevision
        self.pendingTaskID = pendingTaskID; self.draftText = draftText
    }
}
