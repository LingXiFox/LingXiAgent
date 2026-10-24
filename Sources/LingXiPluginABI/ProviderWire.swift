import Foundation

/// A credential a plugin needs before it can talk to its upstream. The plugin only *describes* the
/// need; the Core owns storage, consent and delivery. Nothing here names a vendor-specific store:
/// the Core maps every requirement to one Keychain item.
public struct CredentialRequirement: Codable, Sendable, Equatable {
    /// Scoped to the declaring provider, e.g. `apiKey`. The Core composes the durable key from the
    /// provider id and this id, so two providers can both use `apiKey` without colliding.
    public let id: String
    /// Human label the frontend shows while asking for the secret.
    public let label: String
    /// The explicit development/automation fallback: when the Core runs in environment source mode,
    /// this suggests a variable name. Only the operator mapping authorizes a Core environment read.
    public let envVariable: String?
    /// Optional documentation link shown by the frontend.
    public let helpURL: String?

    public init(id: String, label: String, envVariable: String?, helpURL: String?) {
        self.id = id
        self.label = label
        self.envVariable = envVariable
        self.helpURL = helpURL
    }
}


/// One reasoning-effort level a model accepts. `id` is stable and is what a selection is sent back
/// as; `label` is display text owned by the plugin.
public struct ProviderThinkingLevel: Codable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One thinking control ladder for one API protocol. A provider may declare different ladders per
/// model and protocol (Chat Completions exposes a switch; Responses exposes an effort ladder), and
/// the frontend never merges them or invents a level. `axisLabel` names the ladder for display
/// (`effort`), `note` carries an official limitation the plugin wants shown, and every id stays
/// opaque to the Core.
public struct ProviderThinkingProfile: Codable, Sendable, Equatable {
    public let protocolKind: String
    public let protocolLabel: String?
    /// Display name of the ladder, e.g. `effort`. `nil` means the levels are plain modes.
    public let axisLabel: String?
    public let levels: [ProviderThinkingLevel]
    public let defaultLevel: String?
    /// Optional official limitation/hint, e.g. "current tiers are equivalent upstream".
    public let note: String?

    public init(
        protocolKind: String, protocolLabel: String? = nil, axisLabel: String? = nil,
        levels: [ProviderThinkingLevel], defaultLevel: String? = nil, note: String? = nil
    ) {
        self.protocolKind = protocolKind
        self.protocolLabel = protocolLabel
        self.axisLabel = axisLabel
        self.levels = levels
        self.defaultLevel = defaultLevel
        self.note = note
    }
}

/// A provider may expose a read-only state capability so the Core can report what is actually in
/// effect (protocol family, thinking level) without knowing anything vendor-specific. The plugin
/// answers an invoke with `ProviderState`; the capability string lives in its own namespace, so the
/// C ABI table is untouched.
public struct ProviderStateDeclaration: Codable, Sendable, Equatable {
    public let capability: String

    public init(capability: String) {
        self.capability = capability
    }
}

/// What a provider reports about the request it would send next. Values are the plugin's own ids;
/// the Core treats them as opaque display data and never interprets a vendor vocabulary.
public struct ProviderState: Codable, Sendable, Equatable {
    /// Protocol family the plugin currently speaks, e.g. `chatCompletions` / `responses`.
    public let protocolKind: String?
    /// Display name for `protocolKind`, owned by the plugin (e.g. "Chat Completions"). The Core and
    /// the frontend never prettify a vendor vocabulary on their own.
    public let protocolLabel: String?
    /// The thinking level id the plugin's saved configuration selects, when one is selected.
    public let thinkingLevel: String?
    /// Display label for `thinkingLevel`.
    public let thinkingLabel: String?
    /// Where the state comes from: `plugin-settings` or `server-default`.
    public let source: String?
    /// Optional short human hint (for example "服务端默认 effort"). Never request content.
    public let detail: String?

    public init(
        protocolKind: String? = nil, protocolLabel: String? = nil, thinkingLevel: String? = nil,
        thinkingLabel: String? = nil, source: String? = nil, detail: String? = nil
    ) {
        self.protocolKind = protocolKind
        self.protocolLabel = protocolLabel
        self.thinkingLevel = thinkingLevel
        self.thinkingLabel = thinkingLabel
        self.source = source
        self.detail = detail
    }
}

/// Request-phase timings reported by a provider. Every value is milliseconds measured from the
/// plugin's invoke entry (`totalMs` excepted). Deliberately numbers only: no request text, headers
/// or credentials can ride along.
public struct ProviderTiming: Codable, Sendable, Equatable {
    /// Invoke entry to the wire body being built.
    public let prepareMs: Int?
    /// Wire body built to the HTTP request being handed to the transport.
    public let sendMs: Int?
    /// Invoke entry to the first response header.
    public let firstResponseMs: Int?
    /// Invoke entry to the first SSE line.
    public let firstSSEMs: Int?
    /// Invoke entry to the first reasoning delta.
    public let firstReasoningMs: Int?
    /// Invoke entry to the first text delta.
    public let firstTextMs: Int?
    /// Invoke entry to the provider terminal event.
    public let terminalMs: Int?
    /// Invoke entry to the timing report itself.
    public let totalMs: Int?

    public init(
        prepareMs: Int? = nil, sendMs: Int? = nil, firstResponseMs: Int? = nil,
        firstSSEMs: Int? = nil, firstReasoningMs: Int? = nil, firstTextMs: Int? = nil,
        terminalMs: Int? = nil, totalMs: Int? = nil
    ) {
        self.prepareMs = prepareMs
        self.sendMs = sendMs
        self.firstResponseMs = firstResponseMs
        self.firstSSEMs = firstSSEMs
        self.firstReasoningMs = firstReasoningMs
        self.firstTextMs = firstTextMs
        self.terminalMs = terminalMs
        self.totalMs = totalMs
    }
}

/// One model offered by a provider, with optional capability metadata. The model id remains the
/// router key; everything else is display metadata and never changes routing.
public struct ProviderModel: Codable, Sendable, Equatable {
    public let id: String
    /// Legacy flat level list for plugins that declare one ladder for every protocol. New plugins
    /// declare `thinkingProfiles` instead; the Core keeps both so an older plugin stays usable.
    public let thinkingLevels: [ProviderThinkingLevel]?
    public let defaultThinkingLevel: String?
    /// Per-protocol thinking ladders, validated by the loader. When present the frontend shows the
    /// ladder that matches the live provider state instead of the flat list.
    public let thinkingProfiles: [ProviderThinkingProfile]?

    public init(
        id: String, thinkingLevels: [ProviderThinkingLevel]? = nil, defaultThinkingLevel: String? = nil,
        thinkingProfiles: [ProviderThinkingProfile]? = nil
    ) {
        self.id = id
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
        self.thinkingProfiles = thinkingProfiles
    }
}

public enum ProviderDeclarationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyModel
    case duplicateModel(String)
    case modelDetailsMismatch
    case emptyThinkingLevel(model: String)
    case duplicateThinkingLevel(model: String, level: String)
    case defaultThinkingLevelWithoutLevels(model: String)
    case unknownDefaultThinkingLevel(model: String, level: String)
    case emptyThinkingProfile(model: String)
    case duplicateThinkingProtocol(model: String, protocol: String)
    case emptyThinkingProfileLevels(model: String, protocol: String)
    case unknownProfileDefaultLevel(model: String, protocol: String, level: String)

    public var description: String {
        switch self {
        case .emptyModel: "model id must not be empty"
        case .duplicateModel(let model): "duplicate model id: \(model)"
        case .modelDetailsMismatch: "modelDetails must list exactly the same ids, in the same order, as models"
        case .emptyThinkingLevel(let model): "model \(model) declares an empty thinking level id or label"
        case .duplicateThinkingLevel(let model, let level): "model \(model) declares thinking level \(level) twice"
        case .defaultThinkingLevelWithoutLevels(let model): "model \(model) declares a default thinking level without levels"
        case .unknownDefaultThinkingLevel(let model, let level): "model \(model) default thinking level \(level) is not declared"
        case .emptyThinkingProfile(let model): "model \(model) declares an empty thinking profile"
        case .duplicateThinkingProtocol(let model, let protocolKind):
            "model \(model) declares thinking profile for \(protocolKind) twice"
        case .emptyThinkingProfileLevels(let model, let protocolKind):
            "model \(model) thinking profile \(protocolKind) has no levels"
        case .unknownProfileDefaultLevel(let model, let protocolKind, let level):
            "model \(model) thinking profile \(protocolKind) default level \(level) is not declared"
        }
    }
}

/// A provider capability as declared by a plugin and reported by the host. No defaults: the models a
/// plugin offers and the request shape it accepts are explicit, not assumed.
public struct ProviderIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let models: [String]
    /// Optional per-model metadata. When present it must list exactly the same ids as `models`, in
    /// the same order; the loader rejects a declaration that drifts instead of guessing which side
    /// is authoritative.
    public let modelDetails: [ProviderModel]?
    public let supportsParallelToolCalls: Bool
    public let toolResultPlacement: String
    /// What the provider needs before it can reach its upstream. `nil` means "declares nothing",
    /// which is the safe direction: a plugin that needs a secret but forgets to declare it gets no
    /// secret and fails loudly with `unauthorized`, instead of silently inheriting one.
    public let credentials: [CredentialRequirement]?
    /// Optional read-only state capability. When absent the frontend simply has no live state to
    /// show for this provider; the host never invents one.
    public let state: ProviderStateDeclaration?

    public init(
        id: String, models: [String], supportsParallelToolCalls: Bool, toolResultPlacement: String,
        credentials: [CredentialRequirement]? = nil, modelDetails: [ProviderModel]? = nil,
        state: ProviderStateDeclaration? = nil
    ) {
        self.id = id
        self.models = models
        self.modelDetails = modelDetails
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.toolResultPlacement = toolResultPlacement
        self.credentials = credentials
        self.state = state
    }
}

public extension ProviderIdentity {
    /// Rejects ambiguous declarations: duplicate model ids, metadata that disagrees with `models`,
    /// duplicate or empty thinking levels, and a default level that was never declared.
    func validate() throws {
        var seenModels = Set<String>()
        for model in models {
            guard !model.isEmpty else { throw ProviderDeclarationError.emptyModel }
            guard seenModels.insert(model).inserted else {
                throw ProviderDeclarationError.duplicateModel(model)
            }
        }
        guard let modelDetails else { return }
        guard modelDetails.map(\.id) == models else {
            throw ProviderDeclarationError.modelDetailsMismatch
        }
        for model in modelDetails {
            if let levels = model.thinkingLevels {
                var seenLevels = Set<String>()
                for level in levels {
                    guard !level.id.isEmpty, !level.label.isEmpty else {
                        throw ProviderDeclarationError.emptyThinkingLevel(model: model.id)
                    }
                    guard seenLevels.insert(level.id).inserted else {
                        throw ProviderDeclarationError.duplicateThinkingLevel(model: model.id, level: level.id)
                    }
                }
                if let fallback = model.defaultThinkingLevel, !seenLevels.contains(fallback) {
                    throw ProviderDeclarationError.unknownDefaultThinkingLevel(model: model.id, level: fallback)
                }
            } else if model.defaultThinkingLevel != nil {
                throw ProviderDeclarationError.defaultThinkingLevelWithoutLevels(model: model.id)
            }

            var seenProfiles = Set<String>()
            for profile in model.thinkingProfiles ?? [] {
                guard !profile.protocolKind.isEmpty else {
                    throw ProviderDeclarationError.emptyThinkingProfile(model: model.id)
                }
                guard seenProfiles.insert(profile.protocolKind).inserted else {
                    throw ProviderDeclarationError.duplicateThinkingProtocol(
                        model: model.id, protocol: profile.protocolKind
                    )
                }
                guard !profile.levels.isEmpty else {
                    throw ProviderDeclarationError.emptyThinkingProfileLevels(
                        model: model.id, protocol: profile.protocolKind
                    )
                }
                var seenProfileLevels = Set<String>()
                for level in profile.levels {
                    guard !level.id.isEmpty, !level.label.isEmpty else {
                        throw ProviderDeclarationError.emptyThinkingLevel(model: model.id)
                    }
                    guard seenProfileLevels.insert(level.id).inserted else {
                        throw ProviderDeclarationError.duplicateThinkingLevel(model: model.id, level: level.id)
                    }
                }
                if let fallback = profile.defaultLevel, !seenProfileLevels.contains(fallback) {
                    throw ProviderDeclarationError.unknownProfileDefaultLevel(
                        model: model.id, protocol: profile.protocolKind, level: fallback
                    )
                }
            }
        }
    }
}

/// One item of provider input. `role` covers message items; `callID`/`name`/`arguments` cover the
/// function-call pair the loop produces, so a tool round trip survives the boundary unchanged.
public struct ProviderWireItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case message
        case functionCall = "function_call"
        case functionCallOutput = "function_call_output"
    }

    public let kind: Kind
    public let role: String?
    public let text: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let output: String?

    public init(
        kind: Kind, role: String? = nil, text: String? = nil,
        callID: String? = nil, name: String? = nil, arguments: String? = nil, output: String? = nil
    ) {
        self.kind = kind
        self.role = role
        self.text = text
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.output = output
    }
}

public struct ProviderWireTool: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    /// JSON Schema as a string; the kernel never re-encodes or interprets it.
    public let parametersJSON: String

    public init(name: String, description: String?, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// One structured reasoning item returned by a provider. The identifier, status, and text are
/// preserved so a Responses continuation can replay the same item shape instead of a synthetic
/// assistant message. Chat Completions uses the text; Responses uses the whole item.
public struct ProviderReasoningItem: Codable, Sendable, Equatable {
    public let id: String?
    public let text: String
    public let status: String?

    public init(id: String? = nil, text: String, status: String? = nil) {
        self.id = id
        self.text = text
        self.status = status
    }
}

/// Reasoning produced by one assistant turn and the function calls that turn issued. Turns are
/// kept in order so the Responses encoder can place each reasoning item before its function call.
public struct ProviderReasoningTurn: Codable, Sendable, Equatable {
    public let callIDs: [String]
    public let items: [ProviderReasoningItem]

    public init(callIDs: [String], items: [ProviderReasoningItem]) {
        self.callIDs = callIDs
        self.items = items
    }
}

public struct ProviderWireRequest: Codable, Sendable, Equatable {
    public let model: String
    public let instructions: String?
    public let input: [ProviderWireItem]
    public let tools: [ProviderWireTool]
    public let maxOutputTokens: Int?
    /// Supplied per invocation by the Core from its own environment. The host environment is never
    /// widened, and the value is never logged.
    public let credential: String?
    /// Kernel execution (Run) this request belongs to. Lets a provider snapshot settings once per
    /// Run, so a mid-Run settings save cannot change protocol or thinking parameters halfway.
    public let executionID: String?
    /// Reasoning from the previous assistant turn of the same execution. It is kept only in memory
    /// for a tool loop; it is never written to the session journal. Providers that do not accept
    /// reasoning history ignore it.
    public let previousReasoning: String?
    /// Structured per-turn reasoning history. New providers use this; `previousReasoning` stays
    /// for older plugin binaries and Chat-only consumers that understand a single string.
    public let previousReasoningTurns: [ProviderReasoningTurn]?
    /// Temporary, frontend-owned thinking selection for this request. It is one of the model's
    /// declared thinking level ids and takes precedence over the plugin's saved configuration for
    /// this request only; `nil` means "use the plugin's own settings". The plugin owns the mapping
    /// from a level id to its wire parameters.
    public let reasoningLevel: String?

    public init(
        model: String, instructions: String?, input: [ProviderWireItem],
        tools: [ProviderWireTool], maxOutputTokens: Int?, credential: String?,
        executionID: String? = nil, previousReasoning: String? = nil,
        previousReasoningTurns: [ProviderReasoningTurn]? = nil, reasoningLevel: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.credential = credential
        self.executionID = executionID
        self.previousReasoning = previousReasoning
        self.previousReasoningTurns = previousReasoningTurns
        self.reasoningLevel = reasoningLevel
    }
}

public struct ProviderWireUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    public init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Normalized streaming event. The plugin translates its wire format into this; the runtime maps it
/// to the kernel's `ModelEvent`. Unknown types are decoded as `unknown`, never thrown away silently.
public struct ProviderWireEvent: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let stopReason: String?
    public let failureKind: String?
    public let message: String?
    public let requestID: String?
    public let usage: ProviderWireUsage?
    /// Structured reasoning item metadata. `reasoningDelta` carries `itemID`; `reasoningItem`
    /// carries the final text and status.
    public let itemID: String?
    public let status: String?
    /// Phase timings, sent once as a `timing` event just before the terminal event. Numbers only.
    public let timing: ProviderTiming?

    public init(
        type: String, text: String? = nil, callID: String? = nil, name: String? = nil,
        arguments: String? = nil, stopReason: String? = nil, failureKind: String? = nil,
        message: String? = nil, requestID: String? = nil, usage: ProviderWireUsage? = nil,
        itemID: String? = nil, status: String? = nil, timing: ProviderTiming? = nil
    ) {
        self.type = type
        self.text = text
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.stopReason = stopReason
        self.failureKind = failureKind
        self.message = message
        self.requestID = requestID
        self.usage = usage
        self.itemID = itemID
        self.status = status
        self.timing = timing
    }
}

/// The envelope a plugin emits on the host's `emit` channel. `requestID` routes the event to the
/// invoke that is still in flight.
public struct ProviderWireEnvelope: Codable, Sendable {
    public let requestID: String
    public let event: ProviderWireEvent

    public init(requestID: String, event: ProviderWireEvent) {
        self.requestID = requestID
        self.event = event
    }
}
