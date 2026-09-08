import Foundation
import LingXiProtocol

extension ProviderWire {
    public var modelWireProtocol: ModelWireProtocol? {
        switch self {
        case .openAIChatCompletions, .openAICompatible: .chatCompletions
        case .openAIResponses: .responses
        case .anthropicMessages: .anthropicMessages
        case .providerNative: nil
        }
    }
}

extension ProviderVerificationStatus {
    public var isRuntimeVerified: Bool { self == .verified }
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
    case unknownProduct(String)
    case unknownModel(String)
    case invalidEndpointURL(String)
}

// MARK: - Provider Platform v2 Unified Configuration

public struct ResolvedProviderConfiguration: Sendable, Equatable {
    public let productID: String
    public let vendorID: String
    public let displayName: String
    public let endpoint: URL
    public let protocolFamily: ModelWireProtocol
    public let authStrategy: any AuthStrategy
    public let credentialRef: CredentialRef?
    public let requestProfile: OAuthRequestProfile?
    public let modelID: String
    public let modelDisplayName: String
    public let limits: ModelLimits
    public let capabilities: ModelCapabilities
    public let continuationPolicy: String?
    public let quirks: Set<String>

    public init(
        productID: String,
        vendorID: String,
        displayName: String,
        endpoint: URL,
        protocolFamily: ModelWireProtocol,
        authStrategy: any AuthStrategy,
        credentialRef: CredentialRef? = nil,
        requestProfile: OAuthRequestProfile? = nil,
        modelID: String,
        modelDisplayName: String,
        limits: ModelLimits = ModelLimits(),
        capabilities: ModelCapabilities = ModelCapabilities(),
        continuationPolicy: String? = nil,
        quirks: Set<String> = []
    ) {
        self.productID = productID
        self.vendorID = vendorID
        self.displayName = displayName
        self.endpoint = endpoint
        self.protocolFamily = protocolFamily
        self.authStrategy = authStrategy
        self.credentialRef = credentialRef
        self.requestProfile = requestProfile
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.limits = limits
        self.capabilities = capabilities
        self.continuationPolicy = continuationPolicy
        self.quirks = quirks
    }

    public static func == (lhs: ResolvedProviderConfiguration, rhs: ResolvedProviderConfiguration) -> Bool {
        lhs.productID == rhs.productID &&
        lhs.vendorID == rhs.vendorID &&
        lhs.displayName == rhs.displayName &&
        lhs.endpoint == rhs.endpoint &&
        lhs.protocolFamily == rhs.protocolFamily &&
        lhs.credentialRef == rhs.credentialRef &&
        lhs.requestProfile == rhs.requestProfile &&
        lhs.modelID == rhs.modelID &&
        lhs.modelDisplayName == rhs.modelDisplayName &&
        lhs.limits == rhs.limits &&
        lhs.capabilities == rhs.capabilities &&
        lhs.continuationPolicy == rhs.continuationPolicy &&
        lhs.quirks == rhs.quirks
    }
}

public enum ProviderResolver {
    public static func resolveBuiltin(
        productID: String,
        modelID: String,
        credentialRef: CredentialRef? = nil,
        secret: String? = nil,
        compatibilityMode: RequestCompatibilityMode = .conservative
    ) throws -> ResolvedProviderConfiguration {
        guard let product = BuiltinProviderCatalog.catalog?.products.first(where: { $0.id == productID })
                ?? BuiltinProviderCatalog.generatedProductsFallback.first(where: { $0.id == productID }) else {
            throw ProviderResolutionError.unknownProduct(productID)
        }

        guard let model = product.models.first(where: { $0.id == modelID }) else {
            throw ProviderResolutionError.unknownModel(modelID)
        }

        guard let endpointURL = URL(string: product.endpoint) else {
            throw ProviderResolutionError.invalidEndpointURL(product.endpoint)
        }

        let wireProto: ModelWireProtocol
        switch product.protocolFamily {
        case "openai_responses": wireProto = .responses
        case "anthropic_messages": wireProto = .anthropicMessages
        default: wireProto = .chatCompletions
        }

        let authStrategy: any AuthStrategy
        if product.authMethods.contains("none") {
            authStrategy = NoAuthStrategy()
        } else if let secret = secret, !secret.isEmpty {
            if product.protocolFamily == "anthropic_messages" {
                authStrategy = APIKeyHeaderAuthStrategy(headerName: "x-api-key", key: secret)
            } else if product.quirks.contains("customApiKeyHeader") {
                authStrategy = APIKeyHeaderAuthStrategy(headerName: "api-key", key: secret)
            } else {
                authStrategy = BearerAuthStrategy(token: secret)
            }
        } else {
            authStrategy = NoAuthStrategy()
        }

        var requestProfile: OAuthRequestProfile? = nil
        if let profConfig = product.requestProfiles.values.first {
            requestProfile = OAuthRequestProfile(
                id: profConfig.id,
                version: profConfig.version,
                compatibilityMode: compatibilityMode,
                endpointOverride: profConfig.endpointOverride.flatMap(URL.init(string:)),
                requiredHeaders: profConfig.requiredHeaders ?? [:],
                dynamicHeaders: profConfig.dynamicHeaders ?? [:],
                userAgentProfile: profConfig.userAgentProfile
            )
        }

        let limits = ModelLimits(contextWindow: model.contextWindow, maxOutputTokens: model.maxOutputTokens)
        let capabilities = ModelCapabilities(
            toolCalling: model.toolCalling,
            parallelToolCalling: model.parallelToolCalling,
            reasoning: model.reasoningCapability != nil,
            vision: model.vision,
            structuredOutput: model.structuredOutput,
            reasoningCapability: model.reasoningCapability
        )

        let continuationPolicy: String? = (wireProto == .responses) ? "responses_api" : nil

        return ResolvedProviderConfiguration(
            productID: product.id,
            vendorID: product.vendor,
            displayName: product.displayName,
            endpoint: endpointURL,
            protocolFamily: wireProto,
            authStrategy: authStrategy,
            credentialRef: credentialRef,
            requestProfile: requestProfile,
            modelID: model.id,
            modelDisplayName: model.displayName,
            limits: limits,
            capabilities: capabilities,
            continuationPolicy: continuationPolicy,
            quirks: Set(product.quirks)
        )
    }

    public static func resolveCustom(
        endpoint: URL,
        modelID: String,
        protocolFamily: ModelWireProtocol,
        apiKey: String? = nil,
        credentialRef: CredentialRef? = nil,
        customHeaders: [String: String] = [:]
    ) -> ResolvedProviderConfiguration {
        let authStrategy: any AuthStrategy
        if let key = apiKey, !key.isEmpty {
            if protocolFamily == .anthropicMessages {
                authStrategy = APIKeyHeaderAuthStrategy(headerName: "x-api-key", key: key)
            } else {
                authStrategy = BearerAuthStrategy(token: key)
            }
        } else {
            authStrategy = NoAuthStrategy()
        }

        let limits = ModelLimits(contextWindow: 128_000, maxOutputTokens: 4096)
        let capabilities = ModelCapabilities(toolCalling: true, parallelToolCalling: true, reasoning: false, vision: false, structuredOutput: true)

        return ResolvedProviderConfiguration(
            productID: "custom",
            vendorID: "custom",
            displayName: "Custom Provider",
            endpoint: endpoint,
            protocolFamily: protocolFamily,
            authStrategy: authStrategy,
            credentialRef: credentialRef,
            requestProfile: customHeaders.isEmpty ? nil : OAuthRequestProfile(id: "custom", version: "1.0", requiredHeaders: customHeaders),
            modelID: modelID,
            modelDisplayName: modelID,
            limits: limits,
            capabilities: capabilities,
            continuationPolicy: (protocolFamily == .responses) ? "responses_api" : nil,
            quirks: []
        )
    }
}
