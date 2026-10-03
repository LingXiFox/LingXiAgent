import Foundation

/// A local inference runtime: a model server the user runs themselves, which — unlike a cloud
/// API — can tell us what it has actually loaded right now.
///
/// Only backends with a real implementation are listed. Ollama, llama.cpp and vLLM have native
/// status endpoints too, but a case here is a promise Core can honour, so they are added when
/// they are implemented rather than as placeholders.
public enum LocalInferenceBackend: String, Codable, Sendable, Equatable, CaseIterable {
    case lmStudio = "lmstudio"
}

public enum SpeculativeDecodingMode: String, Codable, Sendable, Equatable {
    /// Multi-token prediction heads in the model itself; no draft model involved.
    case mtp
    /// A separate, smaller draft model.
    case externalDraftModel
    case unavailable
}

/// One response's speculative-decoding outcome. Counts are optional individually: a field the
/// response did not carry stays nil rather than being estimated.
public struct SpeculativeDecodingMetrics: Codable, Sendable, Equatable {
    public let backend: LocalInferenceBackend
    public let mode: SpeculativeDecodingMode
    public let draftModel: String?
    public let draftedTokens: Int?
    public let acceptedTokens: Int?
    public let rejectedTokens: Int?
    public let ignoredTokens: Int?
    public let observedAt: Date

    public init(backend: LocalInferenceBackend, mode: SpeculativeDecodingMode, draftModel: String? = nil,
                draftedTokens: Int?, acceptedTokens: Int?, rejectedTokens: Int?, ignoredTokens: Int? = nil,
                observedAt: Date = Date()) {
        self.backend = backend
        self.mode = mode
        self.draftModel = draftModel
        self.draftedTokens = draftedTokens
        self.acceptedTokens = acceptedTokens
        self.rejectedTokens = rejectedTokens
        self.ignoredTokens = ignoredTokens
        self.observedAt = observedAt
    }

    /// Derived: accepted / drafted. Nil when either is missing or nothing was drafted.
    public var acceptanceRate: Double? {
        guard let draftedTokens, let acceptedTokens, draftedTokens > 0 else { return nil }
        return Double(acceptedTokens) / Double(draftedTokens)
    }
}

/// What the runtime reports about one model, as of the last discovery.
///
/// `runtimeContextTokens` and `modelMaxContextTokens` are deliberately separate: a model that can
/// address 256K but is loaded with 64K has a 64K budget, and confusing the two is how an agent
/// plans for room it does not have.
public struct LocalRuntimeModelStatus: Codable, Sendable, Equatable {
    public enum DiscoverySource: String, Codable, Sendable, Equatable {
        /// The runtime's native status endpoint answered.
        case native
        /// Only the OpenAI-compatible `/models` list answered; no runtime state is known.
        case openAICompatibleFallback
        /// Nothing answered. Distinct from "answered with no models".
        case unreachable
    }

    public let backend: LocalInferenceBackend
    public let endpoint: String
    public let source: DiscoverySource
    public let discoveredAt: Date
    /// Why discovery fell short, when it did.
    public let note: String?

    public let modelKey: String?
    public let loadedInstanceID: String?
    /// True only when the native endpoint lists a loaded instance for this model.
    public let isLoaded: Bool
    public let architecture: String?
    public let quantization: String?
    public let quantizationBits: Double?
    public let sizeBytes: Int?
    public let runtimeContextTokens: Int?
    public let modelMaxContextTokens: Int?
    public let toolUse: Bool?
    public let vision: Bool?
    public let reasoningOptions: [String]?
    public let reasoningDefault: String?

    public let flashAttention: Bool?
    public let kvCacheOnGPU: Bool?
    public let evalBatchSize: Int?
    public let parallel: Int?
    public let mtpEnabled: Bool?
    /// Nil when no external draft model is configured (an empty string on the wire).
    public let externalDraftModel: String?
    public let draftMaxTokens: Int?
    public let draftMinContinueProbability: Double?

    /// The latest response's speculative statistics, if any response has carried them.
    public var lastSpeculative: SpeculativeDecodingMetrics?

    public init(backend: LocalInferenceBackend, endpoint: String, source: DiscoverySource,
                discoveredAt: Date = Date(), note: String? = nil, modelKey: String? = nil,
                loadedInstanceID: String? = nil, isLoaded: Bool = false, architecture: String? = nil,
                quantization: String? = nil, quantizationBits: Double? = nil, sizeBytes: Int? = nil,
                runtimeContextTokens: Int? = nil, modelMaxContextTokens: Int? = nil, toolUse: Bool? = nil,
                vision: Bool? = nil, reasoningOptions: [String]? = nil, reasoningDefault: String? = nil,
                flashAttention: Bool? = nil, kvCacheOnGPU: Bool? = nil, evalBatchSize: Int? = nil,
                parallel: Int? = nil, mtpEnabled: Bool? = nil, externalDraftModel: String? = nil,
                draftMaxTokens: Int? = nil, draftMinContinueProbability: Double? = nil,
                lastSpeculative: SpeculativeDecodingMetrics? = nil) {
        self.backend = backend
        self.endpoint = endpoint
        self.source = source
        self.discoveredAt = discoveredAt
        self.note = note
        self.modelKey = modelKey
        self.loadedInstanceID = loadedInstanceID
        self.isLoaded = isLoaded
        self.architecture = architecture
        self.quantization = quantization
        self.quantizationBits = quantizationBits
        self.sizeBytes = sizeBytes
        self.runtimeContextTokens = runtimeContextTokens
        self.modelMaxContextTokens = modelMaxContextTokens
        self.toolUse = toolUse
        self.vision = vision
        self.reasoningOptions = reasoningOptions
        self.reasoningDefault = reasoningDefault
        self.flashAttention = flashAttention
        self.kvCacheOnGPU = kvCacheOnGPU
        self.evalBatchSize = evalBatchSize
        self.parallel = parallel
        self.mtpEnabled = mtpEnabled
        self.externalDraftModel = externalDraftModel
        self.draftMaxTokens = draftMaxTokens
        self.draftMinContinueProbability = draftMinContinueProbability
        self.lastSpeculative = lastSpeculative
    }

    /// Speculative decoding as configured, before any response is seen.
    public var configuredSpeculativeMode: SpeculativeDecodingMode {
        if let externalDraftModel, !externalDraftModel.isEmpty { return .externalDraftModel }
        if mtpEnabled == true { return .mtp }
        return .unavailable
    }
}
