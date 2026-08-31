import Foundation
import LingXiProtocol

extension ProviderWire {
    var modelWireProtocol: ModelWireProtocol? {
        switch self {
        case .openAIChatCompletions, .openAICompatible: .chatCompletions
        case .openAIResponses: .responses
        case .anthropicMessages: .anthropicMessages
        case .providerNative: nil
        }
    }
}

extension ProviderVerificationStatus {
    var isRuntimeVerified: Bool { self == .verified }
}

public struct ModelLimits: Codable, Sendable, Equatable {
    public let contextWindow: Int?
    public let maxOutputTokens: Int?

    public init(contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ModelProfile: Codable, Sendable, Equatable {
    public let productID: ProviderProductID
    public let providerModelID: String
    public let compatibleEndpointIDs: [ProviderEndpointID]
    public let limits: ModelLimits
    public let capabilities: ModelCapabilities
    public let catalogSource: ModelCatalogSource
    public let verificationStatus: ProviderVerificationStatus

    public init(
        productID: ProviderProductID,
        providerModelID: String,
        compatibleEndpointIDs: [ProviderEndpointID],
        limits: ModelLimits = ModelLimits(),
        capabilities: ModelCapabilities = ModelCapabilities(),
        catalogSource: ModelCatalogSource,
        verificationStatus: ProviderVerificationStatus
    ) {
        self.productID = productID
        self.providerModelID = providerModelID
        self.compatibleEndpointIDs = compatibleEndpointIDs
        self.limits = limits
        self.capabilities = capabilities
        self.catalogSource = catalogSource
        self.verificationStatus = verificationStatus
    }
}

public struct ProviderProductEndpoint: Sendable, Equatable {
    public let id: ProviderEndpointID
    public let baseURL: URL?
    public let wire: ProviderWire
    public let requestAuthentication: RequestAuthentication
    public let requiredHeaders: [String: String]
    public let allowsEndpointOverride: Bool
    public let catalogSource: ModelCatalogSource
    public let verificationStatus: ProviderVerificationStatus

    public init(
        id: ProviderEndpointID,
        baseURL: URL? = nil,
        wire: ProviderWire,
        requestAuthentication: RequestAuthentication,
        requiredHeaders: [String: String] = [:],
        allowsEndpointOverride: Bool = false,
        catalogSource: ModelCatalogSource = .officialStaticCatalog,
        verificationStatus: ProviderVerificationStatus
    ) {
        self.id = id
        self.baseURL = baseURL
        self.wire = wire
        self.requestAuthentication = requestAuthentication
        self.requiredHeaders = requiredHeaders
        self.allowsEndpointOverride = allowsEndpointOverride
        self.catalogSource = catalogSource
        self.verificationStatus = verificationStatus
    }
}

public struct ProviderProductDefinition: Sendable, Equatable {
    public let id: ProviderProductID
    public let vendorID: VendorID
    public let displayName: String
    public let type: ProviderProductType
    public let accountTypes: [ProviderAccountType]
    public let endpoints: [ProviderProductEndpoint]
    public let verificationStatus: ProviderVerificationStatus
    public let officialSources: [URL]
    public let requiredAccountFields: [String]

    public init(
        id: ProviderProductID,
        vendorID: VendorID,
        displayName: String,
        type: ProviderProductType,
        accountTypes: [ProviderAccountType],
        endpoints: [ProviderProductEndpoint] = [],
        verificationStatus: ProviderVerificationStatus,
        officialSources: [URL] = [],
        requiredAccountFields: [String] = []
    ) {
        self.id = id
        self.vendorID = vendorID
        self.displayName = displayName
        self.type = type
        self.accountTypes = accountTypes
        self.endpoints = endpoints
        self.verificationStatus = verificationStatus
        self.officialSources = officialSources
        self.requiredAccountFields = requiredAccountFields
    }

    public func endpoint(id: ProviderEndpointID) -> ProviderProductEndpoint? {
        endpoints.first { $0.id == id }
    }

    public var isRuntimeResolvable: Bool {
        verificationStatus.isRuntimeVerified && endpoints.contains { $0.verificationStatus.isRuntimeVerified }
    }
}

public struct ProviderAccount: Codable, Sendable, Equatable {
    public let id: String
    public let productID: ProviderProductID
    public let type: ProviderAccountType
    public let credential: CredentialRef?

    public init(id: String, productID: ProviderProductID, type: ProviderAccountType, credential: CredentialRef?) {
        self.id = id
        self.productID = productID
        self.type = type
        self.credential = credential
    }
}

public protocol OAuthAuthorizationProvider: Sendable {
    func authorize() async throws
}

public struct OAuthCredential: Codable, Sendable, Equatable {
    public let accessCredential: CredentialRef
    public let refreshCredential: CredentialRef?
    public let expiresAt: Date?
}

public struct OAuthRefreshResult: Sendable, Equatable {
    public let credential: OAuthCredential
}

public struct ModelCatalogEntry: Sendable, Equatable {
    public let profile: ModelProfile
    public let endpointID: ProviderEndpointID?

    public init(profile: ModelProfile, endpointID: ProviderEndpointID? = nil) {
        self.profile = profile
        self.endpointID = endpointID
    }
}

public protocol ModelCatalogDiscovery: Sendable {
    func discoverModels() async throws -> [ModelCatalogEntry]
}

public enum ProviderResolutionError: Error, Sendable, Equatable {
    case providerProductUnverified(ProviderProductID)
    case providerEndpointUnverified(ProviderEndpointID)
    case providerWireUnsupported(ProviderWire)
    case modelProfileIncomplete(String)
    case authenticationUnsupported(RequestAuthentication)
}
