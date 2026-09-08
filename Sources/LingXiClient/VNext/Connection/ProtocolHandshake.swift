import Foundation
import LingXiProtocol

public struct HandshakeResult: Sendable, Equatable {
    public let clientVersion: ProtocolVersion
    public let serverVersion: ProtocolVersion
    public let runtimeInfo: RuntimeInfo
    public let capabilities: RuntimeCapabilities

    public init(
        clientVersion: ProtocolVersion,
        serverVersion: ProtocolVersion,
        runtimeInfo: RuntimeInfo,
        capabilities: RuntimeCapabilities
    ) {
        self.clientVersion = clientVersion
        self.serverVersion = serverVersion
        self.runtimeInfo = runtimeInfo
        self.capabilities = capabilities
    }
}

public enum HandshakeError: Error, Sendable, Equatable {
    case incompatibleVersion(client: ProtocolVersion, server: ProtocolVersion)
    case unsupportedMode(AgentMode)
    case transportError(String)
}

public struct ProtocolHandshake: Sendable {
    public let clientVersion: ProtocolVersion
    public let requiredModes: [AgentMode]

    public init(
        clientVersion: ProtocolVersion = .current,
        requiredModes: [AgentMode] = []
    ) {
        self.clientVersion = clientVersion
        self.requiredModes = requiredModes
    }

    public func perform(service: any LingXiProtocolService) async throws -> HandshakeResult {
        // 1. Fetch runtime info
        let infoResp = try await service.getRuntimeInfo(envelope: QueryEnvelope(payload: VoidResult()))
        let runtimeInfo = infoResp.payload
        let serverVersion = runtimeInfo.protocolVersion

        // 2. Validate version compatibility
        guard clientVersion.isCompatible(with: serverVersion) else {
            throw HandshakeError.incompatibleVersion(client: clientVersion, server: serverVersion)
        }

        // 3. Negotiate capabilities
        let capResp = try await service.getRuntimeCapabilities(envelope: QueryEnvelope(payload: VoidResult()))
        let capabilities = capResp.payload

        for mode in requiredModes {
            guard capabilities.supportedModes.contains(mode) else {
                throw HandshakeError.unsupportedMode(mode)
            }
        }

        return HandshakeResult(
            clientVersion: clientVersion,
            serverVersion: serverVersion,
            runtimeInfo: runtimeInfo,
            capabilities: capabilities
        )
    }
}
