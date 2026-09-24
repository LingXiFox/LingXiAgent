import Foundation
import LingXiProtocol

/// 任务运行时 (TaskRuntime)
/// 任务胶囊注册表与唯一权威写者 Actor，串行化任务生命周期状态跃迁并记录事件。
public actor TaskRuntime {
    private var capsules: [TaskID: TaskCapsule] = [:]
    private var activeRootTaskBySession: [SessionID: TaskID] = [:]
    private let persistence: (any TaskPersistence)?

    public init(persistence: (any TaskPersistence)? = nil) {
        self.persistence = persistence
    }

    public func register(capsule: TaskCapsule) async throws {
        capsules[capsule.taskID] = capsule
        if capsule.parentTaskID == nil && (capsule.state == .running || capsule.state == .waiting) {
            activeRootTaskBySession[capsule.sessionID] = capsule.taskID
        }
        try await persistence?.saveCapsule(capsule)
    }

    public func getCapsule(_ id: TaskID) -> TaskCapsule? {
        capsules[id]
    }

    public func listCapsules(sessionID: SessionID? = nil, projectID: String? = nil) -> [TaskCapsule] {
        capsules.values.filter { capsule in
            if let sessionID = sessionID, capsule.sessionID != sessionID { return false }
            if let projectID = projectID, capsule.projectID != projectID { return false }
            return true
        }
    }

    public func activeRootTask(for sessionID: SessionID) -> TaskCapsule? {
        guard let taskID = activeRootTaskBySession[sessionID] else { return nil }
        return capsules[taskID]
    }

    @discardableResult
    public func transition(request: TaskLifecycleRequest) async throws -> TaskCapsule {
        try await transition(
            taskID: request.taskID,
            command: request.command,
            reason: request.reason,
            waitingReason: request.waitingReason
        )
    }

    @discardableResult
    public func transition(
        taskID: TaskID,
        command: TaskLifecycleCommand,
        reason: String? = nil,
        waitingReason: WaitingReason? = nil
    ) async throws -> TaskCapsule {
        guard var capsule = capsules[taskID] else {
            throw CoreError(code: .taskNotFound, message: "Task not found: \(taskID.rawValue)")
        }

        guard let targetState = TaskStateMachine.next(from: capsule.state, on: command) else {
            throw CoreError(code: .invalidTaskTransition, message: "Illegal task transition from \(capsule.state) on \(command)")
        }

        let fromState = capsule.state
        capsule.state = targetState
        capsule.updatedAt = .now
        capsule.revision += 1

        if targetState == .waiting {
            capsule.waitingReason = waitingReason ?? .approvalPending
        } else if targetState == .running || targetState.isTerminal {
            capsule.waitingReason = nil
        }

        if targetState == .paused || targetState == .waiting {
            capsule.resumePoint = ResumePoint(
                stepIndex: capsule.revision,
                generation: (capsule.resumePoint?.generation ?? 0) + 1,
                interruptedAt: .now,
                statePayload: reason != nil ? ["reason": reason!] : [:]
            )
        }

        capsules[taskID] = capsule

        if capsule.parentTaskID == nil {
            if targetState == .running || targetState == .waiting {
                activeRootTaskBySession[capsule.sessionID] = taskID
            } else if targetState.isTerminal || targetState == .paused {
                if activeRootTaskBySession[capsule.sessionID] == taskID {
                    activeRootTaskBySession.removeValue(forKey: capsule.sessionID)
                }
            }
        }

        if let persistence = persistence {
            try await persistence.recordEvent(
                taskID: taskID,
                event: "lifecycle.\(command.rawValue)",
                fromState: fromState,
                toState: targetState,
                payload: reason != nil ? ["reason": reason!] : [:]
            )
            try await persistence.saveCapsule(capsule)
        }

        return capsule
    }
}
