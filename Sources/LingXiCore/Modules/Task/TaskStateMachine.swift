import Foundation
import LingXiProtocol

/// 任务生命周期状态机 (TaskStateMachine)
/// 严格的纯函数实现，无任何外部 I/O，依据既定转换规则计算状态迁移。
public enum TaskStateMachine {

    /// 计算下一状态；若流转非法则返回 nil
    public static func next(from currentState: TaskState, on command: TaskLifecycleCommand) -> TaskState? {
        switch (currentState, command) {
        // Queued
        case (.queued, .start):
            return .running
        case (.queued, .cancel):
            return .cancelled

        // Running
        case (.running, .enterWaiting):
            return .waiting
        case (.running, .pause):
            return .paused
        case (.running, .complete):
            return .completed
        case (.running, .fail):
            return .failed
        case (.running, .cancel):
            return .cancelled

        // Waiting
        case (.waiting, .resume), (.waiting, .start):
            return .running
        case (.waiting, .pause):
            return .paused
        case (.waiting, .cancel):
            return .cancelled
        case (.waiting, .fail):
            return .failed

        // Paused
        case (.paused, .resume), (.paused, .start):
            return .running
        case (.paused, .cancel):
            return .cancelled

        // Verifying (declared for V1.2, in V1.1 not producible by runtime)
        case (.verifying, .complete):
            return .completed
        case (.verifying, .fail):
            return .failed
        case (.verifying, .resume):
            return .running

        // Terminal states and illegal transitions
        case (.completed, _), (.failed, _), (.cancelled, _), (.unknown, _):
            return nil

        default:
            return nil
        }
    }
}
