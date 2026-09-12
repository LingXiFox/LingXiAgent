import Foundation
import LingXiProtocol

// MARK: - Model lifecycle

/// Lifecycle state of a model in the registry.
///
/// Only `active` and `preview` take part in default selection. The remaining
/// states exist so that metadata about a superseded model stays available
/// without letting it anchor what the agent reaches for by default.
public enum RegistryModelStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case preview
    case deprecated
    case retired
    case unknown

    /// Whether this status may be offered for default selection.
    public var isSelectable: Bool {
        switch self {
        case .active, .preview: return true
        case .deprecated, .retired, .unknown: return false
        }
    }

    /// Decoding is lenient: a status the client does not know is `unknown`
    /// rather than a decode failure, so a newer server can add states without
    /// breaking older clients.
    public init(lenient raw: String) {
        self = RegistryModelStatus(rawValue: raw) ?? .unknown
    }
}

/// What LingXi has actually implemented for a product or model.
///
/// This is deliberately separate from catalog availability ("what exists
/// upstream") and account availability ("what this user can reach"). A model
/// can be listed in the catalog and still not be runnable here.
public enum RuntimeSupport: String, Codable, Sendable, Equatable {
    case implemented
    case partial
    case unsupported

    /// Whether the runtime can execute this entry at all. `partial` is runnable
    /// — it means some paths are incomplete, not that execution is unavailable.
    public var isRunnable: Bool {
        self != .unsupported
    }

    public init(lenient raw: String) {
        self = RuntimeSupport(rawValue: raw) ?? .unsupported
    }
}

// MARK: - Capabilities

/// Per-model capability facts. Every field is optional so that "unknown" stays
/// distinguishable from "false" — a model with no stated vision support is not
/// the same as one stated to lack it.
public struct RegistryCapabilities: Codable, Sendable, Equatable {
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let toolCalling: Bool?
    public let parallelToolCalling: Bool?
    public let vision: Bool?
    public let reasoning: Bool?
    public let reasoningMode: String?
    public let supportedReasoningEfforts: [String]?
    public let structuredOutput: Bool?
    public let cache: Bool?
    public let modalities: [String]?

    public init(
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        toolCalling: Bool? = nil,
        parallelToolCalling: Bool? = nil,
        vision: Bool? = nil,
        reasoning: Bool? = nil,
        reasoningMode: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        structuredOutput: Bool? = nil,
        cache: Bool? = nil,
        modalities: [String]? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.reasoning = reasoning
        self.reasoningMode = reasoningMode
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.structuredOutput = structuredOutput
        self.cache = cache
        self.modalities = modalities
    }

    public var reasoningEfforts: [ReasoningEffort] {
        (supportedReasoningEfforts ?? []).compactMap { ReasoningEffort(rawValue: $0) }
    }
}

// MARK: - Registry documents

public struct RegistryCatalogMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let generatedAt: String
    public let sourceRevision: String
    public let sha256: String

    public init(schemaVersion: Int, catalogRevision: String, generatedAt: String, sourceRevision: String, sha256: String) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.generatedAt = generatedAt
        self.sourceRevision = sourceRevision
        self.sha256 = sha256
    }
}

public struct RegistryVendor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A model as published in the catalog.
public struct RegistryModelRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let productID: String
    public let displayName: String
    public let status: String
    public let capabilities: RegistryCapabilities
    public let metadataIncomplete: Bool
    public let source: String
    public let discoveredAt: String?
    public let verifiedAt: String?

    public let upstreamModelID: String?
    public let sourceAuthority: String?
    public let sourceAuthorityKind: String?
    public let discoveredFrom: String?
    public let listingVerified: Bool
    public let namingVerification: String?
    public let displayNameSource: String?

    public init(
        id: String,
        productID: String,
        displayName: String,
        status: String,
        capabilities: RegistryCapabilities = RegistryCapabilities(),
        metadataIncomplete: Bool = true,
        source: String = "",
        discoveredAt: String? = nil,
        verifiedAt: String? = nil,
        upstreamModelID: String? = nil,
        sourceAuthority: String? = nil,
        sourceAuthorityKind: String? = nil,
        discoveredFrom: String? = nil,
        listingVerified: Bool = false,
        namingVerification: String? = nil,
        displayNameSource: String? = nil
    ) {
        self.id = id
        self.productID = productID
        self.displayName = displayName
        self.status = status
        self.capabilities = capabilities
        self.metadataIncomplete = metadataIncomplete
        self.source = source
        self.discoveredAt = discoveredAt
        self.verifiedAt = verifiedAt
        self.upstreamModelID = upstreamModelID
        self.sourceAuthority = sourceAuthority
        self.sourceAuthorityKind = sourceAuthorityKind
        self.discoveredFrom = discoveredFrom
        self.listingVerified = listingVerified
        self.namingVerification = namingVerification
        self.displayNameSource = displayNameSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.productID = try container.decode(String.self, forKey: .productID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.status = try container.decode(String.self, forKey: .status)
        self.capabilities = try container.decodeIfPresent(RegistryCapabilities.self, forKey: .capabilities) ?? RegistryCapabilities()
        self.metadataIncomplete = try container.decodeIfPresent(Bool.self, forKey: .metadataIncomplete) ?? false
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.discoveredAt = try container.decodeIfPresent(String.self, forKey: .discoveredAt)
        self.verifiedAt = try container.decodeIfPresent(String.self, forKey: .verifiedAt)
        self.upstreamModelID = try container.decodeIfPresent(String.self, forKey: .upstreamModelID)
        self.sourceAuthority = try container.decodeIfPresent(String.self, forKey: .sourceAuthority)
        self.sourceAuthorityKind = try container.decodeIfPresent(String.self, forKey: .sourceAuthorityKind)
        self.discoveredFrom = try container.decodeIfPresent(String.self, forKey: .discoveredFrom)
        self.listingVerified = try container.decodeIfPresent(Bool.self, forKey: .listingVerified) ?? false
        self.namingVerification = try container.decodeIfPresent(String.self, forKey: .namingVerification)
        self.displayNameSource = try container.decodeIfPresent(String.self, forKey: .displayNameSource)
    }

    private enum CodingKeys: String, CodingKey {
        case id, productID, displayName, status, capabilities, metadataIncomplete, source
        case discoveredAt, verifiedAt, upstreamModelID, sourceAuthority, sourceAuthorityKind
        case discoveredFrom, listingVerified, namingVerification, displayNameSource
    }

    public var modelStatus: RegistryModelStatus { RegistryModelStatus(lenient: status) }

    /// Source label for a record that came from an upstream listing.
    public static let sourceUpstreamDiscovery = "upstream-discovery"
    /// Source label for a record that came from registry metadata alone.
    public static let sourceStaticMetadata = "static-metadata"
}

/// How to read a model list off an upstream endpoint.
///
/// Published by the registry so a client can perform account discovery against
/// the right URL and wire format without hardcoding either. The `kind` selects
/// the response parser; it is the only place a provider-specific listing shape
/// is allowed to be known.
public struct RegistryDiscoveryProfile: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let url: String
    public let auth: String?
    public let authKeyParam: String?
    public let headers: [String: String]?
    public let cacheTTL: String?
    public let sourceAuthorityKind: String?
    /// Whether the endpoint is reachable with no credential at all.
    public let `public`: Bool?

    public init(
        id: String,
        kind: String,
        url: String,
        auth: String? = nil,
        authKeyParam: String? = nil,
        headers: [String: String]? = nil,
        cacheTTL: String? = nil,
        sourceAuthorityKind: String? = nil,
        isPublic: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.auth = auth
        self.authKeyParam = authKeyParam
        self.headers = headers
        self.cacheTTL = cacheTTL
        self.sourceAuthorityKind = sourceAuthorityKind
        self.`public` = isPublic
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, url, auth, authKeyParam, headers, cacheTTL
        case sourceAuthorityKind
        case `public`
    }
}

/// Discovery implementation details for a product (status and backend adapter).
public struct DiscoveryImplementation: Codable, Sendable, Equatable {
    public let status: String
    public let backend: String?

    public init(status: String, backend: String? = nil) {
        self.status = status
        self.backend = backend
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case backend
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.status = try container.decode(String.self, forKey: .status)
            self.backend = try container.decodeIfPresent(String.self, forKey: .backend)
            return
        }
        if let singleValue = try? decoder.singleValueContainer(),
           let statusStr = try? singleValue.decode(String.self) {
            self.status = statusStr
            self.backend = nil
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected DiscoveryImplementation dictionary or status string"
            )
        )
    }
}

/// A product together with the IDs of the models published for it.
public struct RegistryProduct: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let vendorID: String
    public let displayName: String
    public let type: String?
    public let authStrategy: String
    public let authMethods: [String]?
    public let protocolFamily: String
    public let discoveryStrategy: String
    public let discoveryProfileID: String?
    public let endpoint: String?
    public let runtimeSupport: String
    public let concurrencyLimit: Int?
    public let quirks: [String]?
    public let verificationStatus: String?
    public let discoveryImplementation: DiscoveryImplementation?
    public let namingVerification: String?
    public let requestProfileID: String?
    public let accountFields: [String]?
    public let modelIDs: [String]
    public let discoveryProfile: RegistryDiscoveryProfile?

    public init(
        id: String,
        vendorID: String,
        displayName: String,
        type: String? = nil,
        authStrategy: String,
        authMethods: [String]? = nil,
        protocolFamily: String,
        discoveryStrategy: String,
        discoveryProfileID: String? = nil,
        endpoint: String? = nil,
        runtimeSupport: String,
        concurrencyLimit: Int? = nil,
        quirks: [String]? = nil,
        verificationStatus: String? = nil,
        discoveryImplementation: DiscoveryImplementation? = nil,
        namingVerification: String? = nil,
        requestProfileID: String? = nil,
        accountFields: [String]? = nil,
        modelIDs: [String] = [],
        discoveryProfile: RegistryDiscoveryProfile? = nil
    ) {
        self.id = id
        self.vendorID = vendorID
        self.displayName = displayName
        self.type = type
        self.authStrategy = authStrategy
        self.authMethods = authMethods
        self.protocolFamily = protocolFamily
        self.discoveryStrategy = discoveryStrategy
        self.discoveryProfileID = discoveryProfileID
        self.endpoint = endpoint
        self.runtimeSupport = runtimeSupport
        self.concurrencyLimit = concurrencyLimit
        self.quirks = quirks
        self.verificationStatus = verificationStatus
        self.discoveryImplementation = discoveryImplementation
        self.namingVerification = namingVerification
        self.requestProfileID = requestProfileID
        self.accountFields = accountFields
        self.modelIDs = modelIDs
        self.discoveryProfile = discoveryProfile
    }

    public var runtime: RuntimeSupport { RuntimeSupport(lenient: runtimeSupport) }
    public var discovery: ModelDiscoveryStrategy { ModelDiscoveryStrategy(lenient: discoveryStrategy) }
}

/// Per-product discovery freshness as published by the registry.
public struct RegistryCacheSummary: Codable, Sendable, Equatable {
    public let status: String
    public let fetchedAt: String?
    public let expiresAt: String?
    public let source: String?
    public let modelCount: Int
    public let lastError: String?

    public init(status: String, fetchedAt: String? = nil, expiresAt: String? = nil, source: String? = nil, modelCount: Int = 0, lastError: String? = nil) {
        self.status = status
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.source = source
        self.modelCount = modelCount
        self.lastError = lastError
    }
}

/// The canonical catalog document served at `/v1/catalog`.
public struct RegistryCatalog: Codable, Sendable, Equatable {
    public let metadata: RegistryCatalogMetadata
    public let vendors: [RegistryVendor]
    public let products: [RegistryProduct]
    public let models: [RegistryModelRecord]
    public let discoveryCache: [String: RegistryCacheSummary]?

    public init(
        metadata: RegistryCatalogMetadata,
        vendors: [RegistryVendor],
        products: [RegistryProduct],
        models: [RegistryModelRecord],
        discoveryCache: [String: RegistryCacheSummary]? = nil
    ) {
        self.metadata = metadata
        self.vendors = vendors
        self.products = products
        self.models = models
        self.discoveryCache = discoveryCache
    }

    public func product(id: String) -> RegistryProduct? {
        products.first { $0.id == id }
    }

    public func models(productID: String) -> [RegistryModelRecord] {
        models.filter { $0.productID == productID }
    }

    public func vendorName(_ id: String) -> String? {
        vendors.first { $0.id == id }?.displayName
    }
}

/// The `/v1/catalog/status` document: a cheap change detector.
public struct RegistryCatalogStatus: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let generatedAt: String
    public let sourceRevision: String?
    public let providerCount: Int
    public let productCount: Int
    public let modelCount: Int
    public let sha256: String

    public init(
        schemaVersion: Int,
        catalogRevision: String,
        generatedAt: String,
        sourceRevision: String? = nil,
        providerCount: Int,
        productCount: Int,
        modelCount: Int,
        sha256: String
    ) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.generatedAt = generatedAt
        self.sourceRevision = sourceRevision
        self.providerCount = providerCount
        self.productCount = productCount
        self.modelCount = modelCount
        self.sha256 = sha256
    }
}

// MARK: - Lenient discovery strategy decoding

public extension ModelDiscoveryStrategy {
    /// Decodes a strategy string the client may not know yet. An unrecognised
    /// value falls back to the product's declared behavior rather than failing
    /// the whole catalog decode.
    init(lenient raw: String) {
        switch raw {
        case "static", "staticCatalog": self = .staticCatalog
        case "apiModels", "endpoint": self = .endpoint
        case "authenticatedRemote": self = .authenticatedRemote
        case "local": self = .local
        case "custom": self = .custom
        default: self = .custom
        }
    }
}
