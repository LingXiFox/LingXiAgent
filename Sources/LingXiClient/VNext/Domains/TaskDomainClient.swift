import Foundation
import LingXiProtocol

public struct TaskDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func create(
        sessionID: SessionID,
        objective: String,
        projectID: String = "default",
        successCriteria: [SuccessCriterion] = [],
        limits: TaskLimits = TaskLimits()
    ) async throws -> CommandReceipt<TaskSnapshot> {
        let req = CreateTaskRequest(
            sessionID: sessionID,
            objective: objective,
            projectID: projectID,
            successCriteria: successCriteria,
            limits: limits
        )
        return try await transport.createTask(envelope: CommandEnvelope(payload: req))
    }

    public func get(taskID: TaskID) async throws -> TaskSnapshot {
        let req = GetTaskRequest(taskID: taskID)
        let resp = try await transport.getTask(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func list(sessionID: SessionID? = nil, projectID: String? = nil) async throws -> [TaskSnapshot] {
        let req = ListTasksRequest(sessionID: sessionID, projectID: projectID)
        let resp = try await transport.listTasks(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func pause(taskID: TaskID, reason: String? = nil) async throws -> CommandReceipt<TaskSnapshot> {
        let req = TaskLifecycleRequest(taskID: taskID, command: .pause, reason: reason)
        return try await transport.pauseTask(envelope: CommandEnvelope(payload: req))
    }

    public func resume(taskID: TaskID) async throws -> CommandReceipt<TaskSnapshot> {
        let req = TaskLifecycleRequest(taskID: taskID, command: .resume)
        return try await transport.resumeTask(envelope: CommandEnvelope(payload: req))
    }

    public func cancel(taskID: TaskID, reason: String? = nil) async throws -> CommandReceipt<TaskSnapshot> {
        let req = TaskLifecycleRequest(taskID: taskID, command: .cancel, reason: reason)
        return try await transport.cancelTask(envelope: CommandEnvelope(payload: req))
    }

    public func fork(sourceTaskID: TaskID, newSessionID: SessionID? = nil) async throws -> CommandReceipt<TaskSnapshot> {
        let req = ForkTaskRequest(sourceTaskID: sourceTaskID, newSessionID: newSessionID)
        return try await transport.forkTask(envelope: CommandEnvelope(payload: req))
    }

    public func updateCriteria(taskID: TaskID, criteria: [SuccessCriterion]) async throws -> CommandReceipt<TaskSnapshot> {
        let req = UpdateTaskCriteriaRequest(taskID: taskID, criteria: criteria)
        return try await transport.updateTaskCriteria(envelope: CommandEnvelope(payload: req))
    }

    public func listArtifacts(taskID: TaskID) async throws -> [TaskArtifact] {
        let req = GetTaskRequest(taskID: taskID)
        let resp = try await transport.listTaskArtifacts(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getReport(taskID: TaskID) async throws -> TaskReport? {
        let req = GetTaskRequest(taskID: taskID)
        let resp = try await transport.getTaskReport(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func finalize(taskID: TaskID, action: TaskFinalizeAction, message: String? = nil) async throws -> CommandReceipt<TaskSnapshot> {
        let req = TaskFinalizeRequest(taskID: taskID, action: action, message: message)
        return try await transport.finalizeTask(envelope: CommandEnvelope(payload: req))
    }

    public func filterArtifacts(in snapshot: TaskSnapshot, by kind: ArtifactKind) -> [TaskArtifact] {
        snapshot.capsule.artifacts.filter { $0.artifactKind == kind }
    }

    public func filterArtifacts(_ artifacts: [TaskArtifact], by kind: ArtifactKind) -> [TaskArtifact] {
        artifacts.filter { $0.artifactKind == kind }
    }
}
