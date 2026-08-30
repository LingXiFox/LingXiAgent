import Foundation

public enum ConfigurationSchemaURI {
    public static let core = "https://schemas.example.invalid/lingxiagent/config.schema.json"
    public static let providers = "https://schemas.example.invalid/lingxiagent/providers.schema.json"
    public static let mcp = "https://schemas.example.invalid/lingxiagent/mcp.schema.json"
    public static let plugins = "https://schemas.example.invalid/lingxiagent/plugins.schema.json"
}

public enum ConfigurationFormat {
    public static let currentVersion = 1
}

public struct CredentialRef: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConfigurationLogLevel: String, Codable, Sendable, Equatable {
    case debug, info, warning, error
}

public struct CoreSettings: Codable, Sendable, Equatable {
    public var locale: String
    public var logLevel: ConfigurationLogLevel

    public init(locale: String = "system", logLevel: ConfigurationLogLevel = .info) {
        self.locale = locale
        self.logLevel = logLevel
    }
}

public struct AgentSettings: Codable, Sendable, Equatable {
    public var maxConcurrentSubagents: Int
    public var maxSubagentDepth: Int
    public var maxTotalRunsPerRootRun: Int

    public init(maxConcurrentSubagents: Int = 4, maxSubagentDepth: Int = 3, maxTotalRunsPerRootRun: Int = 32) {
        self.maxConcurrentSubagents = maxConcurrentSubagents
        self.maxSubagentDepth = maxSubagentDepth
        self.maxTotalRunsPerRootRun = maxTotalRunsPerRootRun
    }
}

public struct RuntimeSettings: Codable, Sendable, Equatable {
    public var interactive: Bool
    public var commandTimeoutSeconds: Double

    public init(interactive: Bool = false, commandTimeoutSeconds: Double = 60) {
        self.interactive = interactive
        self.commandTimeoutSeconds = commandTimeoutSeconds
    }
}

public struct CoreConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var core: CoreSettings
    public var agent: AgentSettings
    public var runtime: RuntimeSettings

    public init(
        schema: String = ConfigurationSchemaURI.core,
        version: Int = ConfigurationFormat.currentVersion,
        core: CoreSettings = CoreSettings(),
        agent: AgentSettings = AgentSettings(),
        runtime: RuntimeSettings = RuntimeSettings()
    ) {
        self.schema = schema
        self.version = version
        self.core = core
        self.agent = agent
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, core, agent, runtime
    }
}

public enum StoredProviderWireProtocol: String, Codable, Sendable, Equatable {
    case chatCompletions, responses, anthropicMessages
}

public enum StoredProviderAuthenticationKind: String, Codable, Sendable, Equatable {
    case none, bearer, header
}

public struct ProviderAccountConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var providerID: String
    public var displayName: String
    public var enabled: Bool
    public var authentication: StoredProviderAuthenticationKind
    public var headerName: String?
    public var credential: CredentialRef?
    public var endpointOverride: String?
    public var configOverrides: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        providerID: String,
        displayName: String,
        enabled: Bool = true,
        authentication: StoredProviderAuthenticationKind = .none,
        headerName: String? = nil,
        credential: CredentialRef? = nil,
        endpointOverride: String? = nil,
        configOverrides: [String: String] = [:],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.enabled = enabled
        self.authentication = authentication
        self.headerName = headerName
        self.credential = credential
        self.endpointOverride = endpointOverride
        self.configOverrides = configOverrides
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ModelCapabilitiesConfiguration: Codable, Sendable, Equatable {
    public var toolCalling: Bool
    public var parallelToolCalling: Bool
    public var reasoning: Bool
    public var vision: Bool
    public var structuredOutput: Bool

    public init(toolCalling: Bool = false, parallelToolCalling: Bool = false, reasoning: Bool = false, vision: Bool = false, structuredOutput: Bool = false) {
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.reasoning = reasoning
        self.vision = vision
        self.structuredOutput = structuredOutput
    }
}

public struct ModelProfileConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var providerID: String
    public var modelID: String
    public var displayName: String
    public var wireProtocol: StoredProviderWireProtocol
    public var contextWindow: Int
    public var maxOutputTokens: Int?
    public var capabilities: ModelCapabilitiesConfiguration
    public var remoteStateEnabled: Bool

    public init(
        id: String,
        providerID: String,
        modelID: String,
        displayName: String,
        wireProtocol: StoredProviderWireProtocol,
        contextWindow: Int,
        maxOutputTokens: Int? = nil,
        capabilities: ModelCapabilitiesConfiguration = ModelCapabilitiesConfiguration(),
        remoteStateEnabled: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.wireProtocol = wireProtocol
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.remoteStateEnabled = remoteStateEnabled
    }
}

public struct StoredModelSelection: Codable, Sendable, Equatable {
    public var accountID: String
    public var profileID: String

    public init(accountID: String, profileID: String) {
        self.accountID = accountID
        self.profileID = profileID
    }
}

public struct CustomProviderConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var baseURL: String

    public init(id: String, displayName: String, baseURL: String) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
    }
}

public struct ProvidersConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    /// Built-in providers belong to the runtime catalog and are never persisted here.
    public var customProviders: [CustomProviderConfiguration]
    public var accounts: [ProviderAccountConfiguration]
    public var modelProfiles: [ModelProfileConfiguration]
    public var defaultSelection: StoredModelSelection?

    public init(
        schema: String = ConfigurationSchemaURI.providers,
        version: Int = ConfigurationFormat.currentVersion,
        customProviders: [CustomProviderConfiguration] = [],
        accounts: [ProviderAccountConfiguration] = [],
        modelProfiles: [ModelProfileConfiguration] = [],
        defaultSelection: StoredModelSelection? = nil
    ) {
        self.schema = schema
        self.version = version
        self.customProviders = customProviders
        self.accounts = accounts
        self.modelProfiles = modelProfiles
        self.defaultSelection = defaultSelection
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, customProviders, accounts, modelProfiles, defaultSelection
    }
}

public enum StoredMCPTransport: String, Codable, Sendable, Equatable {
    case stdio, streamableHTTP
}

public enum StoredMCPProtocolPreference: String, Codable, Sendable, Equatable {
    case auto, modern, legacy
}

public enum StoredMCPAuthenticationKind: String, Codable, Sendable, Equatable {
    case none, bearer, header
}

public struct MCPAuthenticationConfiguration: Codable, Sendable, Equatable {
    public var kind: StoredMCPAuthenticationKind
    public var headerName: String?
    public var credential: CredentialRef?

    public init(kind: StoredMCPAuthenticationKind = .none, headerName: String? = nil, credential: CredentialRef? = nil) {
        self.kind = kind
        self.headerName = headerName
        self.credential = credential
    }
}

public struct MCPEnvironmentCredential: Codable, Sendable, Equatable {
    public var name: String
    public var credential: CredentialRef

    public init(name: String, credential: CredentialRef) {
        self.name = name
        self.credential = credential
    }
}

public struct StoredMCPServerConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var alias: String
    public var transport: StoredMCPTransport
    public var command: String?
    public var arguments: [String]
    public var endpoint: String?
    public var protocolPreference: StoredMCPProtocolPreference
    public var enabled: Bool
    public var authentication: MCPAuthenticationConfiguration
    public var environment: [MCPEnvironmentCredential]
    public var timeoutSeconds: Double

    public init(
        id: String,
        alias: String,
        transport: StoredMCPTransport,
        command: String? = nil,
        arguments: [String] = [],
        endpoint: String? = nil,
        protocolPreference: StoredMCPProtocolPreference = .auto,
        enabled: Bool = true,
        authentication: MCPAuthenticationConfiguration = MCPAuthenticationConfiguration(),
        environment: [MCPEnvironmentCredential] = [],
        timeoutSeconds: Double = 60
    ) {
        self.id = id
        self.alias = alias
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.endpoint = endpoint
        self.protocolPreference = protocolPreference
        self.enabled = enabled
        self.authentication = authentication
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct MCPConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var servers: [StoredMCPServerConfiguration]

    public init(schema: String = ConfigurationSchemaURI.mcp, version: Int = ConfigurationFormat.currentVersion, servers: [StoredMCPServerConfiguration] = []) {
        self.schema = schema
        self.version = version
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, servers
    }
}

/// Reserved persistence envelope. Plugin loading and execution are intentionally out of scope.
public struct PluginsConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int

    public init(schema: String = ConfigurationSchemaURI.plugins, version: Int = ConfigurationFormat.currentVersion) {
        self.schema = schema
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version
    }
}

public struct ConfigurationSnapshot: Sendable, Equatable {
    public var core: CoreConfiguration
    public var providers: ProvidersConfiguration
    public var mcp: MCPConfiguration
    public var plugins: PluginsConfiguration

    public init(core: CoreConfiguration, providers: ProvidersConfiguration, mcp: MCPConfiguration, plugins: PluginsConfiguration) {
        self.core = core
        self.providers = providers
        self.mcp = mcp
        self.plugins = plugins
    }
}
