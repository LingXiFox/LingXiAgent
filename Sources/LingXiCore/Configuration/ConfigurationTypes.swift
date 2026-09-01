import Foundation
import LingXiProtocol

public typealias CredentialRef = LingXiProtocol.CredentialRef

public enum ConfigurationSchemaURI {
    public static let core = "https://schemas.example.invalid/lingxiagent/config.schema.json"
    public static let providers = "https://schemas.example.invalid/lingxiagent/providers.schema.json"
    public static let mcp = "https://schemas.example.invalid/lingxiagent/mcp.schema.json"
    public static let plugins = "https://schemas.example.invalid/lingxiagent/plugins.schema.json"
}

public enum ConfigurationFormat {
    public static let currentVersion = 1
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
    public var permissionPolicy: PermissionPolicy
    public var executionProfile: ExecutionProfile
    public var behaviorProfile: AgentBehaviorProfile?
    public var systemContext: String?
    public var l2MaxCharacters: Int
    public var l1ProjectMaxCharacters: Int
    public var preferredActiveTokens: Int?

    public init(maxConcurrentSubagents: Int = 4, maxSubagentDepth: Int = 3, maxTotalRunsPerRootRun: Int = 32, permissionPolicy: PermissionPolicy = .ask, executionProfile: ExecutionProfile = .workspace, behaviorProfile: AgentBehaviorProfile? = nil, systemContext: String? = nil, l2MaxCharacters: Int = 256 * 1024, l1ProjectMaxCharacters: Int = 32 * 1024, preferredActiveTokens: Int? = nil) {
        self.maxConcurrentSubagents = maxConcurrentSubagents
        self.maxSubagentDepth = maxSubagentDepth
        self.maxTotalRunsPerRootRun = maxTotalRunsPerRootRun
        self.permissionPolicy = permissionPolicy
        self.executionProfile = executionProfile
        self.behaviorProfile = behaviorProfile
        self.systemContext = systemContext
        self.l2MaxCharacters = l2MaxCharacters
        self.l1ProjectMaxCharacters = l1ProjectMaxCharacters
        self.preferredActiveTokens = preferredActiveTokens
    }

    private enum CodingKeys: String, CodingKey { case maxConcurrentSubagents, maxSubagentDepth, maxTotalRunsPerRootRun, permissionPolicy, executionProfile, behaviorProfile, systemContext, l2MaxCharacters, l1ProjectMaxCharacters, preferredActiveTokens }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentSubagents = try values.decode(Int.self, forKey: .maxConcurrentSubagents)
        maxSubagentDepth = try values.decode(Int.self, forKey: .maxSubagentDepth)
        maxTotalRunsPerRootRun = try values.decode(Int.self, forKey: .maxTotalRunsPerRootRun)
        permissionPolicy = try values.decodeIfPresent(PermissionPolicy.self, forKey: .permissionPolicy) ?? .ask
        executionProfile = try values.decodeIfPresent(ExecutionProfile.self, forKey: .executionProfile) ?? .workspace
        behaviorProfile = try values.decodeIfPresent(AgentBehaviorProfile.self, forKey: .behaviorProfile)
        systemContext = try values.decodeIfPresent(String.self, forKey: .systemContext)
        l2MaxCharacters = try values.decodeIfPresent(Int.self, forKey: .l2MaxCharacters) ?? 256 * 1024
        l1ProjectMaxCharacters = try values.decodeIfPresent(Int.self, forKey: .l1ProjectMaxCharacters) ?? 32 * 1024
        preferredActiveTokens = try values.decodeIfPresent(Int.self, forKey: .preferredActiveTokens)
    }
}

public struct RuntimeSettings: Codable, Sendable, Equatable {
    public var interactive: Bool
    public var commandTimeoutSeconds: Double
    public var execution: ExecutionTimeoutSettings

    public init(interactive: Bool = false, commandTimeoutSeconds: Double = 60, execution: ExecutionTimeoutSettings = ExecutionTimeoutSettings()) {
        self.interactive = interactive
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.execution = execution
    }

    private enum CodingKeys: String, CodingKey { case interactive, commandTimeoutSeconds, execution }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interactive = try values.decode(Bool.self, forKey: .interactive)
        commandTimeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .commandTimeoutSeconds) ?? 60
        execution = try values.decodeIfPresent(ExecutionTimeoutSettings.self, forKey: .execution) ?? ExecutionTimeoutSettings(foregroundShellSeconds: commandTimeoutSeconds)
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
    public var accountType: ProviderAccountType
    public var createdAt: Date
    public var updatedAt: Date

    public var productID: String { providerID }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, displayName, enabled, authentication, headerName, credential, endpointOverride, configOverrides, accountType, createdAt, updatedAt
    }

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
        accountType: ProviderAccountType = .apiKey,
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
        self.accountType = accountType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerID = try values.decode(String.self, forKey: .providerID)
        displayName = try values.decode(String.self, forKey: .displayName)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        authentication = try values.decode(StoredProviderAuthenticationKind.self, forKey: .authentication)
        headerName = try values.decodeIfPresent(String.self, forKey: .headerName)
        credential = try values.decodeIfPresent(CredentialRef.self, forKey: .credential)
        endpointOverride = try values.decodeIfPresent(String.self, forKey: .endpointOverride)
        configOverrides = try values.decodeIfPresent([String: String].self, forKey: .configOverrides) ?? [:]
        accountType = try values.decodeIfPresent(ProviderAccountType.self, forKey: .accountType) ?? .apiKey
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
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
    public var endpointID: String?
    public var catalogSource: ModelCatalogSource
    public var verificationStatus: ProviderVerificationStatus

    public init(
        id: String,
        providerID: String,
        modelID: String,
        displayName: String,
        wireProtocol: StoredProviderWireProtocol,
        contextWindow: Int,
        maxOutputTokens: Int? = nil,
        capabilities: ModelCapabilitiesConfiguration = ModelCapabilitiesConfiguration(),
        remoteStateEnabled: Bool = false,
        endpointID: String? = nil,
        catalogSource: ModelCatalogSource = .userConfiguration,
        verificationStatus: ProviderVerificationStatus = .unverified
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
        self.endpointID = endpointID
        self.catalogSource = catalogSource
        self.verificationStatus = verificationStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, modelID, displayName, wireProtocol, contextWindow, maxOutputTokens, capabilities, remoteStateEnabled, endpointID, catalogSource, verificationStatus
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerID = try values.decode(String.self, forKey: .providerID)
        modelID = try values.decode(String.self, forKey: .modelID)
        displayName = try values.decode(String.self, forKey: .displayName)
        wireProtocol = try values.decode(StoredProviderWireProtocol.self, forKey: .wireProtocol)
        contextWindow = try values.decode(Int.self, forKey: .contextWindow)
        maxOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        capabilities = try values.decode(ModelCapabilitiesConfiguration.self, forKey: .capabilities)
        remoteStateEnabled = try values.decode(Bool.self, forKey: .remoteStateEnabled)
        endpointID = try values.decodeIfPresent(String.self, forKey: .endpointID)
        catalogSource = try values.decodeIfPresent(ModelCatalogSource.self, forKey: .catalogSource) ?? .userConfiguration
        verificationStatus = try values.decodeIfPresent(ProviderVerificationStatus.self, forKey: .verificationStatus) ?? .unverified
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
