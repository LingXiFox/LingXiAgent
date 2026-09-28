import Foundation
import LingXiProtocol

extension CoreHost {
    public func createTask(envelope: CommandEnvelope<CreateTaskRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        let request = envelope.payload
        let objective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw CoreError(code: .toolArgumentInvalid, message: "Task objective is empty")
        }
        let capsule = TaskCapsule(sessionID: request.sessionID, projectID: request.projectID,
                                  objective: objective, successCriteria: request.successCriteria)
        try await taskRuntime.register(capsule: capsule)
        return taskReceipt(envelope.commandID, capsule)
    }

    public func getTask(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskSnapshot> {
        let capsule = try await loadTask(envelope.payload.taskID)
        return ResponseEnvelope(requestID: envelope.requestID, revision: UInt64(capsule.revision),
                                payload: TaskSnapshot(capsule: capsule))
    }

    public func listTasks(envelope: QueryEnvelope<ListTasksRequest>) async throws -> ResponseEnvelope<[TaskSnapshot]> {
        let request = envelope.payload
        var indexed: [TaskID: TaskCapsule] = [:]
        if let persistence {
            for capsule in try await persistence.listCapsules(sessionID: request.sessionID) {
                indexed[capsule.taskID] = capsule
            }
        }
        for capsule in await taskRuntime.listCapsules(sessionID: request.sessionID, projectID: request.projectID) {
            indexed[capsule.taskID] = capsule
        }
        let result = indexed.values.filter { request.projectID == nil || $0.projectID == request.projectID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { TaskSnapshot(capsule: $0) }
        return ResponseEnvelope(requestID: envelope.requestID, payload: result)
    }

    public func pauseTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        try await transitionTask(envelope, command: .pause)
    }

    public func resumeTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        try await transitionTask(envelope, command: .resume)
    }

    public func cancelTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        try await transitionTask(envelope, command: .cancel)
    }

    public func forkTask(envelope: CommandEnvelope<ForkTaskRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        let source = try await loadTask(envelope.payload.sourceTaskID)
        let capsule = TaskCapsule(parentTaskID: source.taskID, forkedFromTaskID: source.taskID,
                                  workspaceID: source.workspaceID,
                                  sessionID: envelope.payload.newSessionID ?? source.sessionID,
                                  projectID: source.projectID, objective: source.objective,
                                  successCriteria: source.successCriteria,
                                  modelSelection: source.modelSelection)
        try await taskRuntime.register(capsule: capsule)
        return taskReceipt(envelope.commandID, capsule)
    }

    public func updateTaskCriteria(envelope: CommandEnvelope<UpdateTaskCriteriaRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        var capsule = try await loadTask(envelope.payload.taskID)
        guard !capsule.state.isTerminal else {
            throw CoreError(code: .invalidTaskTransition, message: "Cannot update terminal task")
        }
        capsule.successCriteria = envelope.payload.criteria
        capsule.revision += 1
        capsule.updatedAt = .now
        try await taskRuntime.register(capsule: capsule)
        return taskReceipt(envelope.commandID, capsule)
    }

    public func listTaskArtifacts(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<[TaskArtifact]> {
        let capsule = try await loadTask(envelope.payload.taskID)
        return ResponseEnvelope(requestID: envelope.requestID, revision: UInt64(capsule.revision), payload: capsule.artifacts)
    }

    public func getTaskReport(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskReport?> {
        let capsule = try await loadTask(envelope.payload.taskID)
        return ResponseEnvelope(requestID: envelope.requestID, revision: UInt64(capsule.revision), payload: nil)
    }

    public func finalizeTask(envelope: CommandEnvelope<TaskFinalizeRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        let command: TaskLifecycleCommand = envelope.payload.action == .discard ? .cancel : .complete
        let capsule = try await loadTask(envelope.payload.taskID)
        let result = try await taskRuntime.transition(taskID: capsule.taskID, command: command,
                                                       reason: envelope.payload.message)
        return taskReceipt(envelope.commandID, result)
    }

    private func transitionTask(_ envelope: CommandEnvelope<TaskLifecycleRequest>,
                                command: TaskLifecycleCommand) async throws -> CommandReceipt<TaskSnapshot> {
        let capsule = try await loadTask(envelope.payload.taskID)
        let result = try await taskRuntime.transition(taskID: capsule.taskID, command: command,
                                                       reason: envelope.payload.reason,
                                                       waitingReason: envelope.payload.waitingReason)
        return taskReceipt(envelope.commandID, result)
    }

    private func loadTask(_ id: TaskID) async throws -> TaskCapsule {
        if let capsule = await taskRuntime.getCapsule(id) { return capsule }
        if let capsule = try await persistence?.loadCapsule(taskID: id) {
            try await taskRuntime.register(capsule: capsule)
            return capsule
        }
        throw CoreError(code: .taskNotFound, message: "Task not found: \(id.rawValue)")
    }

    private func taskReceipt(_ commandID: CommandID, _ capsule: TaskCapsule) -> CommandReceipt<TaskSnapshot> {
        CommandReceipt(commandID: commandID, applied: true, revision: UInt64(capsule.revision),
                       observedThrough: [], result: TaskSnapshot(capsule: capsule))
    }
}
