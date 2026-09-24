import Foundation

/// 任务生命周期状态 (TaskState)
public enum TaskState: String, Sendable, Codable, Equatable, Hashable {
    case queued
    case running
    case waiting
    case paused
    case verifying
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TaskState(rawValue: raw) ?? .unknown
    }

    /// 是否为终态
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running, .waiting, .paused, .verifying, .unknown:
            return false
        }
    }

    /// 允许流转的目标状态集合
    public var allowedTransitions: Set<TaskState> {
        switch self {
        case .queued:
            return [.running, .cancelled]
        case .running:
            // verifying declared for V1.2, not producible in V1.1 runtime
            return [.waiting, .paused, .completed, .failed, .cancelled]
        case .waiting:
            return [.running, .paused, .cancelled, .failed]
        case .paused:
            return [.running, .cancelled]
        case .verifying:
            return [.completed, .failed, .running]
        case .completed, .failed, .cancelled, .unknown:
            return []
        }
    }
}
