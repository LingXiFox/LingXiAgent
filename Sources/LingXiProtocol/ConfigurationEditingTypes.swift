import Foundation

// Front-end editing contract for `providers.json` and `mcp.json`.
//
// Secrets travel front-end → Core exactly once, inside a `SecretUpdate.replace`,
// and are stored by Core in the credential vault. Core never sends a secret
// back: reads only report whether one is stored and where it comes from.

/// How a stored secret is supplied.
public enum SecretSource: Codable, Sendable, Equatable {
    /// No secret configured.
    case none
    /// Stored in the Core credential vault.
    case vault
    /// Read from an environment variable at runtime.
    case environment(name: String)
}

/// Change to a secret field; `keep` leaves the stored value untouched.
public enum SecretUpdate: Codable, Sendable, Equatable {
    case keep
    case replace(String)
    /// Adopt a secret the front end already wrote to Core's vault (a staged
    /// credential reference), so the plaintext is sent exactly once.
    case staged(reference: CredentialRef)
    case clear
}

/// Tests a connection that is not saved yet. The secret is referenced, never
/// carried: the front end stages it with `credential.store` first.
public struct TestProviderDraftRequest: Codable, Sendable, Equatable {
    public var adapter: String
    public var baseURL: String
    public var apiKeyHeader: String?
    public var headers: [String: String]
    public var credentialRef: CredentialRef?

    public init(adapter: String, baseURL: String, apiKeyHeader: String? = nil,
                headers: [String: String] = [:], credentialRef: CredentialRef? = nil) {
        self.adapter = adapter
        self.baseURL = baseURL
        self.apiKeyHeader = apiKeyHeader
        self.headers = headers
        self.credentialRef = credentialRef
    }
}

// MARK: - Providers

/// The value the model catalog publishes for one field, if it publishes one.
///
/// This is the read-only bottom layer of `catalog → override → effective`.
/// A `nil` here means the catalog states nothing about the field, which is not
/// the same as a catalog value of `false` or `0`.
public struct ProviderModelCatalogDefaults: Codable, Sendable, Equatable {
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var reasoning: Bool?
    public var toolCalling: Bool?
    public var parallelToolCalling: Bool?
    public var vision: Bool?
    public var structuredOutput: Bool?
    public var tokensPerMinute: Int?
    public var requestsPerMinute: Int?
    public var maxConcurrentRequests: Int?
    public var maxRetries: Int?
    public var initialRetryDelayMilliseconds: Int?
    public var maxRetryDelayMilliseconds: Int?
    public var retryJitterRatio: Double?

    public init(contextWindow: Int? = nil, maxOutputTokens: Int? = nil, reasoning: Bool? = nil,
                toolCalling: Bool? = nil, parallelToolCalling: Bool? = nil, vision: Bool? = nil,
                structuredOutput: Bool? = nil, tokensPerMinute: Int? = nil, requestsPerMinute: Int? = nil,
                maxConcurrentRequests: Int? = nil, maxRetries: Int? = nil,
                initialRetryDelayMilliseconds: Int? = nil, maxRetryDelayMilliseconds: Int? = nil,
                retryJitterRatio: Double? = nil) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.tokensPerMinute = tokensPerMinute
        self.requestsPerMinute = requestsPerMinute
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxRetries = maxRetries
        self.initialRetryDelayMilliseconds = initialRetryDelayMilliseconds
        self.maxRetryDelayMilliseconds = maxRetryDelayMilliseconds
        self.retryJitterRatio = retryJitterRatio
    }

    /// True when no source describes this model, so the row reads 「元数据待同步」.
    public var isEmpty: Bool {
        contextWindow == nil && maxOutputTokens == nil && reasoning == nil && toolCalling == nil
            && parallelToolCalling == nil && vision == nil && structuredOutput == nil
            && tokensPerMinute == nil && requestsPerMinute == nil && maxConcurrentRequests == nil
            && maxRetries == nil && initialRetryDelayMilliseconds == nil
            && maxRetryDelayMilliseconds == nil && retryJitterRatio == nil
    }

    /// What Core uses when the user has overridden nothing: the catalog value,
    /// or a last-resort default where no catalog states the field.
    public func effectiveOrDefaults() -> ProviderModelEffectiveValues {
        ProviderModelEffectiveValues(
            contextWindow: contextWindow ?? ProviderModelDefaults.contextWindow,
            maxOutputTokens: maxOutputTokens ?? ProviderModelDefaults.maxOutputTokens,
            reasoning: reasoning ?? ProviderModelDefaults.reasoning,
            toolCalling: toolCalling ?? ProviderModelDefaults.toolCalling,
            parallelToolCalling: parallelToolCalling ?? ProviderModelDefaults.parallelToolCalling,
            vision: vision ?? ProviderModelDefaults.vision,
            structuredOutput: structuredOutput ?? ProviderModelDefaults.structuredOutput,
            tokensPerMinute: tokensPerMinute,
            requestsPerMinute: requestsPerMinute,
            maxConcurrentRequests: maxConcurrentRequests,
            maxRetries: maxRetries ?? ProviderModelDefaults.maxRetries,
            initialRetryDelayMilliseconds: initialRetryDelayMilliseconds
                ?? ProviderModelDefaults.initialRetryDelayMilliseconds,
            maxRetryDelayMilliseconds: maxRetryDelayMilliseconds
                ?? ProviderModelDefaults.maxRetryDelayMilliseconds,
            retryJitterRatio: retryJitterRatio ?? ProviderModelDefaults.retryJitterRatio)
    }
}

/// Core's last-resort values, used only when neither the user nor the model
/// catalog states a field. They are a fallback for a runtime that needs a
/// number, not a claim about the model.
public enum ProviderModelDefaults {
    public static let contextWindow = 128_000
    public static let maxOutputTokens = 4_096
    public static let reasoning = false
    public static let toolCalling = true
    public static let parallelToolCalling = true
    public static let vision = false
    public static let structuredOutput = false
    public static let maxRetries = 5
    public static let initialRetryDelayMilliseconds = 2_000
    public static let maxRetryDelayMilliseconds = 30_000
    public static let retryJitterRatio = 0.25
}

/// The value Core will actually use, already resolved from override → catalog
/// default → last-resort default. The GUI must not recompute this.
public struct ProviderModelEffectiveValues: Codable, Sendable, Equatable {
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var reasoning: Bool
    public var toolCalling: Bool
    public var parallelToolCalling: Bool
    public var vision: Bool
    public var structuredOutput: Bool
    public var tokensPerMinute: Int?
    public var requestsPerMinute: Int?
    public var maxConcurrentRequests: Int?
    public var maxRetries: Int
    public var initialRetryDelayMilliseconds: Int
    public var maxRetryDelayMilliseconds: Int
    public var retryJitterRatio: Double

    public init(contextWindow: Int, maxOutputTokens: Int, reasoning: Bool, toolCalling: Bool,
                parallelToolCalling: Bool, vision: Bool, structuredOutput: Bool,
                tokensPerMinute: Int?, requestsPerMinute: Int?, maxConcurrentRequests: Int?,
                maxRetries: Int, initialRetryDelayMilliseconds: Int, maxRetryDelayMilliseconds: Int,
                retryJitterRatio: Double) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.tokensPerMinute = tokensPerMinute
        self.requestsPerMinute = requestsPerMinute
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxRetries = maxRetries
        self.initialRetryDelayMilliseconds = initialRetryDelayMilliseconds
        self.maxRetryDelayMilliseconds = maxRetryDelayMilliseconds
        self.retryJitterRatio = retryJitterRatio
    }
}

/// Editable fields of one model under a provider.
///
/// Every overridable field is optional and `nil` means "the user never
/// overrode this field" — the stored file omits the key entirely, so a later
/// catalog update still reaches the model. `catalogDefaults` and `effective`
/// carry the other two layers; a front end must never infer override state by
/// comparing values.
public struct ProviderModelConfigurationDetail: Codable, Sendable, Equatable, Identifiable {
    public var modelID: String
    public var name: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var reasoning: Bool?
    public var toolCalling: Bool?
    public var parallelToolCalling: Bool?
    public var vision: Bool?
    public var structuredOutput: Bool?
    public var tokensPerMinute: Int?
    public var requestsPerMinute: Int?
    public var maxConcurrentRequests: Int?
    public var maxRetries: Int?
    public var initialRetryDelayMilliseconds: Int?
    public var maxRetryDelayMilliseconds: Int?
    public var retryJitterRatio: Double?
    public var catalogDefaults: ProviderModelCatalogDefaults
    public var effective: ProviderModelEffectiveValues

    public var id: String { modelID }

    /// True when the user has overridden this model in at least one field.
    public var isCustomized: Bool {
        contextWindow != nil || maxOutputTokens != nil || reasoning != nil || toolCalling != nil
            || parallelToolCalling != nil || vision != nil || structuredOutput != nil
            || tokensPerMinute != nil || requestsPerMinute != nil || maxConcurrentRequests != nil
            || maxRetries != nil || initialRetryDelayMilliseconds != nil
            || maxRetryDelayMilliseconds != nil || retryJitterRatio != nil
    }

    public init(
        modelID: String,
        name: String,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoning: Bool? = nil,
        toolCalling: Bool? = nil,
        parallelToolCalling: Bool? = nil,
        vision: Bool? = nil,
        structuredOutput: Bool? = nil,
        tokensPerMinute: Int? = nil,
        requestsPerMinute: Int? = nil,
        maxConcurrentRequests: Int? = nil,
        maxRetries: Int? = nil,
        initialRetryDelayMilliseconds: Int? = nil,
        maxRetryDelayMilliseconds: Int? = nil,
        retryJitterRatio: Double? = nil,
        catalogDefaults: ProviderModelCatalogDefaults = ProviderModelCatalogDefaults(),
        effective: ProviderModelEffectiveValues? = nil
    ) {
        self.modelID = modelID
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.tokensPerMinute = tokensPerMinute
        self.requestsPerMinute = requestsPerMinute
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxRetries = maxRetries
        self.initialRetryDelayMilliseconds = initialRetryDelayMilliseconds
        self.maxRetryDelayMilliseconds = maxRetryDelayMilliseconds
        self.retryJitterRatio = retryJitterRatio
        self.catalogDefaults = catalogDefaults
        self.effective = effective ?? Self.resolveEffective(
            contextWindow: contextWindow, maxOutputTokens: maxOutputTokens, reasoning: reasoning,
            toolCalling: toolCalling, parallelToolCalling: parallelToolCalling, vision: vision,
            structuredOutput: structuredOutput, tokensPerMinute: tokensPerMinute,
            requestsPerMinute: requestsPerMinute, maxConcurrentRequests: maxConcurrentRequests,
            maxRetries: maxRetries, initialRetryDelayMilliseconds: initialRetryDelayMilliseconds,
            maxRetryDelayMilliseconds: maxRetryDelayMilliseconds, retryJitterRatio: retryJitterRatio,
            defaults: catalogDefaults)
    }

    private static func resolveEffective(
        contextWindow: Int?, maxOutputTokens: Int?, reasoning: Bool?, toolCalling: Bool?,
        parallelToolCalling: Bool?, vision: Bool?, structuredOutput: Bool?, tokensPerMinute: Int?,
        requestsPerMinute: Int?, maxConcurrentRequests: Int?, maxRetries: Int?,
        initialRetryDelayMilliseconds: Int?, maxRetryDelayMilliseconds: Int?,
        retryJitterRatio: Double?, defaults: ProviderModelCatalogDefaults
    ) -> ProviderModelEffectiveValues {
        let base = defaults.effectiveOrDefaults()
        return ProviderModelEffectiveValues(
            contextWindow: contextWindow ?? base.contextWindow,
            maxOutputTokens: maxOutputTokens ?? base.maxOutputTokens,
            reasoning: reasoning ?? base.reasoning,
            toolCalling: toolCalling ?? base.toolCalling,
            parallelToolCalling: parallelToolCalling ?? base.parallelToolCalling,
            vision: vision ?? base.vision,
            structuredOutput: structuredOutput ?? base.structuredOutput,
            tokensPerMinute: tokensPerMinute ?? base.tokensPerMinute,
            requestsPerMinute: requestsPerMinute ?? base.requestsPerMinute,
            maxConcurrentRequests: maxConcurrentRequests ?? base.maxConcurrentRequests,
            maxRetries: maxRetries ?? base.maxRetries,
            initialRetryDelayMilliseconds: initialRetryDelayMilliseconds
                ?? base.initialRetryDelayMilliseconds,
            maxRetryDelayMilliseconds: maxRetryDelayMilliseconds ?? base.maxRetryDelayMilliseconds,
            retryJitterRatio: retryJitterRatio ?? base.retryJitterRatio
        )
    }
}

/// One provider entry of `providers.json`, as the settings form sees it.
public struct ProviderConfigurationDetail: Codable, Sendable, Equatable, Identifiable {
    public var providerID: String
    public var name: String
    /// `openai-compatible` · `openai-responses` · `anthropic-messages`
    public var adapter: String
    public var baseURL: String
    public var apiKeyHeader: String?
    public var headers: [String: String]
    public var apiKey: SecretSource
    public var models: [ProviderModelConfigurationDetail]

    public var id: String { providerID }

    public init(providerID: String, name: String, adapter: String, baseURL: String,
                apiKeyHeader: String? = nil, headers: [String: String] = [:],
                apiKey: SecretSource = .none, models: [ProviderModelConfigurationDetail] = []) {
        self.providerID = providerID
        self.name = name
        self.adapter = adapter
        self.baseURL = baseURL
        self.apiKeyHeader = apiKeyHeader
        self.headers = headers
        self.apiKey = apiKey
        self.models = models
    }
}

public struct GetProviderConfigurationRequest: Codable, Sendable, Equatable {
    public let providerID: String
    public init(providerID: String) { self.providerID = providerID }
}

/// Creates or replaces a provider entry. `models: nil` keeps the stored models.
public struct SaveProviderConfigurationRequest: Codable, Sendable, Equatable {
    public var providerID: String
    public var name: String
    public var adapter: String
    public var baseURL: String
    public var apiKeyHeader: String?
    public var headers: [String: String]
    public var apiKey: SecretUpdate
    public var models: [ProviderModelConfigurationDetail]?

    public init(providerID: String, name: String, adapter: String, baseURL: String,
                apiKeyHeader: String? = nil, headers: [String: String] = [:],
                apiKey: SecretUpdate = .keep, models: [ProviderModelConfigurationDetail]? = nil) {
        self.providerID = providerID
        self.name = name
        self.adapter = adapter
        self.baseURL = baseURL
        self.apiKeyHeader = apiKeyHeader
        self.headers = headers
        self.apiKey = apiKey
        self.models = models
    }
}

public struct DeleteProviderConfigurationRequest: Codable, Sendable, Equatable {
    public let providerID: String
    /// Also remove the vault secret the entry referenced.
    public let deleteCredential: Bool
    public init(providerID: String, deleteCredential: Bool = true) {
        self.providerID = providerID
        self.deleteCredential = deleteCredential
    }
}

// MARK: - MCP

public enum MCPServerTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case stdio, streamableHTTP
}

public enum MCPServerProtocolPreference: String, Codable, Sendable, Equatable, CaseIterable {
    case auto, modern, legacy
}

public enum MCPAuthenticationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case none, bearer, header
}

/// One environment variable of a stdio server. Values are secrets.
public struct MCPEnvironmentVariableDetail: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var value: SecretSource
    public var id: String { name }
    public init(name: String, value: SecretSource) {
        self.name = name
        self.value = value
    }
}

public struct MCPEnvironmentVariableUpdate: Codable, Sendable, Equatable {
    public var name: String
    public var value: SecretUpdate
    public init(name: String, value: SecretUpdate) {
        self.name = name
        self.value = value
    }
}

/// One server of `mcp.json`, as the settings form sees it.
public struct MCPServerConfigurationDetail: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var alias: String
    public var transport: MCPServerTransport
    public var command: String?
    public var arguments: [String]
    public var endpoint: String?
    public var protocolPreference: MCPServerProtocolPreference
    public var enabled: Bool
    public var authentication: MCPAuthenticationKind
    public var headerName: String?
    public var credential: SecretSource
    public var environment: [MCPEnvironmentVariableDetail]
    public var timeoutSeconds: Double

    public init(id: String, alias: String, transport: MCPServerTransport, command: String? = nil,
                arguments: [String] = [], endpoint: String? = nil,
                protocolPreference: MCPServerProtocolPreference = .auto, enabled: Bool = true,
                authentication: MCPAuthenticationKind = .none, headerName: String? = nil,
                credential: SecretSource = .none, environment: [MCPEnvironmentVariableDetail] = [],
                timeoutSeconds: Double = 60) {
        self.id = id
        self.alias = alias
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.endpoint = endpoint
        self.protocolPreference = protocolPreference
        self.enabled = enabled
        self.authentication = authentication
        self.headerName = headerName
        self.credential = credential
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Creates or replaces a server. Environment variables not listed are removed.
public struct SaveMCPServerRequest: Codable, Sendable, Equatable {
    public var id: String
    public var alias: String
    public var transport: MCPServerTransport
    public var command: String?
    public var arguments: [String]
    public var endpoint: String?
    public var protocolPreference: MCPServerProtocolPreference
    public var enabled: Bool
    public var authentication: MCPAuthenticationKind
    public var headerName: String?
    public var credential: SecretUpdate
    public var environment: [MCPEnvironmentVariableUpdate]
    public var timeoutSeconds: Double

    public init(id: String, alias: String, transport: MCPServerTransport, command: String? = nil,
                arguments: [String] = [], endpoint: String? = nil,
                protocolPreference: MCPServerProtocolPreference = .auto, enabled: Bool = true,
                authentication: MCPAuthenticationKind = .none, headerName: String? = nil,
                credential: SecretUpdate = .keep, environment: [MCPEnvironmentVariableUpdate] = [],
                timeoutSeconds: Double = 60) {
        self.id = id
        self.alias = alias
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.endpoint = endpoint
        self.protocolPreference = protocolPreference
        self.enabled = enabled
        self.authentication = authentication
        self.headerName = headerName
        self.credential = credential
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct DeleteMCPServerRequest: Codable, Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}
