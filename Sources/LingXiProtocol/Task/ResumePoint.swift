import Foundation

/// 任务恢复点 (ResumePoint)
/// 吸收原 InterruptionFrame 字段，记录跨进程重启与任务恢复所必需的状态与代际计数
public struct ResumePoint: Sendable, Codable, Equatable, Hashable {
    public let resumePointID: String
    public let stepIndex: Int
    public let generation: Int
    public let interruptedAt: Date
    public let statePayload: [String: String]
    public let contextSnapshotRef: String?

    public init(
        resumePointID: String = UUID().uuidString,
        stepIndex: Int,
        generation: Int = 1,
        interruptedAt: Date = .now,
        statePayload: [String: String] = [:],
        contextSnapshotRef: String? = nil
    ) {
        self.resumePointID = resumePointID
        self.stepIndex = stepIndex
        self.generation = generation
        self.interruptedAt = interruptedAt
        self.statePayload = statePayload
        self.contextSnapshotRef = contextSnapshotRef
    }
}
