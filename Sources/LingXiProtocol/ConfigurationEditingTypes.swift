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
    case clear
}

// MARK: - Providers

/// Editable fields of one model under a provider.
public struct ProviderModelConfigurationDetail: Codable, Sendable, Equatable, Identifiable {
    public var modelID: String
    public var name: String
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

    public var id: String { modelID }

    public init(
        modelID: String,
        name: String,
        contextWindow: Int,
        maxOutputTokens: Int,
        reasoning: Bool = false,
        toolCalling: Bool = true,
        parallelToolCalling: Bool = true,
        vision: Bool = false,
        structuredOutput: Bool = false,
        tokensPerMinute: Int? = nil,
        requestsPerMinute: Int? = nil,
        maxConcurrentRequests: Int? = nil,
        maxRetries: Int = 5,
        initialRetryDelayMilliseconds: Int = 2_000,
        maxRetryDelayMilliseconds: Int = 30_000,
        retryJitterRatio: Double = 0.25
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
