import Foundation

/// 任务生命周期日志事件实体 (TaskEventPayload)
public struct TaskEventPayload: Sendable, Codable, Equatable {
    public let seq: Int64?
    public let taskID: TaskID
    public let event: String
    public let fromState: TaskState?
    public let toState: TaskState
    public let payload: [String: String]
    public let correlationID: String?
    public let createdAt: Date

    public init(
        seq: Int64? = nil,
        taskID: TaskID,
        event: String,
        fromState: TaskState? = nil,
        toState: TaskState,
        payload: [String: String] = [:],
        correlationID: String? = nil,
        createdAt: Date = .now
    ) {
        self.seq = seq
        self.taskID = taskID
        self.event = event
        self.fromState = fromState
        self.toState = toState
        self.payload = payload
        self.correlationID = correlationID
        self.createdAt = createdAt
    }
}
