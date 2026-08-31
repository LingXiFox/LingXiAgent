import Foundation
import LingXiProtocol

public struct ProviderRuntimeResolution: Sendable {
    public let assembly: ModelRuntimeAssembly
    public let missingRequirements: [String]
    public let runtimes: [String: ModelRuntimeAssembly]
    public let defaultSelection: ModelSelection?
}

public struct MCPRuntimeResolution: Sendable {
    public let pager: MCPToolPager
    public let configurations: [MCPServerConfiguration]
}

public enum LingXiDataRootResolver {
    public static func resolve(environment: [String: String], homeDirectory: URL) -> URL {
        if let override = environment["LINGXI_DATA_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".lingxiagent", isDirectory: true).standardizedFileURL
    }
}

public enum RuntimeConfigurationResolver {
    public static func resolveProviders(
        _ configuration: ProvidersConfiguration,
        credentials: any CredentialStore,
        provenanceDirectory: URL? = nil,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false
    ) async throws -> ProviderRuntimeResolution {
        try requireUnique(configuration.customProviders.map(\.id), path: "$.customProviders")
        try requireUnique(configuration.accounts.map(\.id), path: "$.accounts")
        try requireUnique(configuration.modelProfiles.map(\.id), path: "$.modelProfiles")

        var runtimes: [String: ModelRuntimeAssembly] = [:]
        let provenance = ProviderProvenanceStore(directory: provenanceDirectory)
        for account in configuration.accounts where account.enabled {
            let profiles = configuration.modelProfiles.filter { $0.providerID == account.providerID }
            guard !profiles.isEmpty else { continue }
            let custom = configuration.customProviders.first(where: { $0.id == account.providerID })
            let builtin = BuiltinProviderCatalog.definition(id: account.providerID)
            if let builtin, builtin.status != .verified {
                throw ConfigurationValidationError(path: "$.accounts.\(account.id).providerID", reason: "built-in provider is not verified for runtime use")
            }
            guard custom != nil || builtin != nil else {
                throw ConfigurationValidationError(path: "$.accounts.\(account.id).providerID", reason: "unknown provider; define it explicitly in customProviders")
            }
            let endpoint = account.endpointOverride ?? custom?.baseURL ?? builtin?.defaultBaseURL?.absoluteString
            guard let endpoint else { throw ConfigurationValidationError(path: "$.accounts.\(account.id).endpointOverride", reason: "provider endpoint is required") }
            let baseURL = try ConfigurationEndpointPolicy.resolve(endpoint, path: "$.accounts.\(account.id).endpointOverride")
            let authentication = try await authentication(for: account, credentials: credentials)
            for profile in profiles {
                if let builtin, !builtin.supportedWires.contains(profile.wireProtocol) {
                    throw ConfigurationValidationError(path: "$.modelProfiles.\(profile.id).wireProtocol", reason: "wire is not verified for this built-in provider")
                }
                runtimes["\(account.id)::\(profile.id)"] = try providerAssembly(
                    account: account,
                    profile: profile,
                    baseURL: baseURL,
                    authentication: authentication,
                    provenance: provenance,
                    diagnosticsEnabled: diagnosticsEnabled,
                    performanceDiagnosticsEnabled: performanceDiagnosticsEnabled
                )
            }
        }

        guard let selected = configuration.defaultSelection else {
            return ProviderRuntimeResolution(assembly: .unavailable, missingRequirements: ["providers.defaultSelection"], runtimes: runtimes, defaultSelection: nil)
        }
        guard let account = configuration.accounts.first(where: { $0.id == selected.accountID }) else {
            throw ConfigurationValidationError(path: "$.defaultSelection.accountID", reason: "unknown provider account")
        }
        guard account.enabled else {
            throw ConfigurationValidationError(path: "$.defaultSelection.accountID", reason: "provider account is disabled")
        }
        guard let profile = configuration.modelProfiles.first(where: { $0.id == selected.profileID }) else {
            throw ConfigurationValidationError(path: "$.defaultSelection.profileID", reason: "unknown model profile")
        }
        guard profile.providerID == account.providerID else {
            throw ConfigurationValidationError(path: "$.defaultSelection", reason: "account and model profile use different providers")
        }
        guard let assembly = runtimes["\(account.id)::\(profile.id)"] else {
            throw ConfigurationValidationError(path: "$.defaultSelection", reason: "selected provider runtime is unavailable")
        }
        let selection = ModelSelection(providerID: profile.providerID, accountID: account.id, profileID: profile.id, modelID: profile.modelID)
        return ProviderRuntimeResolution(
            assembly: assembly,
            missingRequirements: [],
            runtimes: runtimes,
            defaultSelection: selection
        )
    }

    private static func providerAssembly(
        account: ProviderAccountConfiguration,
        profile: ModelProfileConfiguration,
        baseURL: URL,
        authentication: ProviderAuthentication,
        provenance: ProviderProvenanceStore,
        diagnosticsEnabled: Bool,
        performanceDiagnosticsEnabled: Bool
    ) throws -> ModelRuntimeAssembly {
        let wireProtocol: ModelWireProtocol
        switch profile.wireProtocol {
        case .chatCompletions: wireProtocol = .chatCompletions
        case .responses: wireProtocol = .responses
        case .anthropicMessages: wireProtocol = .anthropicMessages
        }
        guard !profile.remoteStateEnabled || wireProtocol == .responses else {
            throw ConfigurationValidationError(path: "$.modelProfiles.\(profile.id).remoteStateEnabled", reason: "remote state is only supported by Responses profiles")
        }
        let context = ModelContextProfile(contextWindowTokens: profile.contextWindow, maxOutputTokens: profile.maxOutputTokens, source: "providers.json:\(profile.id)")
        let runtimeConfig = ProviderConfig(
            baseURL: baseURL,
            authentication: authentication,
            model: profile.modelID,
            wireProtocol: wireProtocol,
            diagnosticsEnabled: diagnosticsEnabled,
            performanceDiagnosticsEnabled: performanceDiagnosticsEnabled,
            remoteStateEnabled: profile.remoteStateEnabled,
            maxOutputTokens: profile.maxOutputTokens
        )
        let provider: any ModelProvider
        switch wireProtocol {
        case .chatCompletions: provider = OpenAICompatibleProvider(config: runtimeConfig, provenance: provenance)
        case .responses: provider = OpenAIResponsesProvider(config: runtimeConfig, provenance: provenance)
        case .anthropicMessages: provider = AnthropicMessagesProvider(config: runtimeConfig, provenance: provenance)
        }
        return ModelRuntimeAssembly(
            provider: provider,
            modelID: ModelID(profile.modelID),
            contextProfile: context,
            endpoint: ResolvedModelEndpoint(providerID: account.providerID, accountID: account.id, profileID: profile.id, modelID: ModelID(profile.modelID), baseURL: baseURL, wireProtocol: wireProtocol, contextProfile: context, capabilities: ModelCapabilities(toolCalling: profile.capabilities.toolCalling, parallelToolCalling: profile.capabilities.parallelToolCalling, reasoning: profile.capabilities.reasoning, vision: profile.capabilities.vision, structuredOutput: profile.capabilities.structuredOutput))
        )
    }

    public static func resolveMCP(
        _ configuration: MCPConfiguration,
        credentials: any CredentialStore,
        schemaStoreDirectory: URL? = nil,
        discoverTools: Bool = true
    ) async throws -> MCPRuntimeResolution {
        try requireUnique(configuration.servers.map(\.id), path: "$.servers")
        try requireUnique(configuration.servers.map(\.alias), path: "$.servers.alias")
        let manager = MCPConnectionManager()
        let pager = MCPToolPager(schemaStore: MCPToolSchemaStore(directory: schemaStoreDirectory), invoker: manager)
        var resolved: [MCPServerConfiguration] = []

        for stored in configuration.servers {
            let path = "$.servers.\(stored.id)"
            if stored.transport == .streamableHTTP, !stored.environment.isEmpty {
                throw ConfigurationValidationError(path: "\(path).environment", reason: "HTTP transport does not accept process environment")
            }
            if stored.transport == .stdio, stored.authentication.kind != .none {
                throw ConfigurationValidationError(path: "\(path).authentication", reason: "stdio authentication must use environment credential references")
            }
            var secretValues: [String: String] = [:]
            let authentication: MCPAuthentication
            switch stored.authentication.kind {
            case .none:
                authentication = .none
            case .bearer, .header:
                guard let reference = stored.authentication.credential else {
                    throw ConfigurationValidationError(path: "\(path).authentication.credential", reason: "credential reference is required")
                }
                if stored.enabled {
                    guard let value = try await credentials.secret(for: reference), validHeaderValue(value) else {
                        throw ConfigurationValidationError(path: "\(path).authentication.credential", reason: "credential is missing or invalid")
                    }
                    secretValues[reference.rawValue] = value
                }
                if stored.authentication.kind == .bearer {
                    authentication = .bearer(SecretRef(reference.rawValue))
                } else {
                    guard let name = stored.authentication.headerName, validHeaderName(name) else {
                        throw ConfigurationValidationError(path: "\(path).authentication.headerName", reason: "valid header name is required")
                    }
                    authentication = .header(name: name, value: SecretRef(reference.rawValue))
                }
            }

            var environment: [String: SecretRef] = [:]
            for item in stored.environment {
                guard !item.name.isEmpty, environment[item.name] == nil else {
                    throw ConfigurationValidationError(path: "\(path).environment", reason: "environment names must be non-empty and unique")
                }
                if stored.enabled {
                    guard let value = try await credentials.secret(for: item.credential), !value.isEmpty else {
                        throw ConfigurationValidationError(path: "\(path).environment.\(item.name)", reason: "credential is missing")
                    }
                    secretValues[item.credential.rawValue] = value
                }
                environment[item.name] = SecretRef(item.credential.rawValue)
            }

            let runtime: MCPServerConfiguration
            switch stored.transport {
            case .streamableHTTP:
                guard stored.command == nil, stored.arguments.isEmpty, let endpoint = stored.endpoint else {
                    throw ConfigurationValidationError(path: path, reason: "streamableHTTP requires endpoint and forbids command/arguments")
                }
                runtime = MCPServerConfiguration(
                    serverID: MCPServerID(stored.id),
                    alias: stored.alias,
                    transport: .streamableHTTP,
                    endpoint: try ConfigurationEndpointPolicy.resolve(endpoint, path: "\(path).endpoint"),
                    protocolPreference: protocolPreference(stored.protocolPreference),
                    enabled: stored.enabled,
                    auth: authentication,
                    timeoutSeconds: stored.timeoutSeconds
                )
                if stored.enabled {
                    let transport = MCPStreamableHTTPTransport(configuration: runtime, resolver: InMemorySecretResolver(secretValues))
                    await manager.register(transport, for: runtime.serverID)
                    if discoverTools { try await pager.replaceCatalog(serverID: runtime.serverID, tools: transport.listTools()) }
                }
            case .stdio:
                guard stored.endpoint == nil, let command = stored.command, command.hasPrefix("/") else {
                    throw ConfigurationValidationError(path: path, reason: "stdio requires an absolute command and forbids endpoint")
                }
                runtime = MCPServerConfiguration(
                    serverID: MCPServerID(stored.id),
                    alias: stored.alias,
                    transport: .stdio,
                    command: command,
                    arguments: stored.arguments,
                    protocolPreference: protocolPreference(stored.protocolPreference),
                    enabled: stored.enabled,
                    auth: authentication,
                    environment: environment,
                    timeoutSeconds: stored.timeoutSeconds
                )
                if stored.enabled {
                    let transport = MCPStdioTransport(configuration: runtime, resolver: InMemorySecretResolver(secretValues))
                    await manager.register(transport, for: runtime.serverID)
                    if discoverTools { try await pager.replaceCatalog(serverID: runtime.serverID, tools: transport.listTools()) }
                }
            }
            resolved.append(runtime)
        }
        return MCPRuntimeResolution(pager: pager, configurations: resolved)
    }

    private static func authentication(for account: ProviderAccountConfiguration, credentials: any CredentialStore) async throws -> ProviderAuthentication {
        switch account.authentication {
        case .none:
            return .none
        case .bearer, .header:
            guard let reference = account.credential else {
                throw ConfigurationValidationError(path: "$.accounts.\(account.id).credential", reason: "credential reference is required")
            }
            guard let secret = try await credentials.secret(for: reference), validHeaderValue(secret) else {
                throw ConfigurationValidationError(path: "$.accounts.\(account.id).credential", reason: "credential is missing or invalid")
            }
            if account.authentication == .bearer { return .bearer(secret) }
            guard let name = account.headerName, validHeaderName(name) else {
                throw ConfigurationValidationError(path: "$.accounts.\(account.id).headerName", reason: "valid header name is required")
            }
            return .header(name: name, value: secret)
        }
    }

    private static func protocolPreference(_ value: StoredMCPProtocolPreference) -> MCPProtocolPreference {
        switch value {
        case .auto: .auto
        case .modern: .modern
        case .legacy: .legacy
        }
    }

    private static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0) }
    }

    private static func validHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\r") && !value.contains("\n")
    }

    private static func requireUnique(_ values: [String], path: String) throws {
        guard Set(values).count == values.count else {
            throw ConfigurationValidationError(path: path, reason: "identifiers must be unique")
        }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigurationValidationError(path: path, reason: "identifiers must not be empty")
        }
    }
}

enum ConfigurationEndpointPolicy {
    static func resolve(_ value: String, path: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw ConfigurationValidationError(path: path, reason: "invalid endpoint URL")
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw ConfigurationValidationError(path: path, reason: "endpoint must use HTTPS or HTTP loopback")
        }
        return url
    }
}
