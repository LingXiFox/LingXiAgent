import Foundation

/// 任务点位快照 (TaskSnapshot)
public struct TaskSnapshot: Sendable, Codable, Equatable {
    public let capsule: TaskCapsule
    public let timestamp: Date

    public init(capsule: TaskCapsule, timestamp: Date = .now) {
        self.capsule = capsule
        self.timestamp = timestamp
    }
}
