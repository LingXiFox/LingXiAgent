import Foundation
import LingXiProtocol

public enum ConnectionStatus: String, Sendable, Equatable, Codable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case reconnecting
    case failed
}

public struct ConnectionState: Sendable, Equatable {
    public let status: ConnectionStatus
    public let detail: String?
    public let protocolVersion: ProtocolVersion?
    public let capabilities: RuntimeCapabilities?
    public let timestamp: Date

    public init(
        status: ConnectionStatus,
        detail: String? = nil,
        protocolVersion: ProtocolVersion? = nil,
        capabilities: RuntimeCapabilities? = nil,
        timestamp: Date = Date()
    ) {
        self.status = status
        self.detail = detail
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.timestamp = timestamp
    }

    public static let disconnected = ConnectionState(status: .disconnected)
    public static let connecting = ConnectionState(status: .connecting)
    public static let handshaking = ConnectionState(status: .handshaking)

    public static func connected(
        version: ProtocolVersion,
        capabilities: RuntimeCapabilities,
        detail: String? = nil
    ) -> ConnectionState {
        ConnectionState(
            status: .connected,
            detail: detail,
            protocolVersion: version,
            capabilities: capabilities
        )
    }

    public static func reconnecting(detail: String? = nil) -> ConnectionState {
        ConnectionState(status: .reconnecting, detail: detail)
    }

    public static func failed(detail: String) -> ConnectionState {
        ConnectionState(status: .failed, detail: detail)
    }
}
