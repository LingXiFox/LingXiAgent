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


/// One reasoning-effort level a model accepts. `id` is stable and is what a future selection is sent
/// back as; `label` is display text owned by the plugin.
public struct ProviderThinkingLevel: Codable, Sendable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One model offered by a provider, with optional capability metadata. The model id remains the
/// router key; everything else is display metadata and never changes routing.
public struct ProviderModel: Codable, Sendable, Equatable {
    public let id: String
    /// Ordered from least to most reasoning effort. `nil` means the plugin does not declare levels.
    public let thinkingLevels: [ProviderThinkingLevel]?
    public let defaultThinkingLevel: String?

    public init(
        id: String, thinkingLevels: [ProviderThinkingLevel]? = nil, defaultThinkingLevel: String? = nil
    ) {
        self.id = id
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
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

    public var description: String {
        switch self {
        case .emptyModel: "model id must not be empty"
        case .duplicateModel(let model): "duplicate model id: \(model)"
        case .modelDetailsMismatch: "modelDetails must list exactly the same ids, in the same order, as models"
        case .emptyThinkingLevel(let model): "model \(model) declares an empty thinking level id or label"
        case .duplicateThinkingLevel(let model, let level): "model \(model) declares thinking level \(level) twice"
        case .defaultThinkingLevelWithoutLevels(let model): "model \(model) declares a default thinking level without levels"
        case .unknownDefaultThinkingLevel(let model, let level): "model \(model) default thinking level \(level) is not declared"
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

    public init(
        id: String, models: [String], supportsParallelToolCalls: Bool, toolResultPlacement: String,
        credentials: [CredentialRequirement]? = nil, modelDetails: [ProviderModel]? = nil
    ) {
        self.id = id
        self.models = models
        self.modelDetails = modelDetails
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.toolResultPlacement = toolResultPlacement
        self.credentials = credentials
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
            guard let levels = model.thinkingLevels else {
                if model.defaultThinkingLevel != nil {
                    throw ProviderDeclarationError.defaultThinkingLevelWithoutLevels(model: model.id)
                }
                continue
            }
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

    public init(
        model: String, instructions: String?, input: [ProviderWireItem],
        tools: [ProviderWireTool], maxOutputTokens: Int?, credential: String?,
        executionID: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.credential = credential
        self.executionID = executionID
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

    public init(
        type: String, text: String? = nil, callID: String? = nil, name: String? = nil,
        arguments: String? = nil, stopReason: String? = nil, failureKind: String? = nil,
        message: String? = nil, requestID: String? = nil, usage: ProviderWireUsage? = nil
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
