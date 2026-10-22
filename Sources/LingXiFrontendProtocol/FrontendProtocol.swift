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
    /// Credential management. The secret travels **only** in `auth.set`; every reply reports state,
    /// never the value, so a saved key can never be read back through this protocol.
    case authStatus = "auth.status"
    case authSet = "auth.set"
    case authRemove = "auth.remove"
    case shutdown
}

/// What the Core reports about one declared credential. Deliberately status-only: there is no field
/// that could carry the secret.
public struct CredentialStatus: Codable, Sendable, Equatable {
    public let providerID: String
    public let credentialID: String
    public let label: String
    /// "keychain" when a saved secret is available, "environment" when the explicit environment
    /// source supplies it, "missing" when neither does.
    public let source: String
    public let configured: Bool

    public init(
        providerID: String, credentialID: String, label: String, source: String, configured: Bool
    ) {
        self.providerID = providerID
        self.credentialID = credentialID
        self.label = label
        self.source = source
        self.configured = configured
    }
}

public struct FrontendRequest: Codable, Sendable {
    public var id: Int
    public var method: FrontendMethod
    public var sessionID: String?
    public var model: String?
    public var text: String?
    public var runID: String?
    public var bundleID: String?
    /// Which provider an `auth.*` request is about. Never a secret.
    public var provider: String?
    /// The secret for `auth.set` only. It is written to the Core, stored once, and never returned:
    /// no reply, event, log line or journal entry can carry it back out.
    public var secret: String?

    public init(
        id: Int, method: FrontendMethod, provider: String? = nil, secret: String? = nil
    ) {
        self.id = id
        self.method = method
        self.provider = provider
        self.secret = secret
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

/// One thinking level reported for a model. The TUI only displays these in this version; the id is
/// stable so a later selection can travel back without changing the shape.
public struct ModelThinkingLevel: Codable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A model as reported to the frontend: routing key plus plugin-declared capability metadata.
public struct ModelSummary: Codable, Sendable, Equatable {
    public let id: String
    public let provider: String
    /// Ordered from least to most reasoning effort; empty when the plugin declares nothing.
    public let thinkingLevels: [ModelThinkingLevel]
    public let defaultThinkingLevel: String?

    public init(
        id: String, provider: String, thinkingLevels: [ModelThinkingLevel] = [],
        defaultThinkingLevel: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
    }
}

public struct FrontendReply: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var error: String?
    public var sessionID: String?
    public var runID: String?
    public var models: [String]?
    /// Optional enrichment for `models`; consumers that only understand ids keep using `models`.
    public var modelDetails: [ModelSummary]?
    public var sessions: [SessionSummary]?
    public var history: [HistoryEntry]?
    public var plugins: [PluginSummary]?
    /// Auth state only. There is deliberately no field that could echo a saved secret.
    public var credentials: [CredentialStatus]?

    public init(id: Int, ok: Bool, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
    }
}

/// Token counts for one provider call. Absent is not zero: a provider that reports nothing stays
/// distinguishable from one that reports a zero.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil, cacheReadTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
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
    public var modelDetails: [ModelSummary]?
    public var sessions: [SessionSummary]?
    public var plugins: [PluginSummary]?
    public var message: String?
    /// Tool name for `tool` events; `status` is "started" or "requested".
    public var tool: String?
    /// Token usage for `usage` events.
    public var usage: TokenUsage?

    public init(
        event: String,
        runID: String? = nil, sessionID: String? = nil, delta: String? = nil,
        reasoning: String? = nil, status: String? = nil, cause: String? = nil,
        detail: String? = nil, models: [String]? = nil, modelDetails: [ModelSummary]? = nil,
        sessions: [SessionSummary]? = nil, plugins: [PluginSummary]? = nil, message: String? = nil
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
        self.modelDetails = modelDetails
        self.sessions = sessions
        self.plugins = plugins
        self.message = message
    }
}
