import Foundation
import LingXiPluginABI

/// The protocol family the plugin speaks for a request. The two families share the normalized
/// event vocabulary but not the wire format, so the choice lives in settings, never in a global.
enum MiMoProtocolKind: String, Codable, Sendable, CaseIterable {
    case chatCompletions
    case responses
}

/// Whether thinking is left to the server, explicitly enabled, or explicitly disabled.
enum MiMoThinkingMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case enabled
    case disabled

    /// Display label owned by the plugin. The same text is declared on the model's thinking level,
    /// so the state capability and the settings page never drift apart.
    var label: String {
        switch self {
        case .default: "服务端默认"
        case .enabled: "开启思考"
        case .disabled: "关闭思考"
        }
    }

    var shortLabel: String {
        switch self {
        case .default: "服务端默认"
        case .enabled: "开启"
        case .disabled: "关闭"
        }
    }
}

/// Reasoning efforts accepted by the settings layer. The upstream vocabulary is wider than the
/// two values MiMo actually documents; aliases are folded in `wireValue`.
enum MiMoReasoningEffort: String, Codable, Sendable, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    /// minimal is the provider's cheapest non-none tier; xhigh/max/ultra are all "very high".
    var wireValue: String {
        switch self {
        case .minimal: "low"
        case .xhigh, .max, .ultra: "high"
        case .none, .low, .medium, .high: rawValue
        }
    }
}

enum MiMoConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    case notAnObject
    case unknownProtocolKind(String)
    case unknownModel(String)
    case unknownThinkingMode(String)
    case unknownReasoningEffort(String)
    case reasoningEffortRequiresResponses
    case invalidTestEndpoint(String)

    var description: String {
        switch self {
        case .notAnObject:
            "MiMo settings must be a JSON object"
        case .unknownProtocolKind(let value):
            "unsupported MiMo protocolKind: \(value)"
        case .unknownModel(let value):
            "unsupported MiMo model: \(value)"
        case .unknownThinkingMode(let value):
            "unsupported MiMo thinkingMode: \(value)"
        case .unknownReasoningEffort(let value):
            "unsupported MiMo reasoningEffort: \(value)"
        case .reasoningEffortRequiresResponses:
            "reasoningEffort is only valid when protocolKind is responses"
        case .invalidTestEndpoint(let value):
            "test.endpoint must be a loopback HTTP URL: \(value)"
        }
    }
}

/// Immutable-by-convention settings snapshot. The Core owns persistence; the plugin only validates
/// and applies the JSON object it receives.
struct MiMoConfig: Equatable, Sendable, Codable {
    static let defaultModel = MiMoWire.models[0]

    var protocolKind: MiMoProtocolKind
    var model: String
    var thinkingMode: MiMoThinkingMode
    var reasoningEffort: String?

    init(
        protocolKind: MiMoProtocolKind = .chatCompletions,
        model: String = MiMoConfig.defaultModel,
        thinkingMode: MiMoThinkingMode = .default,
        reasoningEffort: String? = nil
    ) {
        self.protocolKind = protocolKind
        self.model = model
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
    }

    init(json: JSONValue) throws {
        guard let object = json.object else { throw MiMoConfigError.notAnObject }
        var config = MiMoConfig()

        if let value = object["protocolKind"] {
            guard let raw = value.string, let kind = MiMoProtocolKind(rawValue: raw) else {
                throw MiMoConfigError.unknownProtocolKind(value.string ?? "\(value)")
            }
            config.protocolKind = kind
        }
        if let value = object["model"] {
            guard let model = value.string else { throw MiMoConfigError.unknownModel("\(value)") }
            config.model = model
        }
        if let value = object["thinkingMode"] {
            guard let raw = value.string, let mode = MiMoThinkingMode(rawValue: raw) else {
                throw MiMoConfigError.unknownThinkingMode(value.string ?? "\(value)")
            }
            config.thinkingMode = mode
        }
        if let value = object["reasoningEffort"], value != .null {
            guard let raw = value.string, MiMoReasoningEffort(rawValue: raw) != nil else {
                throw MiMoConfigError.unknownReasoningEffort(value.string ?? "\(value)")
            }
            config.reasoningEffort = raw
        }

        self = try config.validated()
    }

    func validated() throws -> MiMoConfig {
        guard MiMoWire.models.contains(model) else {
            throw MiMoConfigError.unknownModel(model)
        }
        if let reasoningEffort {
            guard MiMoReasoningEffort(rawValue: reasoningEffort) != nil else {
                throw MiMoConfigError.unknownReasoningEffort(reasoningEffort)
            }
        }
        if protocolKind == .chatCompletions, reasoningEffort != nil {
            throw MiMoConfigError.reasoningEffortRequiresResponses
        }
        return self
    }

    /// Chat Completions sends a `thinking` object only when the user made an explicit choice.
    var chatThinkingType: String? {
        switch thinkingMode {
        case .default: nil
        case .enabled: "enabled"
        case .disabled: "disabled"
        }
    }

    /// Responses sends `reasoning.effort` only when it is meaningful. `default` leaves the field
    /// out entirely; `enabled` without an effort also leaves it out so the server picks its default.
    var responsesEffort: String? {
        switch thinkingMode {
        case .default:
            nil
        case .disabled:
            "none"
        case .enabled:
            reasoningEffort.flatMap(MiMoReasoningEffort.init(rawValue:))?.wireValue
        }
    }

    /// Applies a temporary thinking selection for exactly one request. Effort is kept only where the
    /// effective mode actually sends one, so the cassette digest describes the same body that goes
    /// on the wire. The saved configuration is never mutated.
    func applyingThinking(_ mode: MiMoThinkingMode) -> MiMoConfig {
        guard mode != thinkingMode else { return self }
        var effective = self
        effective.thinkingMode = mode
        effective.reasoningEffort = mode == .enabled ? reasoningEffort : nil
        return effective
    }
}
