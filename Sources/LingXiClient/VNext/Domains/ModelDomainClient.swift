import Foundation
import LingXiProtocol

public struct ModelDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list() async throws -> [ProviderModelInfo] {
        let resp = try await transport.listModels(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getSelection() async throws -> ModelSelectionInfo {
        let resp = try await transport.getModelSelection(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func select(model: String) async throws -> CommandReceipt<ModelSelectionInfo> {
        let req = SelectModelRequest(model: model)
        return try await transport.selectModel(envelope: CommandEnvelope(payload: req))
    }

    public func get(modelID: String) async throws -> ProviderModelInfo {
        let req = GetModelRequest(modelID: modelID)
        let resp = try await transport.getModel(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getCapabilities(modelID: String) async throws -> ModelCapabilitiesInfo {
        let req = GetModelCapabilitiesRequest(modelID: modelID)
        let resp = try await transport.getModelCapabilities(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func setSelection(modelID: String, sessionID: SessionID? = nil) async throws -> CommandReceipt<ModelSelectionInfo> {
        let req = SetModelSelectionRequest(modelID: modelID, sessionID: sessionID)
        return try await transport.setModelSelection(envelope: CommandEnvelope(payload: req))
    }
}
