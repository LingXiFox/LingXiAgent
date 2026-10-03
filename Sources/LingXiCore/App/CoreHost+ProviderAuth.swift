import Foundation
import LingXiProtocol

// Provider sign-in and pre-save connection tests.
//
// The GUI starts a flow, opens the returned URL in the system browser and polls
// the phase; Core holds the callback listener, exchanges the code and writes the
// tokens to the vault. A draft connection test reads its secret from the vault by
// reference, so an unsaved API key is handed to Core once and never travels again
// inside a runtime DTO.

extension CoreHost {

    // MARK: - Connection tests

    /// Tests a provider that is not saved yet.
    public func testProviderDraft(envelope: CommandEnvelope<TestProviderDraftRequest>) async throws -> CommandReceipt<TestProviderResult> {
        let request = envelope.payload
        var adapter = request.adapter
        var baseURL = request.baseURL.trimmingCharacters(in: .whitespaces)
        var apiKeyHeader = request.apiKeyHeader
        var headers = request.headers

        // LM Studio is tested at the address the user typed, as a local runtime; the catalog's
        // localhost default is only a fallback. Everything below then treats it as custom.
        var isLMStudio = false
        if request.productID == Self.lmStudioProductID {
            isLMStudio = true
            adapter = "openai-compatible"
            if baseURL.isEmpty { baseURL = Self.lmStudioDefaultEndpoint }
        }
        if !isLMStudio, let productID = request.productID?.trimmingCharacters(in: .whitespaces), !productID.isEmpty {
            // A registry product: Core knows its endpoint, wire and headers.
            guard let definition = BuiltinProviderCatalog.definition(id: productID),
                  let endpoint = definition.endpoints.first, let resolved = endpoint.baseURL else {
                throw CoreError(code: .provider, message: "\(productID) 的端点尚未验证，无法测试连接")
            }
            switch endpoint.wire {
            case .anthropicMessages: adapter = "anthropic-messages"
            case .openAIResponses: adapter = "openai-responses"
            default: adapter = "openai-compatible"
            }
            baseURL = resolved.absoluteString
            headers = endpoint.requiredHeaders
            if case let .apiKeyHeader(name) = endpoint.requestAuthentication { apiKeyHeader = name }
        } else {
            guard Self.editableAdapters.contains(adapter) else {
                throw CoreError(code: .toolArgumentInvalid, message: "不支持的接口类型: \(adapter)")
            }
            // Same normalisation as save, so the test exercises the URL that will be stored.
            baseURL = ProviderBaseURLNormalizer.normalize(baseURL, adapter: adapter)
            _ = try ConfigurationEndpointPolicy.resolve(baseURL, path: "$.draft.baseURL")
        }

        var secret: String?
        if let reference = request.credentialRef {
            secret = try await requireCredentialStore().secret(for: reference)
        }
        let result: TestProviderResult
        do {
            let outcome = try await ProviderConnectivityProbe.probe(
                baseURL: baseURL, adapter: adapter, apiKeyHeader: apiKeyHeader,
                credential: secret, headers: headers)
            // Only a custom OpenAI-compatible endpoint is asked whether it is LM Studio; a registry
            // product never is, and a native answer is required, not inferred from the model list.
            var detected: LocalInferenceBackend?
            if request.productID == nil || isLMStudio, adapter == "openai-compatible", let first = outcome.modelIDs.first {
                let status = await LMStudioDiscovery.discover(baseURL: baseURL, modelID: first, credential: secret)
                if status.source == .native { detected = .lmStudio }
            }
            let parts = [outcome.models > 0 ? "\(outcome.models) 个模型" : nil,
                         detected == .lmStudio ? "已识别为 LM Studio" : nil].compactMap { $0 }
            result = TestProviderResult(providerID: Self.draftProviderID, reachable: true,
                                        latencyMs: outcome.latencyMs,
                                        message: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                        models: outcome.modelIDs.isEmpty ? nil : outcome.modelIDs,
                                        resolvedBaseURL: baseURL,
                                        localRuntime: detected)
        } catch {
            result = TestProviderResult(providerID: Self.draftProviderID, reachable: false,
                                        message: Self.providerTestMessage(error),
                                        resolvedBaseURL: baseURL)
        }
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: result)
    }

    static let draftProviderID = "draft"

    /// Adapters the settings form may write and test.
    static let editableAdapters = ["openai-compatible", "openai-responses", "anthropic-messages"]

    static func providerTestMessage(_ error: Error) -> String {
        if let core = error as? CoreError { return core.message }
        return error.localizedDescription
    }

    /// Maps a catalog product's protocol family onto the adapter the probe knows.
    static func testAdapter(for family: String) -> String {
        switch family.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "anthropic-messages", "anthropicmessages": "anthropic-messages"
        case "responses", "openai-responses": "openai-responses"
        default: "openai-compatible"
        }
    }

    // MARK: - Sign-in flows

    public func listProviderAuthProducts(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAuthProduct]> {
        ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                         payload: ProviderAuthCoordinator.authProducts())
    }

    /// Curated registry plus the published models.lingxifox.cn index.
    public func getProviderCatalog(envelope: QueryEnvelope<GetProviderCatalogRequest>) async throws -> ResponseEnvelope<[ProviderCatalogEntry]> {
        ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                         payload: await ProviderCatalog.entries(refresh: envelope.payload.refresh,
                                                                catalogClient: modelsCatalogClient))
    }

    /// Saved endpoints supply their own roster; the published catalog is the fallback.
    /// The stored key stays inside Core. An empty roster always says why.
    public func getProviderCatalogModels(envelope: QueryEnvelope<GetProviderCatalogModelsRequest>) async throws -> ResponseEnvelope<ProviderModelRoster> {
        let entryID = envelope.payload.entryID
        let remote = await remoteModelIDs(providerID: entryID)
        if !remote.ids.isEmpty {
            let filtered = await filteringUnavailableModels(remote.ids, providerID: entryID)
            var note: String?
            if filtered.kept.isEmpty, !filtered.hidden.isEmpty {
                note = "端点列出的 \(filtered.hidden.count) 个模型，当前账号一个都用不了（套餐不含）。"
            } else if !filtered.hidden.isEmpty {
                note = "已隐藏 \(filtered.hidden.count) 个当前账号套餐不含的模型。"
            }
            return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                    payload: ProviderModelRoster(models: filtered.kept, note: note))
        }
        let published = await ProviderCatalog.modelIDs(entryID: entryID, catalogClient: modelsCatalogClient)
        if !published.isEmpty {
            return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                    payload: ProviderModelRoster(models: published))
        }
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                payload: ProviderModelRoster(
                                    models: [],
                                    note: remote.note ?? "端点未配置，且 models.lingxifox.cn 索引没有该提供商的条目。"))
    }


    public func beginProviderAuth(envelope: CommandEnvelope<BeginProviderAuthRequest>) async throws -> CommandReceipt<ProviderAuthFlow> {
        let productID = envelope.payload.productID.trimmingCharacters(in: .whitespaces)
        let coordinator = try await requireProviderAuthCoordinator()
        let started = try await coordinator.begin(productID: productID)
        let flow = ProviderAuthFlow(flowID: started.flowID, productID: productID,
                                    authorizeURL: started.authorizeURL, phase: .awaitingCallback)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: flow)
    }

    public func getProviderAuthFlow(envelope: QueryEnvelope<GetProviderAuthFlowRequest>) async throws -> ResponseEnvelope<ProviderAuthFlow> {
        guard let coordinator = providerAuthCoordinator else {
            throw CoreError(code: .provider, message: "当前没有进行中的登录流程")
        }
        guard let flow = await coordinator.status(flowID: envelope.payload.flowID) else {
            throw CoreError(code: .provider, message: "登录流程已过期")
        }
        // The first read of a finished login folds the new account into the
        // runtime, so the provider list shows it without another Core reload.
        if flow.phase == .connected && !appliedAuthFlows.contains(flow.flowID) {
            appliedAuthFlows.insert(flow.flowID)
            await reassembleCurrentModel(ifProvider: flow.productID)
            await notifyProviderCatalogChanged()
        }
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision, payload: flow)
    }

    public func cancelProviderAuth(envelope: CommandEnvelope<CancelProviderAuthRequest>) async throws -> CommandReceipt<VoidResult> {
        await providerAuthCoordinator?.cancel(flowID: envelope.payload.flowID)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }
}
