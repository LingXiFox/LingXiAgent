import Foundation
import LingXiProtocol

public struct RuntimeDomainClient: Sendable {
    private let transport: any ClientTransport
    private let replayCoordinator: EventReplayCoordinator?

    public init(transport: any ClientTransport, replayCoordinator: EventReplayCoordinator? = nil) {
        self.transport = transport
        self.replayCoordinator = replayCoordinator
    }

    public func getInfo() async throws -> RuntimeInfo {
        let resp = try await transport.getRuntimeInfo(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getHealth() async throws -> RuntimeHealth {
        let resp = try await transport.getRuntimeHealth(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getCapabilities() async throws -> RuntimeCapabilities {
        let resp = try await transport.getRuntimeCapabilities(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getEffectiveConfiguration() async throws -> EffectiveConfigurationSnapshot {
        let resp = try await transport.getEffectiveConfiguration(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func reloadConfiguration() async throws -> CommandReceipt<VoidResult> {
        try await transport.reloadConfiguration(envelope: CommandEnvelope(payload: VoidResult()))
    }

    public func updateTypedSetting(key: String, value: String) async throws -> CommandReceipt<VoidResult> {
        try await transport.updateTypedSetting(envelope: CommandEnvelope(payload: UpdateTypedSettingRequest(key: key, value: value)))
    }

    public func events(after: EventCursor? = nil) async -> AsyncStream<RuntimeEventEnvelope> {
        if let replayCoordinator {
            return await replayCoordinator.subscribeRuntimeEvents(after: after)
        }
        return await transport.subscribeRuntimeEvents(after: after)
    }
}
