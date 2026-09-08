import Foundation

/// Canonical reasoning effort levels across sessions and models.
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case auto
    case off
    case minimal
    case low
    case medium
    case high
    case max
}

/// Reasoning capability configuration for a model profile.
public struct ReasoningCapability: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case none
        case toggle
        case effort
        case budget
        case adaptive
    }

    public var mode: Mode
    public var supportedEfforts: [ReasoningEffort]
    public var defaultEffort: ReasoningEffort
    public var emitsVisibleReasoning: Bool
    public var emitsReasoningSummary: Bool
    public var coarseMappings: [ReasoningEffort: String]

    public init(
        mode: Mode = .none,
        supportedEfforts: [ReasoningEffort] = [.auto, .off],
        defaultEffort: ReasoningEffort = .auto,
        emitsVisibleReasoning: Bool = false,
        emitsReasoningSummary: Bool = false,
        coarseMappings: [ReasoningEffort: String] = [:]
    ) {
        self.mode = mode
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.emitsVisibleReasoning = emitsVisibleReasoning
        self.emitsReasoningSummary = emitsReasoningSummary
        self.coarseMappings = coarseMappings
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case supportedEfforts
        case defaultEffort
        case emitsVisibleReasoning
        case emitsReasoningSummary
        case coarseMappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        supportedEfforts = try container.decode([ReasoningEffort].self, forKey: .supportedEfforts)
        defaultEffort = try container.decode(ReasoningEffort.self, forKey: .defaultEffort)
        emitsVisibleReasoning = try container.decode(Bool.self, forKey: .emitsVisibleReasoning)
        emitsReasoningSummary = try container.decode(Bool.self, forKey: .emitsReasoningSummary)
        let rawMappings = try container.decodeIfPresent([String: String].self, forKey: .coarseMappings) ?? [:]
        var mappings: [ReasoningEffort: String] = [:]
        for (k, v) in rawMappings {
            if let effort = ReasoningEffort(rawValue: k) {
                mappings[effort] = v
            }
        }
        coarseMappings = mappings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(supportedEfforts, forKey: .supportedEfforts)
        try container.encode(defaultEffort, forKey: .defaultEffort)
        try container.encode(emitsVisibleReasoning, forKey: .emitsVisibleReasoning)
        try container.encode(emitsReasoningSummary, forKey: .emitsReasoningSummary)
        var rawMappings: [String: String] = [:]
        for (k, v) in coarseMappings {
            rawMappings[k.rawValue] = v
        }
        try container.encode(rawMappings, forKey: .coarseMappings)
    }

    /// Resolve a canonical effort against this model's capabilities.
    public func resolveEffort(_ requested: ReasoningEffort) -> (effective: ReasoningEffort, message: String?) {
        if mode == .none {
            if requested == .off || requested == .auto {
                return (defaultEffort, nil)
            }
            return (defaultEffort, "当前模型不支持推理等级调节，已回退到默认: \(defaultEffort.rawValue)")
        }
        if supportedEfforts.contains(requested) {
            return (requested, nil)
        }
        if let mapped = coarseMappings[requested] {
            return (requested, "当前模型仅支持粗粒度思考控制，\(requested.rawValue) 已映射为: \(mapped)")
        }
        return (defaultEffort, "当前模型不支持推理等级 \(requested.rawValue)，已回退到模型默认: \(defaultEffort.rawValue)")
    }
}
