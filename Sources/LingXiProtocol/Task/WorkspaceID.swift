import Foundation

/// 工作区全局唯一标识符 (WorkspaceID)
public struct WorkspaceID: RawRepresentable, Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public static func generate() -> WorkspaceID {
        WorkspaceID("ws_\(UUID().uuidString.lowercased())")
    }
}
