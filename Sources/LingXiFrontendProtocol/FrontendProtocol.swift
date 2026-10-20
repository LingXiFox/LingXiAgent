import Foundation

/// The frontend wire protocol. One JSON object per line, same discipline as the plugin host: requests
/// carry an id, replies echo it, events never do. The TUI speaks only this; it never loads a provider
/// or a plugin.
public enum FrontendMethod: String, Codable, Sendable {
    case hello
    case sessionsList = "sessions.list"
    case sessionHistory = "session.history"
    case sessionNew = "session.new"
    case chatSend = "chat.send"
    case runCancel = "run.cancel"
    case modelsList = "models.list"
    case pluginsList = "plugins.list"
    case pluginEnable = "plugin.enable"
    case pluginDisable = "plugin.disable"
    case shutdown
}

public struct FrontendRequest: Codable, Sendable {
    public var id: Int
    public var method: FrontendMethod
    public var sessionID: String?
    public var model: String?
    public var text: String?
    public var runID: String?
    public var bundleID: String?

    public init(id: Int, method: FrontendMethod) {
        self.id = id
        self.method = method
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let turns: Int

    public init(id: String, title: String, turns: Int) {
        self.id = id
        self.title = title
        self.turns = turns
    }
}

public struct HistoryEntry: Codable, Sendable, Equatable {
    public let role: String
    public let text: String
    /// "message" | "tool" | "toolCall" — the TUI renders them differently.
    public let kind: String

    public init(role: String, text: String, kind: String) {
        self.role = role
        self.text = text
        self.kind = kind
    }
}

public struct PluginSummary: Codable, Sendable, Equatable {
    public let bundleID: String
    public let version: String
    public let enabled: Bool
    public let running: Bool
    public let capabilities: [String]
    public let permissions: [String]

    public init(
        bundleID: String, version: String, enabled: Bool, running: Bool,
        capabilities: [String], permissions: [String]
    ) {
        self.bundleID = bundleID
        self.version = version
        self.enabled = enabled
        self.running = running
        self.capabilities = capabilities
        self.permissions = permissions
    }
}

public struct FrontendReply: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var error: String?
    public var sessionID: String?
    public var runID: String?
    public var models: [String]?
    public var sessions: [SessionSummary]?
    public var history: [HistoryEntry]?
    public var plugins: [PluginSummary]?

    public init(id: Int, ok: Bool, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
    }
}

public struct FrontendEvent: Codable, Sendable {
    public var event: String
    public var runID: String?
    public var sessionID: String?
    /// Streaming text for the current assistant message.
    public var delta: String?
    /// Provider reasoning delta, rendered dimmed when enabled.
    public var reasoning: String?
    public var status: String?
    public var cause: String?
    public var detail: String?
    public var models: [String]?
    public var sessions: [SessionSummary]?
    public var plugins: [PluginSummary]?
    public var message: String?

    public init(
        event: String,
        runID: String? = nil, sessionID: String? = nil, delta: String? = nil,
        reasoning: String? = nil, status: String? = nil, cause: String? = nil,
        detail: String? = nil, models: [String]? = nil, sessions: [SessionSummary]? = nil,
        plugins: [PluginSummary]? = nil, message: String? = nil
    ) {
        self.event = event
        self.runID = runID
        self.sessionID = sessionID
        self.delta = delta
        self.reasoning = reasoning
        self.status = status
        self.cause = cause
        self.detail = detail
        self.models = models
        self.sessions = sessions
        self.plugins = plugins
        self.message = message
    }
}
