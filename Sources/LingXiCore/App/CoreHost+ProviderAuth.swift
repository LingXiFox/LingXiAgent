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
        guard Self.editableAdapters.contains(request.adapter) else {
            throw CoreError(code: .toolArgumentInvalid, message: "不支持的接口类型: \(request.adapter)")
        }
        let baseURL = request.baseURL.trimmingCharacters(in: .whitespaces)
        _ = try ConfigurationEndpointPolicy.resolve(baseURL, path: "$.draft.baseURL")

        var secret: String?
        if let reference = request.credentialRef {
            secret = try await requireCredentialStore().secret(for: reference)
        }
        let result: TestProviderResult
        do {
            let outcome = try await ProviderConnectivityProbe.probe(
                baseURL: baseURL, adapter: request.adapter, apiKeyHeader: request.apiKeyHeader,
                credential: secret, headers: request.headers)
            result = TestProviderResult(providerID: Self.draftProviderID, reachable: true,
                                        latencyMs: outcome.latencyMs,
                                        message: outcome.models > 0 ? "\(outcome.models) 个模型" : nil)
        } catch {
            result = TestProviderResult(providerID: Self.draftProviderID, reachable: false,
                                        message: Self.providerTestMessage(error))
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
        }
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision, payload: flow)
    }

    public func cancelProviderAuth(envelope: CommandEnvelope<CancelProviderAuthRequest>) async throws -> CommandReceipt<VoidResult> {
        await providerAuthCoordinator?.cancel(flowID: envelope.payload.flowID)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }
}
