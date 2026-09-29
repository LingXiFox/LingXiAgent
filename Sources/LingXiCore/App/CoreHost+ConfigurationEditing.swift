import Foundation
import LingXiPlatform
import LingXiProtocol

// Settings-window editing of `providers.json` and `mcp.json`.
//
// Every write goes through `ConfigurationStore` (schema-validated, atomic).
// Secrets arrive once in a `SecretUpdate.replace`, go to the credential vault
// and are referenced from the file as `{vault:…}`; nothing here ever returns
// a secret value.

extension CoreHost {
    // MARK: - Providers

    public func getProviderConfiguration(envelope: QueryEnvelope<GetProviderConfigurationRequest>) async throws -> ResponseEnvelope<ProviderConfigurationDetail> {
        let providerID = envelope.payload.providerID
        let snapshot = try await requireConfigurationStore().load()
        guard let provider = snapshot.providers.providers[providerID] else {
            throw CoreError(code: .provider, message: "Provider \(providerID) 不在 providers.json 中，由登录或内置目录管理")
        }
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                payload: Self.providerDetail(providerID, provider))
    }

    public func saveProviderConfiguration(envelope: CommandEnvelope<SaveProviderConfigurationRequest>) async throws -> CommandReceipt<ProviderConfigurationDetail> {
        let request = envelope.payload
        let providerID = request.providerID.trimmingCharacters(in: .whitespaces)
        try Self.validateIdentifier(providerID, what: "Provider ID")
        guard ["openai-compatible", "openai-responses", "anthropic-messages"].contains(request.adapter) else {
            throw CoreError(code: .toolArgumentInvalid, message: "不支持的接口类型: \(request.adapter)")
        }
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "名称不能为空") }
        let baseURL = request.baseURL.trimmingCharacters(in: .whitespaces)
        _ = try ConfigurationEndpointPolicy.resolve(baseURL, path: "$.providers.\(providerID).options.baseURL")
        for header in request.headers.keys where header.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CoreError(code: .toolArgumentInvalid, message: "请求头名称不能为空 (\(header))")
        }

        let store = try requireConfigurationStore()
        let snapshot = try await store.load()
        let existing = snapshot.providers.providers[providerID]

        // Models: nil keeps what is stored; fields the form does not edit
        // (context cache, economic threshold, reasoning capability) survive.
        var models = existing?.models ?? [:]
        if let edited = request.models {
            var next: [String: PublicModelConfiguration] = [:]
            for model in edited {
                let modelID = model.modelID.trimmingCharacters(in: .whitespaces)
                guard !modelID.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "模型 ID 不能为空") }
                guard model.contextWindow > 0, model.maxOutputTokens > 0 else {
                    throw CoreError(code: .toolArgumentInvalid, message: "\(modelID) 的上下文窗口与输出上限必须大于 0")
                }
                var config = models[modelID] ?? PublicModelConfiguration(
                    name: modelID, limit: PublicModelLimit(context: model.contextWindow, output: model.maxOutputTokens))
                config.name = model.name.isEmpty ? modelID : model.name
                config.limit = PublicModelLimit(context: model.contextWindow, output: model.maxOutputTokens)
                config.reasoning = model.reasoning
                config.toolCalling = model.toolCalling
                config.parallelToolCalling = model.parallelToolCalling
                config.vision = model.vision
                config.structuredOutput = model.structuredOutput
                config.rateLimits = ProviderRateLimits(
                    tpm: model.tokensPerMinute, rpm: model.requestsPerMinute,
                    maxConcurrentRequests: model.maxConcurrentRequests,
                    retryPolicy: ProviderRetryPolicy(
                        maxRetries: model.maxRetries,
                        initialDelayMilliseconds: model.initialRetryDelayMilliseconds,
                        maxDelayMilliseconds: model.maxRetryDelayMilliseconds,
                        jitterRatio: min(1, max(0, model.retryJitterRatio))))
                next[modelID] = config
            }
            models = next
        }
        guard !models.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "至少需要一个模型") }

        let apiKey = try await updateSecret(request.apiKey,
                                            current: existing?.options.apiKey,
                                            reference: CredentialRef("provider-\(providerID)-key"))

        var providers = snapshot.providers.providers
        providers[providerID] = PublicProviderConfiguration(
            name: name,
            adapter: request.adapter,
            options: PublicProviderOptions(
                baseURL: baseURL,
                apiKey: apiKey,
                apiKeyHeader: request.apiKeyHeader.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                headers: request.headers),
            models: models)
        // A removed model must not stay the default.
        var selected = snapshot.providers.model
        if let current = selected, current.hasPrefix("\(providerID)/"),
           models[String(current.dropFirst(providerID.count + 1))] == nil {
            selected = nil
        }
        try await store.saveProviders(Self.rebuiltProviders(snapshot.providers, model: selected, providers: providers))
        await reassembleCurrentModel(ifProvider: providerID)

        let detail = Self.providerDetail(providerID, providers[providerID]!)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: detail)
    }

    public func deleteProviderConfiguration(envelope: CommandEnvelope<DeleteProviderConfigurationRequest>) async throws -> CommandReceipt<VoidResult> {
        let providerID = envelope.payload.providerID
        let store = try requireConfigurationStore()
        let snapshot = try await store.load()
        var providers = snapshot.providers.providers
        guard let removed = providers.removeValue(forKey: providerID) else {
            throw CoreError(code: .provider, message: "Provider \(providerID) 不在 providers.json 中")
        }
        let selected = snapshot.providers.model?.hasPrefix("\(providerID)/") == true ? nil : snapshot.providers.model
        try await store.saveProviders(Self.rebuiltProviders(snapshot.providers, model: selected, providers: providers))
        if envelope.payload.deleteCredential, let reference = Self.vaultReference(removed.options.apiKey) {
            try await requireCredentialStore().removeSecret(for: reference)
        }
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    // MARK: - MCP

    public func listMCPServerConfigurations(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[MCPServerConfigurationDetail]> {
        let snapshot = try await requireConfigurationStore().load()
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                payload: snapshot.mcp.servers.map(Self.mcpDetail))
    }

    public func saveMCPServerConfiguration(envelope: CommandEnvelope<SaveMCPServerRequest>) async throws -> CommandReceipt<MCPServerConfigurationDetail> {
        let request = envelope.payload
        let id = request.id.trimmingCharacters(in: .whitespaces)
        try Self.validateIdentifier(id, what: "服务器 ID")
        guard request.timeoutSeconds >= 0 else { throw CoreError(code: .toolArgumentInvalid, message: "超时不能为负数") }

        let store = try requireConfigurationStore()
        var snapshot = try await store.load()
        let index = snapshot.mcp.servers.firstIndex { $0.id == id }
        let existing = index.map { snapshot.mcp.servers[$0] }

        var command: String?
        var arguments: [String] = []
        var endpoint: String?
        var environment: [MCPEnvironmentCredential] = []
        switch request.transport {
        case .stdio:
            command = try Self.resolveCommand(request.command)
            arguments = request.arguments.filter { !$0.isEmpty }
            environment = try await updateEnvironment(request.environment, serverID: id,
                                                      current: existing?.environment ?? [])
        case .streamableHTTP:
            let value = (request.endpoint ?? "").trimmingCharacters(in: .whitespaces)
            _ = try ConfigurationEndpointPolicy.resolve(value, path: "$.servers.\(id).endpoint")
            endpoint = value
            // A server that switched away from stdio leaves no env secrets behind.
            _ = try await updateEnvironment([], serverID: id, current: existing?.environment ?? [])
        }

        let credentialRef = CredentialRef("mcp-\(id)-secret")
        var authentication = MCPAuthenticationConfiguration()
        switch request.authentication {
        case .none:
            if let old = existing?.authentication.credential {
                try await requireCredentialStore().removeSecret(for: old)
            }
        case .bearer, .header:
            if request.authentication == .header,
               (request.headerName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                throw CoreError(code: .toolArgumentInvalid, message: "自定义请求头认证需要请求头名称")
            }
            let source = try await updateSecret(request.credential,
                                                current: existing?.authentication.credential.map { "{vault:\($0.rawValue)}" },
                                                reference: credentialRef)
            guard let reference = Self.vaultReference(source) else {
                throw CoreError(code: .toolArgumentInvalid, message: "认证方式需要凭据")
            }
            authentication = MCPAuthenticationConfiguration(
                kind: request.authentication == .bearer ? .bearer : .header,
                headerName: request.authentication == .header ? request.headerName : nil,
                credential: reference)
        }

        let server = StoredMCPServerConfiguration(
            id: id,
            alias: request.alias.trimmingCharacters(in: .whitespaces).isEmpty ? id : request.alias,
            transport: request.transport == .stdio ? .stdio : .streamableHTTP,
            command: command,
            arguments: arguments,
            endpoint: endpoint,
            protocolPreference: StoredMCPProtocolPreference(rawValue: request.protocolPreference.rawValue) ?? .auto,
            enabled: request.enabled,
            authentication: authentication,
            environment: environment,
            timeoutSeconds: request.timeoutSeconds)
        if let index {
            snapshot.mcp.servers[index] = server
        } else {
            snapshot.mcp.servers.append(server)
        }
        try await store.saveMCP(snapshot.mcp)
        await notifyExtensionCatalogChanged()
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: Self.mcpDetail(server))
    }

    public func deleteMCPServerConfiguration(envelope: CommandEnvelope<DeleteMCPServerRequest>) async throws -> CommandReceipt<VoidResult> {
        let store = try requireConfigurationStore()
        var snapshot = try await store.load()
        guard let index = snapshot.mcp.servers.firstIndex(where: { $0.id == envelope.payload.id }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "MCP 服务器 \(envelope.payload.id) 不存在")
        }
        let removed = snapshot.mcp.servers.remove(at: index)
        try await store.saveMCP(snapshot.mcp)
        let credentials = try requireCredentialStore()
        for reference in [removed.authentication.credential].compactMap({ $0 }) + removed.environment.map(\.credential)
        where !reference.rawValue.hasPrefix("env:") {
            try await credentials.removeSecret(for: reference)
        }
        await notifyExtensionCatalogChanged()
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    // MARK: - Secrets

    /// Applies a secret change and returns the `{vault:…}` / `{env:…}` source to store.
    private func updateSecret(_ update: SecretUpdate, current: String?, reference: CredentialRef) async throws -> String? {
        switch update {
        case .keep:
            return current
        case .clear:
            if let old = Self.vaultReference(current) {
                try await requireCredentialStore().removeSecret(for: old)
            }
            return nil
        case .replace(let value):
            let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "密钥不能为空") }
            try await requireCredentialStore().setSecret(secret, for: reference)
            return "{vault:\(reference.rawValue)}"
        }
    }

    private func updateEnvironment(_ updates: [MCPEnvironmentVariableUpdate], serverID: String,
                                   current: [MCPEnvironmentCredential]) async throws -> [MCPEnvironmentCredential] {
        var result: [MCPEnvironmentCredential] = []
        var seen = Set<String>()
        for update in updates {
            let name = update.name.trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw CoreError(code: .toolArgumentInvalid, message: "环境变量名无效: \(update.name)")
            }
            guard seen.insert(name).inserted else {
                throw CoreError(code: .toolArgumentInvalid, message: "环境变量重复: \(name)")
            }
            let old = current.first { $0.name == name }
            let source = try await updateSecret(update.value,
                                                current: old.map { Self.credentialSource($0.credential) },
                                                reference: CredentialRef("mcp-\(serverID)-env-\(name)"))
            guard let source else { continue }
            guard let reference = Self.credentialReference(source) else {
                throw CoreError(code: .toolArgumentInvalid, message: "环境变量 \(name) 没有值")
            }
            result.append(MCPEnvironmentCredential(name: name, credential: reference))
        }
        let credentials = try requireCredentialStore()
        for old in current where !result.contains(where: { $0.credential == old.credential })
            && !old.credential.rawValue.hasPrefix("env:") {
            try await credentials.removeSecret(for: old.credential)
        }
        return result
    }

    // MARK: - Mapping

    /// `ProvidersConfiguration` encodes from its internal account/profile
    /// form, so edits to `providers` only persist through this initializer.
    private static func rebuiltProviders(_ current: ProvidersConfiguration, model: String?,
                                         providers: [String: PublicProviderConfiguration]) -> ProvidersConfiguration {
        ProvidersConfiguration(schema: current.schema, version: current.version, model: model, providers: providers)
    }

    static func providerDetail(_ providerID: String, _ provider: PublicProviderConfiguration) -> ProviderConfigurationDetail {
        ProviderConfigurationDetail(
            providerID: providerID,
            name: provider.name,
            adapter: provider.adapter,
            baseURL: provider.options.baseURL,
            apiKeyHeader: provider.options.apiKeyHeader,
            headers: provider.options.headers,
            apiKey: secretSource(provider.options.apiKey),
            models: provider.models.keys.sorted().map { id in
                let model = provider.models[id]!
                return ProviderModelConfigurationDetail(
                    modelID: id,
                    name: model.name,
                    contextWindow: model.limit.context,
                    maxOutputTokens: model.limit.output,
                    reasoning: model.reasoning,
                    toolCalling: model.toolCalling,
                    parallelToolCalling: model.parallelToolCalling,
                    vision: model.vision,
                    structuredOutput: model.structuredOutput,
                    tokensPerMinute: model.rateLimits.tpm,
                    requestsPerMinute: model.rateLimits.rpm,
                    maxConcurrentRequests: model.rateLimits.maxConcurrentRequests,
                    maxRetries: model.rateLimits.retryPolicy.maxRetries,
                    initialRetryDelayMilliseconds: model.rateLimits.retryPolicy.initialDelayMilliseconds,
                    maxRetryDelayMilliseconds: model.rateLimits.retryPolicy.maxDelayMilliseconds,
                    retryJitterRatio: model.rateLimits.retryPolicy.jitterRatio)
            })
    }

    static func mcpDetail(_ server: StoredMCPServerConfiguration) -> MCPServerConfigurationDetail {
        MCPServerConfigurationDetail(
            id: server.id,
            alias: server.alias,
            transport: server.transport == .stdio ? .stdio : .streamableHTTP,
            command: server.command,
            arguments: server.arguments,
            endpoint: server.endpoint,
            protocolPreference: MCPServerProtocolPreference(rawValue: server.protocolPreference.rawValue) ?? .auto,
            enabled: server.enabled,
            authentication: MCPAuthenticationKind(rawValue: server.authentication.kind.rawValue) ?? .none,
            headerName: server.authentication.headerName,
            credential: server.authentication.credential.map { secretSource(credentialSource($0)) } ?? .none,
            environment: server.environment.map {
                MCPEnvironmentVariableDetail(name: $0.name, value: secretSource(credentialSource($0.credential)))
            },
            timeoutSeconds: server.timeoutSeconds)
    }

    private static func secretSource(_ source: String?) -> SecretSource {
        guard let source, !source.isEmpty else { return .none }
        if source.hasPrefix("{env:") && source.hasSuffix("}") {
            return .environment(name: String(source.dropFirst(5).dropLast()))
        }
        return .vault
    }

    private static func vaultReference(_ source: String?) -> CredentialRef? {
        guard let source, source.hasPrefix("{vault:"), source.hasSuffix("}") else { return nil }
        return CredentialRef(String(source.dropFirst(7).dropLast()))
    }

    /// `{vault:X}` / `{env:NAME}` → the reference the stores use (`X` / `env:NAME`).
    private static func credentialReference(_ source: String) -> CredentialRef? {
        if source.hasPrefix("{env:") && source.hasSuffix("}") { return CredentialRef("env:\(source.dropFirst(5).dropLast())") }
        return vaultReference(source)
    }

    private static func credentialSource(_ reference: CredentialRef) -> String {
        reference.rawValue.hasPrefix("env:") ? "{env:\(reference.rawValue.dropFirst(4))}" : "{vault:\(reference.rawValue)}"
    }

    private static func validateIdentifier(_ value: String, what: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw CoreError(code: .toolArgumentInvalid, message: "\(what) 只能包含字母、数字、点、下划线和连字符，且不超过 64 个字符")
        }
    }

    /// stdio servers run by absolute path; a bare name is resolved on PATH now,
    /// so the stored file never depends on the shell that happens to start Core.
    private static func resolveCommand(_ command: String?) throws -> String {
        let value = (command ?? "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "本地进程需要命令") }
        if LingXiPlatform.path.isAbsolute(value) {
            guard FileManager.default.isExecutableFile(atPath: value) else {
                throw CoreError(code: .toolArgumentInvalid, message: "命令不存在或不可执行: \(value)")
            }
            return value
        }
        guard let resolved = LingXiPlatform.process.resolveExecutable(
            named: value, customSearchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]) else {
            throw CoreError(code: .toolArgumentInvalid, message: "在 PATH 中找不到命令: \(value)")
        }
        return resolved
    }
}
