import Foundation
import LingXiProtocol

/// 任务恢复点管理服务
public final class TaskResumeStore: Sendable {
    private let persistence: any TaskPersistence

    public init(persistence: any TaskPersistence) {
        self.persistence = persistence
    }

    public func latestResumePoint(for taskID: TaskID) async throws -> ResumePoint? {
        guard let capsule = try await persistence.loadCapsule(taskID: taskID) else { return nil }
        return capsule.resumePoint
    }
}
