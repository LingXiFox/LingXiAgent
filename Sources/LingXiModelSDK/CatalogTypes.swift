import Foundation

// The published catalog types. These describe what a model *is* — its identity,
// limits, capabilities and price — and never what LingXi's runtime does with it.
// Protocol family, adapter, authentication and endpoint overrides belong to the
// consumer's runtime layer, not to this catalog.

/// Lifecycle state of a published model.
public enum CatalogModelStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case preview
    case deprecated
    case retired
    case unknown

    /// A state the publisher has not named stays `unknown` rather than becoming
    /// `active` by accident: an unknown model is still selectable, an unknown
    /// deprecated model would otherwise outlive its retirement.
    public init(lenient raw: String?) {
        switch raw {
        case "deprecated", "retired": self = .deprecated
        case "beta", "preview": self = .preview
        case "active": self = .active
        default: self = .unknown
        }
    }

    public var isSelectable: Bool {
        switch self {
        case .active, .preview, .unknown: return true
        case .deprecated, .retired: return false
        }
    }
}

/// Token limits, in tokens. A `nil` field means the source stated nothing, which
/// is not the same as zero.
public struct ModelLimits: Codable, Sendable, Equatable {
    public let context: Int?
    public let input: Int?
    public let output: Int?

    public init(context: Int?, input: Int?, output: Int?) {
        self.context = context
        self.input = input
        self.output = output
    }
}

/// Capability facts as published by the source. Each one answers "does the
/// model have this", never "how does a particular runtime ask for it".
public struct ModelCapabilities: Codable, Sendable, Equatable {
    public let reasoning: Bool
    /// Reasoning effort values the source lists, e.g. `minimal`, `low`, `high`.
    public let reasoningEfforts: [String]
    public let toolCalling: Bool
    public let structuredOutput: Bool
    /// True when the model accepts attachments (files, images) on input.
    public let attachments: Bool
    public let vision: Bool
    public let audioInput: Bool
    public let audioOutput: Bool
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let openWeights: Bool
    public let supportsTemperature: Bool?

    public init(
        reasoning: Bool,
        reasoningEfforts: [String],
        toolCalling: Bool,
        structuredOutput: Bool,
        attachments: Bool,
        vision: Bool,
        audioInput: Bool,
        audioOutput: Bool,
        inputModalities: [String],
        outputModalities: [String],
        openWeights: Bool,
        supportsTemperature: Bool?
    ) {
        self.reasoning = reasoning
        self.reasoningEfforts = reasoningEfforts
        self.toolCalling = toolCalling
        self.structuredOutput = structuredOutput
        self.attachments = attachments
        self.vision = vision
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.openWeights = openWeights
        self.supportsTemperature = supportsTemperature
    }

    /// Modality names are the source's own; matching is case- and plural-insensitive
    /// because the published lists mix `image`/`images` and `audio`/`audios`.
    static func contains(_ modalities: [String], _ name: String) -> Bool {
        modalities.contains { $0.lowercased().hasPrefix(name) }
    }
}

/// Published price in US dollars per one million tokens. `nil` when the source
/// lists no price; zero is a real price and is preserved as such.
public struct ModelPricing: Codable, Sendable, Equatable {
    public let input: Double?
    public let output: Double?
    public let cacheRead: Double?
    public let cacheWrite: Double?
    public let reasoning: Double?
    public let inputAudio: Double?
    public let outputAudio: Double?

    public init(
        input: Double?,
        output: Double?,
        cacheRead: Double?,
        cacheWrite: Double?,
        reasoning: Double?,
        inputAudio: Double?,
        outputAudio: Double?
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.inputAudio = inputAudio
        self.outputAudio = outputAudio
    }

    /// True when no price is stated at all, so a caller can render "价格未知"
    /// instead of treating the model as free.
    public var isUnknown: Bool {
        input == nil && output == nil && cacheRead == nil && cacheWrite == nil
            && reasoning == nil && inputAudio == nil && outputAudio == nil
    }
}

/// One published model.
public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let providerID: String
    public let name: String
    public let family: String?
    public let overview: String?
    public let releaseDate: String?
    public let lastUpdated: String?
    public let knowledgeCutoff: String?
    public let canonicalModelID: String?
    public let status: CatalogModelStatus
    public let limits: ModelLimits
    public let capabilities: ModelCapabilities
    public let pricing: ModelPricing
    /// The complete entry as published, including every field this SDK does not
    /// model. Typed accessors are a convenience view over the same data; a newer
    /// source field is reachable here without waiting for an SDK release.
    public let fields: [String: ModelCatalogValue]

    /// `provider/model`, the form a runtime selects a model by.
    public var qualifiedID: String { "\(providerID)/\(id)" }

    public var contextWindow: Int? { limits.context }
    public var maxOutputTokens: Int? { limits.output }

    public init(
        id: String,
        providerID: String,
        name: String,
        family: String?,
        overview: String?,
        releaseDate: String?,
        lastUpdated: String?,
        knowledgeCutoff: String?,
        canonicalModelID: String?,
        status: CatalogModelStatus,
        limits: ModelLimits,
        capabilities: ModelCapabilities,
        pricing: ModelPricing,
        fields: [String: ModelCatalogValue]
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.family = family
        self.overview = overview
        self.releaseDate = releaseDate
        self.lastUpdated = lastUpdated
        self.knowledgeCutoff = knowledgeCutoff
        self.canonicalModelID = canonicalModelID
        self.status = status
        self.limits = limits
        self.capabilities = capabilities
        self.pricing = pricing
        self.fields = fields
    }
}

/// One published provider.
public struct CatalogProvider: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The vendor's own API endpoint, present only when the source states it.
    /// A `nil` here is not an instruction to route somewhere else.
    public let baseURL: String?
    public let documentationURL: String?
    public let environmentVariableNames: [String]
    public let models: [CatalogModel]
    public let fields: [String: ModelCatalogValue]

    public var modelCount: Int { models.count }

    public init(
        id: String,
        name: String,
        baseURL: String?,
        documentationURL: String?,
        environmentVariableNames: [String],
        models: [CatalogModel],
        fields: [String: ModelCatalogValue]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.documentationURL = documentationURL
        self.environmentVariableNames = environmentVariableNames
        self.models = models
        self.fields = fields
    }
}
