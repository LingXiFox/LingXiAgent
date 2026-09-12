import Foundation

/// Canonical reasoning effort levels across sessions and models.
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Comparable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    case auto

    /// Numerical sort rank for canonical reasoning progression:
    /// off (0) < minimal (1) < low (2) < medium (3) < high (4) < xhigh (5) < max (6) < ultra (7) < auto (99)
    public var sortOrder: Int {
        switch self {
        case .off: return 0
        case .minimal: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .xhigh: return 5
        case .max: return 6
        case .ultra: return 7
        case .auto: return 99
        }
    }

    public static func < (lhs: ReasoningEffort, rhs: ReasoningEffort) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
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
