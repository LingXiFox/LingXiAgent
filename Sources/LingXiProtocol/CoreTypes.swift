import Foundation

/// Core 基础信息。
public struct CoreInfo: Sendable, Equatable, Codable {
    public let name: String
    public let version: String
    public let protocolVersion: String

    public init(name: String, version: String, protocolVersion: String) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

/// Core 生命周期状态。
public enum CoreState: String, Sendable, Equatable, Codable {
    case starting
    case ready
    case shuttingDown
    case stopped
}
