import Foundation

/// 任务生命周期控制指令
public enum TaskLifecycleCommand: String, Sendable, Codable, Equatable {
    case start
    case pause
    case resume
    case cancel
    case complete
    case fail
    case enterWaiting
}

public struct TaskLifecycleRequest: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public let command: TaskLifecycleCommand
    public let reason: String?
    public let waitingReason: WaitingReason?
    public let payload: [String: String]

    public init(
        taskID: TaskID,
        command: TaskLifecycleCommand,
        reason: String? = nil,
        waitingReason: WaitingReason? = nil,
        payload: [String: String] = [:]
    ) {
        self.taskID = taskID
        self.command = command
        self.reason = reason
        self.waitingReason = waitingReason
        self.payload = payload
    }
}
