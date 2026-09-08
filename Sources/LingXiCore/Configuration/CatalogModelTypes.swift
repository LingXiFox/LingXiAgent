import Foundation
import LingXiProtocol

// MARK: - Upstream Snapshot DTOs

public struct UpstreamPricing: Codable, Sendable, Equatable {
    public let input: Double?
    public let output: Double?
    public let cacheRead: Double?
    public let cacheWrite: Double?

    public init(input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct UpstreamModel: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let modalities: [String]?
    public let vision: Bool?
    public let toolCalling: Bool?
    public let parallelToolCalling: Bool?
    public let reasoning: Bool?
    public let structuredOutput: Bool?
    public let pricing: UpstreamPricing?

    public init(
        id: String,
        name: String,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        modalities: [String]? = nil,
        vision: Bool? = nil,
        toolCalling: Bool? = nil,
        parallelToolCalling: Bool? = nil,
        reasoning: Bool? = nil,
        structuredOutput: Bool? = nil,
        pricing: UpstreamPricing? = nil
    ) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modalities = modalities
        self.vision = vision
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.reasoning = reasoning
        self.structuredOutput = structuredOutput
        self.pricing = pricing
    }
}

public struct UpstreamProvider: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let models: [String: UpstreamModel]

    public init(id: String, name: String, models: [String: UpstreamModel]) {
        self.id = id
        self.name = name
        self.models = models
    }
}

public struct UpstreamCatalogSnapshot: Codable, Sendable, Equatable {
    public let version: String
    public let generatedAt: String
    public let providers: [String: UpstreamProvider]

    public init(version: String, generatedAt: String, providers: [String: UpstreamProvider]) {
        self.version = version
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct CatalogManifest: Codable, Sendable, Equatable {
    public let upstreamSource: String
    public let upstreamRevision: String
    public let fetchedAt: String?
    public let snapshotDate: String
    public let sha256: String
    public let importerSchemaVersion: Int
    public let generatedTimestamp: String

    public init(
        upstreamSource: String,
        upstreamRevision: String,
        fetchedAt: String? = nil,
        snapshotDate: String,
        sha256: String,
        importerSchemaVersion: Int,
        generatedTimestamp: String
    ) {
        self.upstreamSource = upstreamSource
        self.upstreamRevision = upstreamRevision
        self.fetchedAt = fetchedAt
        self.snapshotDate = snapshotDate
        self.sha256 = sha256
        self.importerSchemaVersion = importerSchemaVersion
        self.generatedTimestamp = generatedTimestamp
    }
}

// MARK: - Overlay DTOs

public struct OverlayOAuth: Codable, Sendable, Equatable {
    public let provider: String
    public let clientID: String
    public let authURL: String
    public let tokenURL: String
    public let scopes: [String]
    public let usePKCE: Bool
    public let requestProfileID: String
    public let redirectURI: String?

    public init(
        provider: String,
        clientID: String,
        authURL: String,
        tokenURL: String,
        scopes: [String],
        usePKCE: Bool = true,
        requestProfileID: String,
        redirectURI: String? = nil
    ) {
        self.provider = provider
        self.clientID = clientID
        self.authURL = authURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.usePKCE = usePKCE
        self.requestProfileID = requestProfileID
        self.redirectURI = redirectURI
    }
}

public struct OverlayRequestProfile: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let compatibilityMode: String // "conservative" | "officialLike"
    public let endpointOverride: String?
    public let requiredHeaders: [String: String]?
    public let dynamicHeaders: [String: String]?
    public let userAgentProfile: String?

    public init(
        id: String,
        version: String,
        compatibilityMode: String = "conservative",
        endpointOverride: String? = nil,
        requiredHeaders: [String: String]? = nil,
        dynamicHeaders: [String: String]? = nil,
        userAgentProfile: String? = nil
    ) {
        self.id = id
        self.version = version
        self.compatibilityMode = compatibilityMode
        self.endpointOverride = endpointOverride
        self.requiredHeaders = requiredHeaders
        self.dynamicHeaders = dynamicHeaders
        self.userAgentProfile = userAgentProfile
    }
}

public struct OverlayModel: Codable, Sendable, Equatable {
    public let upstreamID: String
    public let id: String
    public let displayName: String?
    public let reasoningCapability: ReasoningCapability?
    public let toolCall: Bool?
    public let vision: Bool?
    public let cache: Bool?

    public init(
        upstreamID: String,
        id: String,
        displayName: String? = nil,
        reasoningCapability: ReasoningCapability? = nil,
        toolCall: Bool? = nil,
        vision: Bool? = nil,
        cache: Bool? = nil
    ) {
        self.upstreamID = upstreamID
        self.id = id
        self.displayName = displayName
        self.reasoningCapability = reasoningCapability
        self.toolCall = toolCall
        self.vision = vision
        self.cache = cache
    }
}

public struct OverlayProduct: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let type: String // "cloudAPI" | "subscription" | "localRuntime" | "gateway"
    public let protocolFamily: String
    public let endpoint: String
    public let authMethods: [String]
    public let concurrencyLimit: Int?
    public let quirks: [String]?
    public let verificationStatus: String // "verified" | "compatibleNonOfficial" | "experimental" | "unsupported"
    public let requiredAccountFields: [String]?
    public let oauth: OverlayOAuth?
    public let requestProfiles: [String: OverlayRequestProfile]?
    public let modelDiscovery: ModelDiscoveryStrategy?
    public let models: [OverlayModel]

    public init(
        id: String,
        displayName: String,
        type: String,
        protocolFamily: String,
        endpoint: String,
        authMethods: [String],
        concurrencyLimit: Int? = nil,
        quirks: [String]? = nil,
        verificationStatus: String,
        requiredAccountFields: [String]? = nil,
        oauth: OverlayOAuth? = nil,
        requestProfiles: [String: OverlayRequestProfile]? = nil,
        modelDiscovery: ModelDiscoveryStrategy? = nil,
        models: [OverlayModel] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.protocolFamily = protocolFamily
        self.endpoint = endpoint
        self.authMethods = authMethods
        self.concurrencyLimit = concurrencyLimit
        self.quirks = quirks
        self.verificationStatus = verificationStatus
        self.requiredAccountFields = requiredAccountFields
        self.oauth = oauth
        self.requestProfiles = requestProfiles
        self.modelDiscovery = modelDiscovery
        self.models = models
    }
}

public struct OverlayDocument: Codable, Sendable, Equatable {
    public let vendor: String
    public let products: [OverlayProduct]

    public init(vendor: String, products: [OverlayProduct]) {
        self.vendor = vendor
        self.products = products
    }
}

// MARK: - Generated Catalog DTOs

public struct GeneratedModel: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let upstreamID: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let toolCalling: Bool
    public let parallelToolCalling: Bool
    public let vision: Bool
    public let cache: Bool
    public let reasoningCapability: ReasoningCapability?
    public let structuredOutput: Bool
    public let pricing: UpstreamPricing?

    public init(
        id: String,
        displayName: String,
        upstreamID: String,
        contextWindow: Int?,
        maxOutputTokens: Int?,
        toolCalling: Bool,
        parallelToolCalling: Bool,
        vision: Bool,
        cache: Bool,
        reasoningCapability: ReasoningCapability?,
        structuredOutput: Bool,
        pricing: UpstreamPricing?
    ) {
        self.id = id
        self.displayName = displayName
        self.upstreamID = upstreamID
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.cache = cache
        self.reasoningCapability = reasoningCapability
        self.structuredOutput = structuredOutput
        self.pricing = pricing
    }
}

public struct GeneratedProduct: Codable, Sendable, Equatable {
    public let id: String
    public let vendor: String
    public let displayName: String
    public let type: String
    public let protocolFamily: String
    public let endpoint: String
    public let authMethods: [String]
    public let concurrencyLimit: Int?
    public let quirks: [String]
    public let verificationStatus: String
    public let requiredAccountFields: [String]
    public let oauth: OverlayOAuth?
    public let requestProfiles: [String: OverlayRequestProfile]
    public let modelDiscovery: ModelDiscoveryStrategy
    public let models: [GeneratedModel]

    public init(
        id: String,
        vendor: String,
        displayName: String,
        type: String,
        protocolFamily: String,
        endpoint: String,
        authMethods: [String],
        concurrencyLimit: Int?,
        quirks: [String],
        verificationStatus: String,
        requiredAccountFields: [String],
        oauth: OverlayOAuth?,
        requestProfiles: [String: OverlayRequestProfile],
        modelDiscovery: ModelDiscoveryStrategy = .staticCatalog,
        models: [GeneratedModel]
    ) {
        self.id = id
        self.vendor = vendor
        self.displayName = displayName
        self.type = type
        self.protocolFamily = protocolFamily
        self.endpoint = endpoint
        self.authMethods = authMethods
        self.concurrencyLimit = concurrencyLimit
        self.quirks = quirks
        self.verificationStatus = verificationStatus
        self.requiredAccountFields = requiredAccountFields
        self.oauth = oauth
        self.requestProfiles = requestProfiles
        self.modelDiscovery = modelDiscovery
        self.models = models
    }
}

public struct GeneratedProviderCatalog: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let manifest: CatalogManifest
    public let products: [GeneratedProduct]

    public init(schemaVersion: Int, generatedAt: String, manifest: CatalogManifest, products: [GeneratedProduct]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.manifest = manifest
        self.products = products
    }
}
