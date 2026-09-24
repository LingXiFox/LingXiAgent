import Foundation

/// 任务全局唯一标识符 (TaskID)
public struct TaskID: RawRepresentable, Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
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

    public static func generate() -> TaskID {
        TaskID("task_\(UUID().uuidString.lowercased())")
    }
}
