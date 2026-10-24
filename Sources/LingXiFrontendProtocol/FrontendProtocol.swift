import Foundation
import LingXiSettingsProtocol

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
    case pluginSettingsOpen = "plugin.settings.open"
    case pluginSettingsInput = "plugin.settings.input"
    case pluginSettingsResize = "plugin.settings.resize"
    case pluginSettingsSave = "plugin.settings.save"
    case pluginSettingsCancel = "plugin.settings.cancel"
    /// Credential actions requested by a plugin's settings page. The Core verifies that the
    /// session's bundle declares the provider and credential before anything is read or removed.
    case pluginSettingsCredential = "plugin.settings.credential"
    /// Credential management. The secret travels **only** in `auth.set`; every reply reports state,
    /// never the value, so a saved key can never be read back through this protocol.
    case authStatus = "auth.status"
    case authSet = "auth.set"
    case authRemove = "auth.remove"
    /// Sets or clears the temporary thinking selection for one provider. The choices come from the
    /// provider's own declaration; the Core validates the id and never invents a level.
    case providerReasoningSet = "provider.reasoning.set"
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
    public var settingsSessionID: String?
    /// `update` or `remove` for `plugin.settings.credential`. The provider is carried separately and
    /// is never trusted on its own: the Core resolves it against the session's own declaration.
    public var settingsCredentialAction: String?
    /// Explicit user confirmation for a destructive credential action (Keychain removal).
    public var settingsCredentialConfirmed: Bool?
    public var settingsInput: SettingsInput?
    public var viewport: SettingsViewport?
    /// Which provider an `auth.*` request is about. Never a secret.
    public var provider: String?
    /// The secret for `auth.set` only. It is written to the Core, stored once, and never returned:
    /// no reply, event, log line or journal entry can carry it back out.
    public var secret: String?
    /// Temporary thinking level id for `provider.reasoning.set`, validated against the provider's
    /// declaration. `nil` with `clearReasoning` unset is a no-op; clearing uses the flag below so
    /// "absent" and "clear" never mean the same thing on the wire.
    public var reasoningLevel: String?
    /// Explicitly drop the temporary thinking selection and follow the plugin's own settings again.
    public var clearReasoning: Bool?

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

/// One thinking control ladder for one API protocol, as declared by the provider. The frontend picks
/// the profile whose protocol matches the live provider state and never merges two ladders.
public struct ModelThinkingProfile: Codable, Sendable, Equatable {
    public let protocolKind: String
    public let protocolLabel: String?
    /// Display name of the ladder (`effort`); nil for a plain switch.
    public let axisLabel: String?
    public let levels: [ModelThinkingLevel]
    public let defaultLevel: String?
    /// Official limitation or hint, plugin-owned.
    public let note: String?

    public init(
        protocolKind: String, protocolLabel: String? = nil, axisLabel: String? = nil,
        levels: [ModelThinkingLevel], defaultLevel: String? = nil, note: String? = nil
    ) {
        self.protocolKind = protocolKind
        self.protocolLabel = protocolLabel
        self.axisLabel = axisLabel
        self.levels = levels
        self.defaultLevel = defaultLevel
        self.note = note
    }
}

/// A model as reported to the frontend: routing key plus plugin-declared capability metadata.
public struct ModelSummary: Codable, Sendable, Equatable {
    public let id: String
    public let provider: String
    /// Ordered from least to most reasoning effort; empty when the plugin declares nothing.
    public let thinkingLevels: [ModelThinkingLevel]
    public let defaultThinkingLevel: String?
    /// Per-protocol ladders. Empty when the plugin only declares the legacy flat list.
    public let thinkingProfiles: [ModelThinkingProfile]

    public init(
        id: String, provider: String, thinkingLevels: [ModelThinkingLevel] = [],
        defaultThinkingLevel: String? = nil, thinkingProfiles: [ModelThinkingProfile] = []
    ) {
        self.id = id
        self.provider = provider
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
        self.thinkingProfiles = thinkingProfiles
    }
}

/// Live provider state for the frontend's model area. The plugin reports what it would send; the
/// Core only merges the temporary selection in front of it. Values are opaque plugin ids.
public struct ProviderStateSummary: Codable, Sendable, Equatable {
    public let providerID: String
    public let protocolKind: String?
    /// Display name for the protocol, owned by the plugin; the frontend never prettifies an id.
    public let protocolLabel: String?
    public let thinkingLevel: String?
    public let thinkingLabel: String?
    /// `plugin-settings`, `server-default` or `session-override`.
    public let source: String?
    /// True when `thinkingLevel` comes from the temporary selection rather than the plugin.
    public let overridden: Bool?
    /// Display name of the thinking ladder for this protocol (`effort`), when the plugin declared one.
    public let thinkingAxisLabel: String?

    public init(
        providerID: String, protocolKind: String? = nil, protocolLabel: String? = nil,
        thinkingLevel: String? = nil, thinkingLabel: String? = nil, source: String? = nil,
        overridden: Bool? = nil, thinkingAxisLabel: String? = nil
    ) {
        self.providerID = providerID
        self.protocolKind = protocolKind
        self.protocolLabel = protocolLabel
        self.thinkingLevel = thinkingLevel
        self.thinkingLabel = thinkingLabel
        self.source = source
        self.overridden = overridden
        self.thinkingAxisLabel = thinkingAxisLabel
    }
}

/// One run's timing report, in milliseconds. The provider phases come from the plugin that owns the
/// HTTP connection; the Core adds request preparation and the run total; the TUI adds its own
/// render cost. Numbers only — there is no field that could carry prompt or response text.
public struct RunTiming: Codable, Sendable, Equatable {
    /// Frontend request accepted to the provider invocation starting.
    public let corePrepareMs: Int?
    /// Invoke entry to the wire body being built.
    public let prepareMs: Int?
    /// Wire body built to the HTTP request being handed to the transport.
    public let httpSendMs: Int?
    /// Invoke entry to the first response header (upstream first byte).
    public let firstResponseMs: Int?
    /// Invoke entry to the first SSE line.
    public let firstSSEMs: Int?
    /// Invoke entry to the first reasoning delta.
    public let firstReasoningMs: Int?
    /// Invoke entry to the first text delta.
    public let firstTextMs: Int?
    /// Sum of every provider request's total time in this Run. One request is the common case; a
    /// tool loop makes this the sum, which is what the run-level total can be compared with.
    public let providerTotalMs: Int?
    /// How many provider requests the Run made; the single-request report never hid a tool loop.
    public let providerCalls: Int?
    /// The last request's own total, kept so a single call still has its exact number.
    public let providerLastCallMs: Int?
    /// Core-side credential resolution (Keychain/environment) summed over the Run's provider calls.
    public let credentialMs: Int?
    /// Frontend request accepted to the run terminal.
    public let runTotalMs: Int?
    /// TUI-only: total time spent rendering this run's frames.
    public let renderMs: Int?
    /// Kernel phase breakdown, in milliseconds, measured inside the loop. All optional so an older
    /// Core stays readable; a missing value is "not measured", never zero.
    public let assemblyMs: Int?
    public let budgetMs: Int?
    public let contextHookMs: Int?
    public let requestHookMs: Int?
    public let providerWaitMs: Int?
    public let toolMs: Int?
    public let logWriteMs: Int?
    public let terminalCommitMs: Int?
    public let providerCleanupMs: Int?
    /// Measured run total minus every named phase. A large value is a bug signal.
    public let unaccountedMs: Int?
    /// The kernel's own total for the `run` call, so the frontend can also show the time between
    /// the request being accepted and the loop starting (queueing) plus the tiny tail afterwards.
    public let loopTotalMs: Int?
    public let steps: Int?

    public init(
        corePrepareMs: Int? = nil, prepareMs: Int? = nil, httpSendMs: Int? = nil,
        firstResponseMs: Int? = nil, firstSSEMs: Int? = nil, firstReasoningMs: Int? = nil,
        firstTextMs: Int? = nil, providerTotalMs: Int? = nil, providerCalls: Int? = nil,
        providerLastCallMs: Int? = nil, credentialMs: Int? = nil, runTotalMs: Int? = nil,
        renderMs: Int? = nil, assemblyMs: Int? = nil, budgetMs: Int? = nil,
        contextHookMs: Int? = nil, requestHookMs: Int? = nil, providerWaitMs: Int? = nil,
        toolMs: Int? = nil, logWriteMs: Int? = nil, terminalCommitMs: Int? = nil,
        providerCleanupMs: Int? = nil, unaccountedMs: Int? = nil, loopTotalMs: Int? = nil,
        steps: Int? = nil
    ) {
        self.corePrepareMs = corePrepareMs
        self.prepareMs = prepareMs
        self.httpSendMs = httpSendMs
        self.firstResponseMs = firstResponseMs
        self.firstSSEMs = firstSSEMs
        self.firstReasoningMs = firstReasoningMs
        self.firstTextMs = firstTextMs
        self.providerTotalMs = providerTotalMs
        self.providerCalls = providerCalls
        self.providerLastCallMs = providerLastCallMs
        self.credentialMs = credentialMs
        self.runTotalMs = runTotalMs
        self.renderMs = renderMs
        self.assemblyMs = assemblyMs
        self.budgetMs = budgetMs
        self.contextHookMs = contextHookMs
        self.requestHookMs = requestHookMs
        self.providerWaitMs = providerWaitMs
        self.toolMs = toolMs
        self.logWriteMs = logWriteMs
        self.terminalCommitMs = terminalCommitMs
        self.providerCleanupMs = providerCleanupMs
        self.unaccountedMs = unaccountedMs
        self.loopTotalMs = loopTotalMs
        self.steps = steps
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
    public var preferredModel: String?
    public var sessions: [SessionSummary]?
    public var history: [HistoryEntry]?
    public var plugins: [PluginSummary]?
    public var settings: SettingsSnapshot?
    /// Live provider state after a state query or a temporary thinking change.
    public var providerStates: [ProviderStateSummary]?
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
    public var preferredModel: String?
    public var sessions: [SessionSummary]?
    public var plugins: [PluginSummary]?
    public var message: String?
    /// Tool name for `tool` events; `status` is "started" or "requested".
    public var tool: String?
    /// Token usage for `usage` events.
    public var usage: TokenUsage?
    /// Timing report for `timing` events: emitted once per run, just before its terminal.
    public var timing: RunTiming?
    /// Live provider state for `providers.state` events (and piggybacked on `models.changed`).
    public var providerStates: [ProviderStateSummary]?

    public init(
        event: String,
        runID: String? = nil, sessionID: String? = nil, delta: String? = nil,
        reasoning: String? = nil, status: String? = nil, cause: String? = nil,
        detail: String? = nil, models: [String]? = nil, modelDetails: [ModelSummary]? = nil,
        preferredModel: String? = nil, sessions: [SessionSummary]? = nil, plugins: [PluginSummary]? = nil, message: String? = nil
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
        self.preferredModel = preferredModel
        self.sessions = sessions
        self.plugins = plugins
        self.message = message
    }
}
