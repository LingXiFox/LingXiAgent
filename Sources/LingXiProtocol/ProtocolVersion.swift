import Foundation

/// ProtocolVersion 定义主次版本。
/// Major 不兼容则拒绝连接；Minor 差异进行 capability negotiation。
public struct ProtocolVersion: Codable, Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// 当前契约版本：v1.1
    public static let current = ProtocolVersion(major: 1, minor: 1)

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        if lhs.major == rhs.major {
            return lhs.minor < rhs.minor
        }
        return lhs.major < rhs.major
    }

    public func isCompatible(with clientVersion: ProtocolVersion) -> Bool {
        return self.major == clientVersion.major
    }
}

/// Protocol capability feature flags for negotiation between Core and Clients.
public enum ProtocolFeature: String, Codable, Sendable, CaseIterable {
    case taskPause = "task.pause"
    case taskResume = "task.resume"
    case taskFork = "task.fork"
    case workspaceFork = "workspace.fork"
    case capabilityGateway = "capability.gateway"
    case traceStream = "trace.stream"
    case traceQuery = "trace.query"
    case unknown = "unknown"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ProtocolFeature(rawValue: raw) ?? .unknown
    }

    /// Known active protocol features excluding fallback unknown case.
    public static var knownFeatures: [ProtocolFeature] {
        allCases.filter { $0 != .unknown }
    }
}

/// 跨两端统一的协议常量 (Audit Round 10 Phase C)
public enum ProtocolConstants {
    /// 统一 VNext JSON-lines frame 大小上限 (32MB)
    public static let maxFrameBytes: Int = 32 * 1024 * 1024
}
