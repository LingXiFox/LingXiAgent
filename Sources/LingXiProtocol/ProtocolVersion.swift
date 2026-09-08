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

    /// 冻结契约版本：v1.0
    public static let current = ProtocolVersion(major: 1, minor: 0)

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
