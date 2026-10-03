import Foundation

public struct VendorID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public struct ProviderProductID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public struct ProviderEndpointID: RawRepresentable, Codable, Sendable, Equatable, Hashable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }; public init(_ value: String) { rawValue = value } }
public enum RequestAuthentication: Sendable, Equatable { case none, bearerToken, apiKeyHeader(name: String), oauthAccessToken, workloadIdentityToken, gatewayToken, customHeaderSet, providerNative }
public enum ProviderWire: String, Codable, Sendable, Equatable { case openAIChatCompletions, openAIResponses, anthropicMessages, openAICompatible, providerNative }
public enum ModelCatalogSource: String, Codable, Sendable, Equatable { case officialAPI, officialStaticCatalog, gatewayCatalog, localRuntime, userConfiguration, unavailable }
public enum ModelDiscoveryStrategy: String, Codable, Sendable, Equatable {
    case staticCatalog = "static"
    case endpoint = "endpoint"
    case authenticatedRemote = "authenticatedRemote"
    case local = "local"
    case custom = "custom"
}
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

/// Credential and connectivity state Core actually observes for an account.
///
/// A front end renders these cases instead of pattern-matching on a string, so
/// an unrecognised value is reported as such rather than guessed at.
public enum ProviderAccountAvailability: String, Codable, Sendable, Equatable {
    case configured
    case active
    case refreshing
    case refreshFailedTransient = "refresh_failed"
    case reauthenticationRequired
    case unavailable
    /// A value this build does not know: shown as unknown, never mapped onto a
    /// nearby state.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderAccountAvailability(rawValue: raw) ?? .unknown
    }
}

public struct ProviderAccountInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let productID: String
    public let displayName: String
    public let accountType: ProviderAccountType
    public let credentialRef: CredentialRef?
    public let endpoint: String?
    public let availability: ProviderAccountAvailability
    public init(id: String, productID: String, displayName: String, accountType: ProviderAccountType, credentialRef: CredentialRef?, endpoint: String?, availability: ProviderAccountAvailability) {
        self.id = id; self.productID = productID; self.displayName = displayName; self.accountType = accountType; self.credentialRef = credentialRef; self.endpoint = endpoint; self.availability = availability
    }
}

/// Whether one model is actually usable on the account behind a provider.
///
/// `/v1/models` cannot answer this: an endpoint happily lists models the token plan excludes, and the
/// user meets that as a 403 in the middle of a conversation. Only a real turn reaches the truth.
public enum ModelAvailability: String, Codable, Sendable, Equatable {
    /// The request reached the model.
    case available
    /// Upstream said this model is not offered here: excluded by the plan, or not a name it knows.
    case unavailable
    /// Nothing was learned. Never demote a model on this.
    case unknown
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
    public let metadataIncomplete: Bool
    public let canonicalModelID: String?
    public let backendVariant: String?
    public let backendVariants: [String]?
    public let vision: Bool
    public let toolCalling: Bool
    /// nil until something has actually probed this model. Absent is not the same as available: a
    /// model nobody has tried yet must not read as verified.
    public let availability: ModelAvailability?
    /// What the model's reasoning control actually offers. Nil when only the `reasoning` flag is
    /// known; a toggle model reports exactly Off and On.
    public let reasoningCapability: ReasoningCapability?
    /// The most the weights can address (a local runtime's `max_context_length`). Shown beside,
    /// never instead of, `contextWindow`.
    public let modelMaximumContextWindow: Int?
    /// Set only when `contextWindow` came from a running local runtime's loaded instance.
    public let runtimeContextWindow: Int?

    public init(
        id: String,
        providerID: String,
        modelID: String,
        displayName: String,
        contextWindow: Int,
        maxOutputTokens: Int,
        reasoning: Bool,
        configured: Bool,
        metadataIncomplete: Bool = false,
        canonicalModelID: String? = nil,
        backendVariant: String? = nil,
        backendVariants: [String]? = nil,
        vision: Bool = false,
        toolCalling: Bool = true,
        availability: ModelAvailability? = nil,
        reasoningCapability: ReasoningCapability? = nil,
        modelMaximumContextWindow: Int? = nil,
        runtimeContextWindow: Int? = nil
    ) {
        self.reasoningCapability = reasoningCapability
        self.modelMaximumContextWindow = modelMaximumContextWindow
        self.runtimeContextWindow = runtimeContextWindow
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.configured = configured
        self.metadataIncomplete = metadataIncomplete
        self.canonicalModelID = canonicalModelID
        self.backendVariant = backendVariant
        self.backendVariants = backendVariants
        self.vision = vision
        self.toolCalling = toolCalling
        self.availability = availability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.contextWindow = try container.decode(Int.self, forKey: .contextWindow)
        self.maxOutputTokens = try container.decode(Int.self, forKey: .maxOutputTokens)
        self.reasoning = try container.decode(Bool.self, forKey: .reasoning)
        self.configured = try container.decode(Bool.self, forKey: .configured)
        self.metadataIncomplete = try container.decodeIfPresent(Bool.self, forKey: .metadataIncomplete) ?? false
        self.canonicalModelID = try container.decodeIfPresent(String.self, forKey: .canonicalModelID)
        self.backendVariant = try container.decodeIfPresent(String.self, forKey: .backendVariant)
        self.backendVariants = try container.decodeIfPresent([String].self, forKey: .backendVariants)
        self.vision = try container.decodeIfPresent(Bool.self, forKey: .vision) ?? false
        self.toolCalling = try container.decodeIfPresent(Bool.self, forKey: .toolCalling) ?? true
        self.availability = try container.decodeIfPresent(ModelAvailability.self, forKey: .availability)
        self.reasoningCapability = try container.decodeIfPresent(ReasoningCapability.self, forKey: .reasoningCapability)
        self.modelMaximumContextWindow = try container.decodeIfPresent(Int.self, forKey: .modelMaximumContextWindow)
        self.runtimeContextWindow = try container.decodeIfPresent(Int.self, forKey: .runtimeContextWindow)
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
