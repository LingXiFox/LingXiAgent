import Foundation
import LingXiProtocol

public typealias CredentialRef = LingXiProtocol.CredentialRef

public enum ConfigurationSchemaURI {
    public static let core = "https://lingxiagent.lingxifox.cn/schema/config.json"
    public static let providers = "https://lingxiagent.lingxifox.cn/schema/providers.json"
    public static let mcp = "https://lingxiagent.lingxifox.cn/schema/mcp.json"
    public static let plugins = "https://lingxiagent.lingxifox.cn/schema/plugins.json"
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
    public var codeIntelligenceEnabled: Bool
    public var maxAgentLoopSteps: Int

    public init(maxConcurrentSubagents: Int = 4, maxSubagentDepth: Int = 3, maxTotalRunsPerRootRun: Int = 32, permissionPolicy: PermissionPolicy = .ask, executionProfile: ExecutionProfile = .workspace, behaviorProfile: AgentBehaviorProfile? = nil, systemContext: String? = nil, l2MaxCharacters: Int = 256 * 1024, l1ProjectMaxCharacters: Int = 32 * 1024, preferredActiveTokens: Int? = nil, codeIntelligenceEnabled: Bool = false, maxAgentLoopSteps: Int = 32) {
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
        self.codeIntelligenceEnabled = codeIntelligenceEnabled
        self.maxAgentLoopSteps = maxAgentLoopSteps
    }

    private enum CodingKeys: String, CodingKey { case maxConcurrentSubagents, maxSubagentDepth, maxTotalRunsPerRootRun, permissionPolicy, executionProfile, behaviorProfile, systemContext, l2MaxCharacters, l1ProjectMaxCharacters, preferredActiveTokens, codeIntelligenceEnabled, maxAgentLoopSteps }

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
        codeIntelligenceEnabled = try values.decodeIfPresent(Bool.self, forKey: .codeIntelligenceEnabled) ?? false
        maxAgentLoopSteps = try values.decodeIfPresent(Int.self, forKey: .maxAgentLoopSteps) ?? 32
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

public struct ContextCacheL1Configuration: Codable, Sendable, Equatable {
    public var target: Int
    public var softLimit: Int
    public var hardLimit: Int

    public init(target: Int = 220_000, softLimit: Int = 235_000, hardLimit: Int = 250_000) {
        self.target = target
        self.softLimit = softLimit
        self.hardLimit = hardLimit
    }

    private enum CodingKeys: String, CodingKey { case target, softLimit, hardLimit }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decodeIfPresent(Int.self, forKey: .target) ?? 220_000
        softLimit = try values.decodeIfPresent(Int.self, forKey: .softLimit) ?? 235_000
        hardLimit = try values.decodeIfPresent(Int.self, forKey: .hardLimit) ?? 250_000
    }
}

public struct ContextCacheL2Configuration: Codable, Sendable, Equatable {
    public var max: Int

    public init(max: Int = 350_000) {
        self.max = max
    }

    private enum CodingKeys: String, CodingKey { case max }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        max = try values.decodeIfPresent(Int.self, forKey: .max) ?? 350_000
    }
}

public struct ContextCacheL3Configuration: Codable, Sendable, Equatable {
    public var max: Int?
    public var useRemainingBudget: Bool

    public init(max: Int? = nil, useRemainingBudget: Bool = true) {
        self.max = max
        self.useRemainingBudget = useRemainingBudget
    }

    private enum CodingKeys: String, CodingKey { case max, useRemainingBudget }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        max = try values.decodeIfPresent(Int.self, forKey: .max)
        useRemainingBudget = try values.decodeIfPresent(Bool.self, forKey: .useRemainingBudget) ?? true
    }
}

public struct ContextCacheConfiguration: Codable, Sendable, Equatable {
    public var addressableBudget: Int
    public var l1: ContextCacheL1Configuration
    public var l2: ContextCacheL2Configuration
    public var l3: ContextCacheL3Configuration
    public var reserve: Int
    public var economicThreshold: Int?

    public init(
        addressableBudget: Int = 1_048_576,
        l1: ContextCacheL1Configuration = ContextCacheL1Configuration(),
        l2: ContextCacheL2Configuration = ContextCacheL2Configuration(),
        l3: ContextCacheL3Configuration = ContextCacheL3Configuration(),
        reserve: Int = 22_000,
        economicThreshold: Int? = 272_000
    ) {
        self.addressableBudget = addressableBudget
        self.l1 = l1
        self.l2 = l2
        self.l3 = l3
        self.reserve = reserve
        self.economicThreshold = economicThreshold
    }

    private enum CodingKeys: String, CodingKey { case addressableBudget, l1, l2, l3, reserve, economicThreshold }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        addressableBudget = try values.decodeIfPresent(Int.self, forKey: .addressableBudget) ?? 1_048_576
        l1 = try values.decodeIfPresent(ContextCacheL1Configuration.self, forKey: .l1) ?? ContextCacheL1Configuration()
        l2 = try values.decodeIfPresent(ContextCacheL2Configuration.self, forKey: .l2) ?? ContextCacheL2Configuration()
        l3 = try values.decodeIfPresent(ContextCacheL3Configuration.self, forKey: .l3) ?? ContextCacheL3Configuration()
        reserve = try values.decodeIfPresent(Int.self, forKey: .reserve) ?? 22_000
        economicThreshold = try values.decodeIfPresent(Int.self, forKey: .economicThreshold) ?? 272_000
    }
}

public enum ContextPolicyResolver {
    public static func resolve(
        global: ContextCacheConfiguration = ContextCacheConfiguration(),
        modelWindow: Int,
        providerOverride: ContextCacheConfiguration? = nil,
        modelOverride: ContextCacheConfiguration? = nil,
        modelEconomicThreshold: Int? = nil
    ) throws -> EffectiveContextPolicy {
        let effectiveBudget = modelOverride?.addressableBudget ?? providerOverride?.addressableBudget ?? global.addressableBudget
        let rawReserve = modelOverride?.reserve ?? providerOverride?.reserve ?? global.reserve
        let effectiveReserve = min(rawReserve, max(128, modelWindow / 10))
        let effectiveEconomicThreshold = modelEconomicThreshold ?? modelOverride?.economicThreshold ?? providerOverride?.economicThreshold ?? global.economicThreshold

        let rawL1Target = modelOverride?.l1.target ?? providerOverride?.l1.target ?? global.l1.target
        let rawL1Soft = modelOverride?.l1.softLimit ?? providerOverride?.l1.softLimit ?? global.l1.softLimit
        let rawL1Hard = modelOverride?.l1.hardLimit ?? providerOverride?.l1.hardLimit ?? global.l1.hardLimit
        let rawL2Max = modelOverride?.l2.max ?? providerOverride?.l2.max ?? global.l2.max

        guard rawL1Target <= rawL1Soft else {
            throw ConfigurationValidationError(path: "$.context.l1", reason: "L1 target (\(rawL1Target)) must be <= softLimit (\(rawL1Soft))")
        }
        guard rawL1Soft <= rawL1Hard else {
            throw ConfigurationValidationError(path: "$.context.l1", reason: "L1 softLimit (\(rawL1Soft)) must be <= hardLimit (\(rawL1Hard))")
        }
        guard rawL2Max >= 0 else {
            throw ConfigurationValidationError(path: "$.context.l2.max", reason: "L2 max (\(rawL2Max)) must be >= 0")
        }
        guard effectiveBudget >= rawL1Target + rawL2Max else {
            throw ConfigurationValidationError(path: "$.context.addressableBudget", reason: "Addressable budget (\(effectiveBudget)) is insufficient for L1 target (\(rawL1Target)) and L2 max (\(rawL2Max))")
        }

        if modelOverride != nil && rawL1Hard + effectiveReserve > modelWindow {
            throw ConfigurationValidationError(path: "$.context.l1.hardLimit", reason: "L1 hardLimit + reserve (\(rawL1Hard + effectiveReserve)) exceeds model physical window (\(modelWindow))")
        }

        let adaptedHard = min(rawL1Hard, max(512, modelWindow - effectiveReserve))
        let adaptedSoft = min(rawL1Soft, max(256, Int(Double(adaptedHard) * 0.94)))
        let adaptedTarget = min(rawL1Target, max(128, Int(Double(adaptedHard) * 0.88)))
        let adaptedBudget = effectiveBudget

        let useRemaining = modelOverride?.l3.useRemainingBudget ?? providerOverride?.l3.useRemainingBudget ?? global.l3.useRemainingBudget
        let explicitL3Max = modelOverride?.l3.max ?? providerOverride?.l3.max ?? global.l3.max

        let l3Capacity: Int
        if let explicitL3Max {
            l3Capacity = max(0, explicitL3Max)
        } else if useRemaining {
            l3Capacity = max(0, adaptedBudget - adaptedTarget - rawL2Max)
        } else {
            l3Capacity = 0
        }

        guard adaptedBudget >= adaptedTarget + rawL2Max else {
            throw ConfigurationValidationError(path: "$.context.addressableBudget", reason: "Addressable budget (\(adaptedBudget)) is insufficient for L1 target (\(adaptedTarget)) and L2 max (\(rawL2Max))")
        }

        return EffectiveContextPolicy(
            addressableBudget: adaptedBudget,
            modelWindow: modelWindow,
            economicThreshold: effectiveEconomicThreshold,
            reserve: effectiveReserve,
            l1Target: adaptedTarget,
            l1SoftLimit: adaptedSoft,
            l1HardLimit: adaptedHard,
            l2Max: rawL2Max,
            l3Capacity: l3Capacity,
            l3Enabled: l3Capacity > 0
        )
    }
}

public struct CoreConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var core: CoreSettings
    public var agent: AgentSettings
    public var runtime: RuntimeSettings
    public var context: ContextCacheConfiguration

    public init(
        schema: String = ConfigurationSchemaURI.core,
        version: Int = ConfigurationFormat.currentVersion,
        core: CoreSettings = CoreSettings(),
        agent: AgentSettings = AgentSettings(),
        runtime: RuntimeSettings = RuntimeSettings(),
        context: ContextCacheConfiguration = ContextCacheConfiguration()
    ) {
        self.schema = schema
        self.version = version
        self.core = core
        self.agent = agent
        self.runtime = runtime
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, core, agent, runtime, context
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(String.self, forKey: .schema) ?? ConfigurationSchemaURI.core
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? ConfigurationFormat.currentVersion
        core = try values.decodeIfPresent(CoreSettings.self, forKey: .core) ?? CoreSettings()
        agent = try values.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? AgentSettings()
        runtime = try values.decodeIfPresent(RuntimeSettings.self, forKey: .runtime) ?? RuntimeSettings()
        context = try values.decodeIfPresent(ContextCacheConfiguration.self, forKey: .context) ?? ContextCacheConfiguration()
    }
}

public enum StoredProviderWireProtocol: String, Codable, Sendable, Equatable {
    case chatCompletions, responses, anthropicMessages
}

public enum StoredProviderAuthenticationKind: String, Codable, Sendable, Equatable {
    case none, bearer, header
}

public struct PublicProviderOptions: Codable, Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String?
    public var apiKeyHeader: String?
    public var headers: [String: String]

    public init(baseURL: String, apiKey: String? = nil, apiKeyHeader: String? = nil, headers: [String: String] = [:]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeyHeader = apiKeyHeader
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey { case baseURL, apiKey, apiKeyHeader, headers }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey)
        if let apiKey, !(apiKey.hasPrefix("{env:") && apiKey.hasSuffix("}")) && !(apiKey.hasPrefix("{vault:") && apiKey.hasSuffix("}")) {
            throw DecodingError.dataCorruptedError(forKey: .apiKey, in: values, debugDescription: "apiKey must be an {env:NAME} or {vault:REFERENCE} reference")
        }
        apiKeyHeader = try values.decodeIfPresent(String.self, forKey: .apiKeyHeader)
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

public struct PublicModelLimit: Codable, Sendable, Equatable {
    public var context: Int
    public var output: Int

    public init(context: Int, output: Int) {
        self.context = context
        self.output = output
    }
}

public struct PublicModelConfiguration: Codable, Sendable, Equatable {
    public var name: String
    public var reasoning: Bool
    public var limit: PublicModelLimit
    public var toolCalling: Bool
    public var parallelToolCalling: Bool
    public var vision: Bool
    public var structuredOutput: Bool
    public var economicThreshold: Int?
    public var context: ContextCacheConfiguration?
    public var rateLimits: ProviderRateLimits
    public var reasoningCapability: ReasoningCapability?

    public init(name: String, reasoning: Bool = false, limit: PublicModelLimit, toolCalling: Bool = true, parallelToolCalling: Bool = true, vision: Bool = false, structuredOutput: Bool = false, economicThreshold: Int? = nil, context: ContextCacheConfiguration? = nil, rateLimits: ProviderRateLimits = ProviderRateLimits(), reasoningCapability: ReasoningCapability? = nil) {
        self.name = name
        self.reasoning = reasoning
        self.limit = limit
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.economicThreshold = economicThreshold
        self.context = context
        self.rateLimits = rateLimits
        self.reasoningCapability = reasoningCapability
    }

    private enum CodingKeys: String, CodingKey { case name, reasoning, limit, toolCalling, parallelToolCalling, vision, structuredOutput, economicThreshold, context, rateLimits, reasoningCapability }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        reasoning = try values.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        limit = try values.decode(PublicModelLimit.self, forKey: .limit)
        toolCalling = try values.decodeIfPresent(Bool.self, forKey: .toolCalling) ?? true
        parallelToolCalling = try values.decodeIfPresent(Bool.self, forKey: .parallelToolCalling) ?? true
        vision = try values.decodeIfPresent(Bool.self, forKey: .vision) ?? false
        structuredOutput = try values.decodeIfPresent(Bool.self, forKey: .structuredOutput) ?? false
        economicThreshold = try values.decodeIfPresent(Int.self, forKey: .economicThreshold)
        context = try values.decodeIfPresent(ContextCacheConfiguration.self, forKey: .context)
        rateLimits = try values.decodeIfPresent(ProviderRateLimits.self, forKey: .rateLimits) ?? ProviderRateLimits()
        reasoningCapability = try values.decodeIfPresent(ReasoningCapability.self, forKey: .reasoningCapability)
    }
}

public struct PublicProviderConfiguration: Codable, Sendable, Equatable {
    public var name: String
    public var adapter: String
    public var options: PublicProviderOptions
    public var models: [String: PublicModelConfiguration]

    public init(name: String, adapter: String = "openai-compatible", options: PublicProviderOptions, models: [String: PublicModelConfiguration]) {
        self.name = name
        self.adapter = adapter
        self.options = options
        self.models = models
    }
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
    public var context: ContextCacheConfiguration?
    public var createdAt: Date
    public var updatedAt: Date

    public var productID: String { providerID }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, displayName, enabled, authentication, headerName, credential, endpointOverride, configOverrides, accountType, context, createdAt, updatedAt
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
        context: ContextCacheConfiguration? = nil,
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
        self.context = context
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
        context = try values.decodeIfPresent(ContextCacheConfiguration.self, forKey: .context)
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
    public var reasoningCapability: ReasoningCapability?

    public init(toolCalling: Bool = false, parallelToolCalling: Bool = false, reasoning: Bool = false, vision: Bool = false, structuredOutput: Bool = false, reasoningCapability: ReasoningCapability? = nil) {
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.reasoning = reasoning
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.reasoningCapability = reasoningCapability
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
    public var economicThreshold: Int?
    public var context: ContextCacheConfiguration?
    public var rateLimits: ProviderRateLimits

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
        verificationStatus: ProviderVerificationStatus = .unverified,
        economicThreshold: Int? = nil,
        context: ContextCacheConfiguration? = nil,
        rateLimits: ProviderRateLimits = ProviderRateLimits()
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
        self.economicThreshold = economicThreshold
        self.context = context
        self.rateLimits = rateLimits
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, modelID, displayName, wireProtocol, contextWindow, maxOutputTokens, capabilities, remoteStateEnabled, endpointID, catalogSource, verificationStatus, economicThreshold, context, rateLimits
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
        economicThreshold = try values.decodeIfPresent(Int.self, forKey: .economicThreshold)
        context = try values.decodeIfPresent(ContextCacheConfiguration.self, forKey: .context)
        rateLimits = try values.decodeIfPresent(ProviderRateLimits.self, forKey: .rateLimits) ?? ProviderRateLimits()
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
    public var requiredHeaders: [String: String]

    public init(id: String, displayName: String, baseURL: String, requiredHeaders: [String: String] = [:]) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.requiredHeaders = requiredHeaders
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, baseURL, requiredHeaders }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        requiredHeaders = try values.decodeIfPresent([String: String].self, forKey: .requiredHeaders) ?? [:]
    }
}

public struct ProvidersConfiguration: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var model: String?
    public var providers: [String: PublicProviderConfiguration]

    private var legacyCustomProviders: [CustomProviderConfiguration]
    private var legacyAccounts: [ProviderAccountConfiguration]
    private var legacyModelProfiles: [ModelProfileConfiguration]
    private var legacyDefaultSelection: StoredModelSelection?

    public var customProviders: [CustomProviderConfiguration] {
        get { legacyCustomProviders }
        set {
            legacyCustomProviders = newValue
            rebuildPublicConfigurationFromLegacy()
        }
    }

    public var accounts: [ProviderAccountConfiguration] {
        get { legacyAccounts }
        set {
            legacyAccounts = newValue
            rebuildPublicConfigurationFromLegacy()
        }
    }

    public var modelProfiles: [ModelProfileConfiguration] {
        get { legacyModelProfiles }
        set {
            legacyModelProfiles = newValue
            rebuildPublicConfigurationFromLegacy()
        }
    }

    public var defaultSelection: StoredModelSelection? {
        get { legacyDefaultSelection }
        set {
            legacyDefaultSelection = newValue
            rebuildPublicConfigurationFromLegacy()
        }
    }

    public init(
        schema: String = ConfigurationSchemaURI.providers,
        version: Int = ConfigurationFormat.currentVersion,
        model: String? = nil,
        providers: [String: PublicProviderConfiguration] = [:]
    ) {
        self.schema = schema
        self.version = version
        self.model = model
        self.providers = providers
        legacyCustomProviders = []
        legacyAccounts = []
        legacyModelProfiles = []
        legacyDefaultSelection = nil
        if !providers.isEmpty {
            let legacy = Self.makeLegacyConfiguration(model: model, providers: providers)
            legacyCustomProviders = legacy.customProviders
            legacyAccounts = legacy.accounts
            legacyModelProfiles = legacy.modelProfiles
            legacyDefaultSelection = legacy.defaultSelection
        }
    }

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
        self.legacyCustomProviders = customProviders
        self.legacyAccounts = accounts
        self.legacyModelProfiles = modelProfiles
        self.legacyDefaultSelection = defaultSelection
        self.model = Self.modelSelection(defaultSelection, accounts: accounts, profiles: modelProfiles)
        self.providers = Self.makePublicConfiguration(customProviders: customProviders, accounts: accounts, profiles: modelProfiles)
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, model, providers
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        version = try values.decode(Int.self, forKey: .version)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        providers = try values.decodeIfPresent([String: PublicProviderConfiguration].self, forKey: .providers) ?? [:]
        let legacy = Self.makeLegacyConfiguration(model: model, providers: providers)
        legacyCustomProviders = legacy.customProviders
        legacyAccounts = legacy.accounts
        legacyModelProfiles = legacy.modelProfiles
        legacyDefaultSelection = legacy.defaultSelection
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(version, forKey: .version)
        let publicConfiguration = Self.makePublicConfiguration(customProviders: legacyCustomProviders, accounts: legacyAccounts, profiles: legacyModelProfiles)
        let selectedModel = Self.modelSelection(legacyDefaultSelection, accounts: legacyAccounts, profiles: legacyModelProfiles) ?? model
        try values.encodeIfPresent(selectedModel, forKey: .model)
        try values.encode(publicConfiguration, forKey: .providers)
    }

    private mutating func rebuildPublicConfigurationFromLegacy() {
        providers = Self.makePublicConfiguration(customProviders: legacyCustomProviders, accounts: legacyAccounts, profiles: legacyModelProfiles)
        model = Self.modelSelection(legacyDefaultSelection, accounts: legacyAccounts, profiles: legacyModelProfiles)
    }

    private struct LegacyConfiguration {
        let customProviders: [CustomProviderConfiguration]
        let accounts: [ProviderAccountConfiguration]
        let modelProfiles: [ModelProfileConfiguration]
        let defaultSelection: StoredModelSelection?
    }

    private static func makeLegacyConfiguration(model: String?, providers: [String: PublicProviderConfiguration]) -> LegacyConfiguration {
        var customProviders: [CustomProviderConfiguration] = []
        var accounts: [ProviderAccountConfiguration] = []
        var profiles: [ModelProfileConfiguration] = []
        for (providerID, provider) in providers.sorted(by: { $0.key < $1.key }) {
            customProviders.append(CustomProviderConfiguration(id: providerID, displayName: provider.name, baseURL: provider.options.baseURL, requiredHeaders: provider.options.headers))
            let credential = credentialReference(provider.options.apiKey)
            let authentication: StoredProviderAuthenticationKind = provider.options.apiKeyHeader == nil ? (credential == nil ? .none : .bearer) : .header
            accounts.append(ProviderAccountConfiguration(
                id: providerID,
                providerID: providerID,
                displayName: provider.name,
                authentication: authentication,
                headerName: provider.options.apiKeyHeader,
                credential: credential,
                endpointOverride: nil,
                configOverrides: provider.options.headers,
                accountType: credential == nil ? .anonymousLocal : .apiKey
            ))
            for (modelID, definition) in provider.models.sorted(by: { $0.key < $1.key }) {
                let wire: StoredProviderWireProtocol
                switch provider.adapter {
                case "anthropic-messages": wire = .anthropicMessages
                case "openai-responses": wire = .responses
                default: wire = .chatCompletions
                }
                profiles.append(ModelProfileConfiguration(
                    id: "\(providerID)::\(modelID)",
                    providerID: providerID,
                    modelID: modelID,
                    displayName: definition.name,
                    wireProtocol: wire,
                    contextWindow: definition.limit.context,
                    maxOutputTokens: definition.limit.output,
                    capabilities: ModelCapabilitiesConfiguration(toolCalling: definition.toolCalling, parallelToolCalling: definition.parallelToolCalling, reasoning: definition.reasoning, vision: definition.vision, structuredOutput: definition.structuredOutput, reasoningCapability: definition.reasoningCapability),
                    endpointID: nil,
                    rateLimits: definition.rateLimits
                ))
            }
        }
        let selection: StoredModelSelection?
        if let model, let separator = model.firstIndex(of: "/") {
            let providerID = String(model[..<separator])
            let modelID = String(model[model.index(after: separator)...])
            let profileID = "\(providerID)::\(modelID)"
            selection = accounts.contains(where: { $0.id == providerID }) && profiles.contains(where: { $0.id == profileID }) ? StoredModelSelection(accountID: providerID, profileID: profileID) : nil
        } else {
            selection = nil
        }
        return LegacyConfiguration(customProviders: customProviders, accounts: accounts, modelProfiles: profiles, defaultSelection: selection)
    }

    private static func makePublicConfiguration(customProviders: [CustomProviderConfiguration], accounts: [ProviderAccountConfiguration], profiles: [ModelProfileConfiguration]) -> [String: PublicProviderConfiguration] {
        var result: [String: PublicProviderConfiguration] = [:]
        for custom in customProviders {
            let account = accounts.first(where: { $0.providerID == custom.id })
            let providerProfiles = profiles.filter { $0.providerID == custom.id }
            let adapter = providerProfiles.first.map(adapterName) ?? "openai-compatible"
            let models = Dictionary(uniqueKeysWithValues: providerProfiles.map { profile in
                (profile.modelID, PublicModelConfiguration(
                    name: profile.displayName,
                    reasoning: profile.capabilities.reasoning,
                    limit: PublicModelLimit(context: profile.contextWindow, output: profile.maxOutputTokens ?? 4_096),
                    toolCalling: profile.capabilities.toolCalling,
                    parallelToolCalling: profile.capabilities.parallelToolCalling,
                    vision: profile.capabilities.vision,
                    structuredOutput: profile.capabilities.structuredOutput,
                    rateLimits: profile.rateLimits
                ))
            })
            result[custom.id] = PublicProviderConfiguration(
                name: custom.displayName,
                adapter: adapter,
                options: PublicProviderOptions(baseURL: account?.endpointOverride ?? custom.baseURL, apiKey: credentialSource(account?.credential), apiKeyHeader: account?.headerName, headers: custom.requiredHeaders),
                models: models
            )
        }
        for account in accounts where result[account.providerID] == nil {
            let providerProfiles = profiles.filter { $0.providerID == account.providerID }
            let baseURL = account.endpointOverride ?? ""
            result[account.providerID] = PublicProviderConfiguration(
                name: account.displayName,
                adapter: providerProfiles.first.map(adapterName) ?? "openai-compatible",
                options: PublicProviderOptions(baseURL: baseURL, apiKey: credentialSource(account.credential), apiKeyHeader: account.headerName, headers: account.configOverrides),
                models: Dictionary(uniqueKeysWithValues: providerProfiles.map { profile in
                    (profile.modelID, PublicModelConfiguration(name: profile.displayName, reasoning: profile.capabilities.reasoning, limit: PublicModelLimit(context: profile.contextWindow, output: profile.maxOutputTokens ?? 4_096), toolCalling: profile.capabilities.toolCalling, parallelToolCalling: profile.capabilities.parallelToolCalling, vision: profile.capabilities.vision, structuredOutput: profile.capabilities.structuredOutput, rateLimits: profile.rateLimits))
                })
            )
        }
        return result
    }

    private static func modelSelection(_ selection: StoredModelSelection?, accounts: [ProviderAccountConfiguration], profiles: [ModelProfileConfiguration]) -> String? {
        guard let selection, let account = accounts.first(where: { $0.id == selection.accountID }), let profile = profiles.first(where: { $0.id == selection.profileID }) else { return nil }
        return "\(account.providerID)/\(profile.modelID)"
    }

    private static func adapterName(_ profile: ModelProfileConfiguration) -> String {
        switch profile.wireProtocol {
        case .chatCompletions: "openai-compatible"
        case .responses: "openai-responses"
        case .anthropicMessages: "anthropic-messages"
        }
    }

    private static func credentialReference(_ source: String?) -> CredentialRef? {
        guard let source, !source.isEmpty else { return nil }
        if source.hasPrefix("{env:") && source.hasSuffix("}") { return CredentialRef("env:\(source.dropFirst(5).dropLast())") }
        if source.hasPrefix("{vault:") && source.hasSuffix("}") { return CredentialRef(String(source.dropFirst(7).dropLast())) }
        return nil
    }

    private static func credentialSource(_ reference: CredentialRef?) -> String? {
        guard let reference else { return nil }
        if reference.rawValue.hasPrefix("env:") { return "{env:\(reference.rawValue.dropFirst(4))}" }
        return "{vault:\(reference.rawValue)}"
    }

    public static func == (lhs: ProvidersConfiguration, rhs: ProvidersConfiguration) -> Bool {
        lhs.schema == rhs.schema && lhs.version == rhs.version && lhs.model == rhs.model && lhs.providers == rhs.providers
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
