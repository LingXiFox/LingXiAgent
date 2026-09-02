import Foundation
import LingXiProtocol

public struct WorkflowTaskCompletion: Sendable, Equatable {
    public let result: SubagentResult?
    public let error: CoreError?

    public init(result: SubagentResult? = nil, error: CoreError? = nil) {
        self.result = result
        self.error = error
    }
}

/// Durable DAG coordinator. It never replays a task after restart: interrupted work is recoveryRequired.
public actor WorkflowRuntime {
    public typealias Executor = @Sendable (WorkflowID, WorkflowTaskDefinition, WorkflowTaskProvenance, @escaping @Sendable (WorkflowTaskProvenance) async -> Void) async -> WorkflowTaskCompletion

    private let persistence: SQLitePersistenceStore?
    private let executor: Executor?
    private let diagnostics: RuntimeDiagnosticsStore?
    private var workflows: [WorkflowID: WorkflowSnapshot] = [:]
    private var active: [String: Task<Void, Never>] = [:]

    public init(persistence: SQLitePersistenceStore? = nil, executor: Executor? = nil, diagnostics: RuntimeDiagnosticsStore? = nil) {
        self.persistence = persistence
        self.executor = executor
        self.diagnostics = diagnostics
    }

    public func restore() async throws {
        for stored in try await persistence?.loadWorkflows() ?? [] {
            let recovered = recover(stored)
            workflows[recovered.id] = recovered
            if recovered != stored { try await persist(recovered) }
        }
    }

    public func create(id: WorkflowID = WorkflowID(UUID().uuidString), rootSessionID: SessionID, rootRunID: AgentRunID, tasks: [WorkflowTaskDefinition]) async throws -> WorkflowSnapshot {
        try validate(tasks)
        let snapshot = WorkflowSnapshot(id: id, rootSessionID: rootSessionID, rootRunID: rootRunID, tasks: tasks.map { WorkflowTaskState(definition: $0) })
        workflows[id] = snapshot
        await diagnostics?.record(kind: .workflow, event: "workflow.created", sessionID: rootSessionID, runID: rootRunID, workflowID: id, metadata: ["taskCount": String(tasks.count)])
        try await persist(snapshot)
        await schedule(id)
        return workflows[id]!
    }

    public func workflow(_ id: WorkflowID) throws -> WorkflowSnapshot {
        guard let workflow = workflows[id] else { throw CoreError(code: .resourceNotFound, message: "Workflow 不存在: \(id.rawValue)") }
        return workflow
    }

    public func allWorkflows() -> [WorkflowSnapshot] { workflows.values.sorted { $0.createdAt < $1.createdAt } }

    public func readyTasks(_ id: WorkflowID) throws -> [WorkflowTaskID] {
        let workflow = try workflow(id)
        return workflow.tasks.filter { $0.status == .pending && dependenciesCompleted($0, in: workflow) }.map(\.definition.id)
    }

    /// Stores the origin-owned input request. The actual continuation remains in the originating runtime only.
    public func suspend(workflowID: WorkflowID, taskID: WorkflowTaskID, input: WorkflowPendingInput) async throws {
        var workflow = try workflow(workflowID)
        guard let index = workflow.tasks.firstIndex(where: { $0.definition.id == taskID }) else { throw CoreError(code: .resourceNotFound, message: "Workflow Task 不存在") }
        let status: WorkflowTaskStatus
        switch input {
        case .question: status = .waitingForQuestion
        case .permission: status = .waitingForPermission
        case .decision: status = .waitingForDecision
        }
        workflow = replacing(workflow, task: replace(workflow.tasks[index], status: status, pendingInput: input), status: .waitingForUser, checkpoint: checkpoint(workflow, taskID, "input-pending"))
        workflows[workflowID] = workflow
        await diagnostics?.record(kind: .hitl, event: "workflow.input.pending", sessionID: workflow.rootSessionID, runID: workflow.rootRunID, workflowID: workflowID, taskID: taskID)
        try await persist(workflow)
    }

    /// Records that routing has been re-established. It does not rerun or complete the originating task.
    public func reattachPendingInput(workflowID: WorkflowID, taskID: WorkflowTaskID) async throws {
        var workflow = try workflow(workflowID)
        guard let index = workflow.tasks.firstIndex(where: { $0.definition.id == taskID }), workflow.tasks[index].pendingInput != nil else { throw CoreError(code: .resourceNotFound, message: "Workflow Task 没有挂起输入") }
        workflow = replacing(workflow, task: replace(workflow.tasks[index], status: workflow.tasks[index].status), status: .waitingForUser, checkpoint: checkpoint(workflow, taskID, "input-reattached"))
        workflows[workflowID] = workflow
        await diagnostics?.record(kind: .recovery, event: "workflow.recovery.acknowledged", sessionID: workflow.rootSessionID, runID: workflow.rootRunID, workflowID: workflowID, taskID: taskID)
        try await persist(workflow)
    }

    public func suspendForOrigin(runID: AgentRunID, input: WorkflowPendingInput) async throws {
        guard let match = workflows.values.lazy.flatMap(\.tasks).first(where: { $0.provenance?.childRunID == runID }), let workflow = workflows.values.first(where: { $0.tasks.contains(where: { $0.definition.id == match.definition.id && $0.provenance?.childRunID == runID }) }) else {
            throw CoreError(code: .resourceNotFound, message: "Workflow child Run 不存在")
        }
        try await suspend(workflowID: workflow.id, taskID: match.definition.id, input: input)
    }

    public func suspendForOrigin(sessionID: SessionID, input: WorkflowPendingInput) async throws {
        guard let match = workflows.values.lazy.flatMap(\.tasks).first(where: { $0.provenance?.childSessionID == sessionID }), let workflow = workflows.values.first(where: { $0.tasks.contains(where: { $0.definition.id == match.definition.id && $0.provenance?.childSessionID == sessionID }) }) else {
            throw CoreError(code: .resourceNotFound, message: "Workflow child Session 不存在")
        }
        try await suspend(workflowID: workflow.id, taskID: match.definition.id, input: input)
    }

    public func complete(workflowID: WorkflowID, taskID: WorkflowTaskID, result: SubagentResult? = nil, error: CoreError? = nil) async throws {
        var workflow = try workflow(workflowID)
        guard let index = workflow.tasks.firstIndex(where: { $0.definition.id == taskID }) else { throw CoreError(code: .resourceNotFound, message: "Workflow Task 不存在") }
        let current = workflow.tasks[index]
        guard !current.status.isTerminal else { return }
        let status: WorkflowTaskStatus = error == nil ? .completed : (error?.code == .commandTimedOut ? .timedOut : .failed)
        let provenance = result.map { WorkflowTaskProvenance(parentSessionID: workflow.rootSessionID, parentRunID: workflow.rootRunID, childSessionID: $0.childSessionID, childRunID: $0.runID) }
        workflow = replacing(workflow, task: replace(current, status: status, provenance: provenance, result: result, pendingInput: nil, error: error), status: status == .completed ? .running : .failed, checkpoint: checkpoint(workflow, taskID, "task-\(status.rawValue)"))
        workflow = blockDependents(in: workflow)
        workflow = withDerivedStatus(workflow)
        workflows[workflowID] = workflow
        active.removeValue(forKey: key(workflowID, taskID))
        try await persist(workflow)
        await schedule(workflowID)
    }

    /// An operator may explicitly make an interrupted task eligible again after verifying its side effects.
    public func acknowledgeRecovery(workflowID: WorkflowID, taskID: WorkflowTaskID) async throws {
        var workflow = try workflow(workflowID)
        guard let index = workflow.tasks.firstIndex(where: { $0.definition.id == taskID }), workflow.tasks[index].status == .recoveryRequired else { throw CoreError(code: .toolArgumentInvalid, message: "Task 不处于 recoveryRequired") }
        workflow = replacing(workflow, task: replace(workflow.tasks[index], status: .pending), status: .running, checkpoint: checkpoint(workflow, taskID, "recovery-acknowledged"))
        workflows[workflowID] = workflow
        try await persist(workflow)
        await schedule(workflowID)
    }

    private func schedule(_ workflowID: WorkflowID) async {
        guard var workflow = workflows[workflowID], workflow.status == .pending || workflow.status == .running else { return }
        var changed = false
        for index in workflow.tasks.indices where workflow.tasks[index].status == .pending && dependenciesCompleted(workflow.tasks[index], in: workflow) {
            guard let executor, workflow.tasks[index].definition.kind == .agent else { continue }
            let task = workflow.tasks[index]
            let provenance = WorkflowTaskProvenance(parentSessionID: workflow.rootSessionID, parentRunID: workflow.rootRunID)
            workflow = replacing(workflow, task: replace(task, status: .running, provenance: provenance), status: .running, checkpoint: checkpoint(workflow, task.definition.id, "task-running"))
            changed = true
            let workflowID = workflow.id
            let taskID = task.definition.id
            active[key(workflowID, taskID)] = Task.detached { [weak self] in
                let completion = await executor(workflowID, task.definition, provenance) { [weak self] child in
                    await self?.recordChild(workflowID: workflowID, taskID: taskID, provenance: child)
                }
                try? await self?.complete(workflowID: workflowID, taskID: taskID, result: completion.result, error: completion.error)
            }
        }
        if changed {
            workflows[workflowID] = workflow
            try? await persist(workflow)
        }
    }

    private func recover(_ workflow: WorkflowSnapshot) -> WorkflowSnapshot {
        let tasks = workflow.tasks.map { task in
            task.status == .running ? replace(task, status: .recoveryRequired) : task
        }
        let status: WorkflowStatus = tasks.contains(where: { $0.status == .recoveryRequired }) ? .recoveryRequired : workflow.status
        return WorkflowSnapshot(id: workflow.id, rootSessionID: workflow.rootSessionID, rootRunID: workflow.rootRunID, status: status, tasks: tasks, checkpoint: WorkflowCheckpoint(sequence: workflow.checkpoint.sequence + 1, label: "restart-recovered"), createdAt: workflow.createdAt, updatedAt: .now)
    }

    private func recordChild(workflowID: WorkflowID, taskID: WorkflowTaskID, provenance: WorkflowTaskProvenance) async {
        guard var workflow = workflows[workflowID], let index = workflow.tasks.firstIndex(where: { $0.definition.id == taskID }), workflow.tasks[index].status == .running else { return }
        workflow = replacing(workflow, task: replace(workflow.tasks[index], status: .running, provenance: provenance), status: .running, checkpoint: checkpoint(workflow, taskID, "child-started"))
        workflows[workflowID] = workflow
        try? await persist(workflow)
    }

    private func validate(_ tasks: [WorkflowTaskDefinition]) throws {
        guard !tasks.isEmpty, Set(tasks.map(\.id)).count == tasks.count else { throw CoreError(code: .toolArgumentInvalid, message: "Workflow Task ID 必须唯一且非空") }
        let ids = Set(tasks.map(\.id))
        guard tasks.allSatisfy({ !$0.dependencies.contains($0.id) && Set($0.dependencies).count == $0.dependencies.count && Set($0.dependencies).isSubset(of: ids) }) else { throw CoreError(code: .toolArgumentInvalid, message: "Workflow dependency 无效") }
        var remaining = Set(tasks.map(\.id))
        while let next = tasks.first(where: { remaining.contains($0.id) && $0.dependencies.allSatisfy { !remaining.contains($0) } }) {
            remaining.remove(next.id)
        }
        guard remaining.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "Workflow dependency 不能成环") }
    }

    private func dependenciesCompleted(_ task: WorkflowTaskState, in workflow: WorkflowSnapshot) -> Bool {
        task.definition.dependencies.allSatisfy { id in workflow.tasks.first(where: { $0.definition.id == id })?.status == .completed }
    }

    private func blockDependents(in workflow: WorkflowSnapshot) -> WorkflowSnapshot {
        var result = workflow
        for task in workflow.tasks where task.status == .pending && task.definition.dependencies.contains(where: { id in
            guard let status = result.tasks.first(where: { $0.definition.id == id })?.status else { return true }
            return status == .failed || status == .cancelled || status == .timedOut || status == .blocked
        }) {
            result = replacing(result, task: replace(task, status: .blocked, error: CoreError(code: .toolExecutionFailed, message: "Workflow dependency 未成功完成")), status: result.status, checkpoint: result.checkpoint)
        }
        return result
    }

    private func withDerivedStatus(_ workflow: WorkflowSnapshot) -> WorkflowSnapshot {
        let status: WorkflowStatus
        if workflow.tasks.allSatisfy({ $0.status == .completed }) { status = .completed }
        else if workflow.tasks.contains(where: { $0.status == .waitingForQuestion || $0.status == .waitingForPermission || $0.status == .waitingForDecision }) { status = .waitingForUser }
        else if workflow.tasks.contains(where: { $0.status == .recoveryRequired }) { status = .recoveryRequired }
        else if workflow.tasks.contains(where: { $0.status == .failed || $0.status == .timedOut || $0.status == .blocked }) { status = .failed }
        else { status = .running }
        return WorkflowSnapshot(id: workflow.id, rootSessionID: workflow.rootSessionID, rootRunID: workflow.rootRunID, status: status, tasks: workflow.tasks, checkpoint: workflow.checkpoint, createdAt: workflow.createdAt, updatedAt: .now)
    }

    private func replacing(_ workflow: WorkflowSnapshot, task: WorkflowTaskState, status: WorkflowStatus, checkpoint: WorkflowCheckpoint) -> WorkflowSnapshot {
        WorkflowSnapshot(id: workflow.id, rootSessionID: workflow.rootSessionID, rootRunID: workflow.rootRunID, status: status, tasks: workflow.tasks.map { $0.definition.id == task.definition.id ? task : $0 }, checkpoint: checkpoint, createdAt: workflow.createdAt, updatedAt: .now)
    }

    private func replace(_ task: WorkflowTaskState, status: WorkflowTaskStatus, provenance: WorkflowTaskProvenance? = nil, result: SubagentResult? = nil, pendingInput: WorkflowPendingInput? = nil, error: CoreError? = nil) -> WorkflowTaskState {
        WorkflowTaskState(definition: task.definition, status: status, provenance: provenance ?? task.provenance, result: result ?? task.result, pendingInput: pendingInput, error: error ?? task.error)
    }

    private func checkpoint(_ workflow: WorkflowSnapshot, _ taskID: WorkflowTaskID?, _ label: String) -> WorkflowCheckpoint {
        WorkflowCheckpoint(sequence: workflow.checkpoint.sequence + 1, taskID: taskID, label: label)
    }

    private func persist(_ workflow: WorkflowSnapshot) async throws { try await persistence?.saveWorkflow(workflow) }
    private func key(_ workflowID: WorkflowID, _ taskID: WorkflowTaskID) -> String { "\(workflowID.rawValue)/\(taskID.rawValue)" }
}
