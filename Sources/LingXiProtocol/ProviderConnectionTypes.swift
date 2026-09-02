import Foundation

public struct VendorID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public struct ProviderProductID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public struct ProviderEndpointID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public enum RequestAuthentication: Sendable, Equatable { case none, bearerToken, apiKeyHeader(name: String), oauthAccessToken, workloadIdentityToken, gatewayToken, customHeaderSet, providerNative }
public enum ProviderWire: String, Codable, Sendable, Equatable { case openAIChatCompletions, openAIResponses, anthropicMessages, openAICompatible, providerNative }
public enum ModelCatalogSource: String, Codable, Sendable, Equatable { case officialAPI, officialStaticCatalog, gatewayCatalog, localRuntime, userConfiguration, unavailable }
public enum ProviderAvailability: String, Codable, Sendable, Equatable { case configured, credentialPresent, endpointResolvable, modelResolvable, available, unavailable, unverified }

public struct CredentialRef: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

public enum ProviderProductType: String, Codable, Sendable, Equatable { case cloudAPI, gateway, subscription, localRuntime }
public enum ProviderAccountType: String, Codable, Sendable, Equatable { case apiKey, oauthUser, workloadIdentity, subscription, localInstance, gateway, anonymousLocal }
public enum ProviderRequestAuthentication: String, Codable, Sendable, Equatable { case none, bearerToken, apiKeyHeader, oauthAccessToken, workloadIdentityToken, gatewayToken, customHeaderSet, providerNative }
public enum ProviderStoredAuthentication: String, Codable, Sendable, Equatable { case none, bearer, header }
public enum ProviderVerificationStatus: String, Codable, Sendable, Equatable { case verified, partial, nonOfficialRunnableEvidence, unverified, unsupported }

public struct ProviderProductSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let vendorID: String
    public let type: ProviderProductType
    public let accountTypes: [ProviderAccountType]
    public let requestAuthentication: ProviderRequestAuthentication?
    public let requestAuthenticationHeaderName: String?
    public let requiresCredential: Bool
    public let requiresLocalEndpoint: Bool
    public let requiredAccountFields: [String]
    public let verificationStatus: ProviderVerificationStatus
    public let connectable: Bool
    public init(id: String, displayName: String, vendorID: String, type: ProviderProductType, accountTypes: [ProviderAccountType], requestAuthentication: ProviderRequestAuthentication?, requestAuthenticationHeaderName: String? = nil, requiresCredential: Bool, requiresLocalEndpoint: Bool, requiredAccountFields: [String] = [], verificationStatus: ProviderVerificationStatus, connectable: Bool) {
        self.id = id; self.displayName = displayName; self.vendorID = vendorID; self.type = type; self.accountTypes = accountTypes; self.requestAuthentication = requestAuthentication; self.requestAuthenticationHeaderName = requestAuthenticationHeaderName; self.requiresCredential = requiresCredential; self.requiresLocalEndpoint = requiresLocalEndpoint; self.requiredAccountFields = requiredAccountFields; self.verificationStatus = verificationStatus; self.connectable = connectable
    }
}

public struct ProviderAccountInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let productID: String
    public let displayName: String
    public let accountType: ProviderAccountType
    public let credentialRef: CredentialRef?
    public let endpoint: String?
    public let availability: String
    public init(id: String, productID: String, displayName: String, accountType: ProviderAccountType, credentialRef: CredentialRef?, endpoint: String?, availability: String) {
        self.id = id; self.productID = productID; self.displayName = displayName; self.accountType = accountType; self.credentialRef = credentialRef; self.endpoint = endpoint; self.availability = availability
    }
}

public struct ProviderModelInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let providerID: String
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int
    public let maxOutputTokens: Int
    public let reasoning: Bool
    public let configured: Bool

    public init(id: String, providerID: String, modelID: String, displayName: String, contextWindow: Int, maxOutputTokens: Int, reasoning: Bool, configured: Bool) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.configured = configured
    }
}

public struct ProviderAccountCreateRequest: Codable, Sendable, Equatable {
    public let id: String
    public let productID: String
    public let displayName: String
    public let accountType: ProviderAccountType
    public let credentialRef: CredentialRef?
    public let endpoint: String?
    public let authentication: ProviderStoredAuthentication
    public let headerName: String?
    public let fields: [String: String]
    public init(id: String, productID: String, displayName: String, accountType: ProviderAccountType, credentialRef: CredentialRef? = nil, endpoint: String? = nil, authentication: ProviderStoredAuthentication = .none, headerName: String? = nil, fields: [String: String] = [:]) {
        self.id = id; self.productID = productID; self.displayName = displayName; self.accountType = accountType; self.credentialRef = credentialRef; self.endpoint = endpoint; self.authentication = authentication; self.headerName = headerName; self.fields = fields
    }
}

public struct ProviderCredentialWriteRequest: Codable, Sendable, Equatable { public let secret: String; public init(secret: String) { self.secret = secret } }
public struct ProviderCredentialResult: Codable, Sendable, Equatable { public let reference: CredentialRef; public init(reference: CredentialRef) { self.reference = reference } }
public struct ProviderDisconnectResult: Codable, Sendable, Equatable { public let accountID: String; public let credentialDeleted: Bool; public init(accountID: String, credentialDeleted: Bool) { self.accountID = accountID; self.credentialDeleted = credentialDeleted } }
public struct OAuthAuthorizationRequest: Codable, Sendable, Equatable { public let authorizationURL: URL; public init(authorizationURL: URL) { self.authorizationURL = authorizationURL } }
public struct OAuthAuthorizationResult: Codable, Sendable, Equatable { public let callback: String; public init(callback: String) { self.callback = callback } }
public enum OAuthConnectionState: String, Codable, Sendable, Equatable { case unavailable, awaitingCallback, completed, failed }
