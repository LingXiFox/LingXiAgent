import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct WorkflowRuntimeTests {
    @Test func checkpointRestartPreservesCompletedDependenciesPendingInputsAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLitePersistenceStore(dataRoot: root.appendingPathComponent("data", isDirectory: true), mainRoot: root)
        let sessionID = SessionID("parent-session")
        let runID = AgentRunID("parent-run")
        let binding = try await store.mainRootBinding()
        try await store.createSession(Session(id: sessionID, createdAt: .now, kind: .primary, rootSessionID: sessionID, projectID: store.projectID, cwdRootBindingID: binding.id))
        try await store.saveAgentRun(AgentRunInfo(runID: runID, sessionID: sessionID, projectID: store.projectID, rootRunID: runID, agentKind: .primary, status: .running, modelSelection: ModelSelection(modelID: "test")))

        let runtime = WorkflowRuntime(persistence: store)
        let tasks = ["done", "question", "permission", "decision", "join"].map { WorkflowTaskDefinition(id: WorkflowTaskID($0), task: $0, dependencies: $0 == "join" ? [WorkflowTaskID("done"), WorkflowTaskID("question"), WorkflowTaskID("permission"), WorkflowTaskID("decision")] : []) }
        let workflow = try await runtime.create(id: WorkflowID("workflow"), rootSessionID: sessionID, rootRunID: runID, tasks: tasks)
        let child = SubagentResult(childSessionID: SessionID("child-session"), runID: AgentRunID("child-run"), status: .completed, finalText: "done")
        try await runtime.complete(workflowID: workflow.id, taskID: WorkflowTaskID("done"), result: child)
        try await runtime.suspend(workflowID: workflow.id, taskID: WorkflowTaskID("question"), input: .question(QuestionRequest(questionID: QuestionID("q"), question: "q", originSessionID: SessionID("child-session"), originRunID: AgentRunID("child-run"), rootSessionID: sessionID, parentSessionID: sessionID)))
        try await runtime.suspend(workflowID: workflow.id, taskID: WorkflowTaskID("permission"), input: .permission(PermissionRequest(permissionID: PermissionID("p"), sessionID: SessionID("child-session"), toolCallID: ToolCallID("call"), toolID: ToolID("write"), resource: "file", description: "write")))
        try await runtime.suspend(workflowID: workflow.id, taskID: WorkflowTaskID("decision"), input: .decision(DecisionRequest(decisionID: DecisionID("d"), question: "d", options: ["yes"], originSessionID: SessionID("child-session"), originRunID: AgentRunID("child-run"))))

        let restored = WorkflowRuntime(persistence: store)
        try await restored.restore()
        let snapshot = try await restored.workflow(workflow.id)
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("done") }?.status == .completed)
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("done") }?.provenance?.childRunID == AgentRunID("child-run"))
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("question") }?.status == .waitingForQuestion)
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("permission") }?.status == .waitingForPermission)
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("decision") }?.status == .waitingForDecision)
        #expect(snapshot.tasks.first { $0.definition.id == WorkflowTaskID("join") }?.definition.dependencies.count == 4)
        #expect(snapshot.checkpoint.sequence >= 4)
    }

    @Test func runningTaskRequiresExplicitRecoveryAcknowledgement() async throws {
        let store = try await workflowStore()
        let sessionID = SessionID("parent-session")
        let runID = AgentRunID("parent-run")
        let task = WorkflowTaskState(definition: WorkflowTaskDefinition(id: WorkflowTaskID("A"), task: "A"), status: .running, provenance: WorkflowTaskProvenance(parentSessionID: sessionID, parentRunID: runID))
        try await store.saveWorkflow(WorkflowSnapshot(id: WorkflowID("recover"), rootSessionID: sessionID, rootRunID: runID, status: .running, tasks: [task]))

        let restored = WorkflowRuntime(persistence: store)
        try await restored.restore()
        #expect(try await restored.workflow(WorkflowID("recover")).tasks[0].status == .recoveryRequired)
        try await restored.acknowledgeRecovery(workflowID: WorkflowID("recover"), taskID: WorkflowTaskID("A"))
        #expect(try await restored.workflow(WorkflowID("recover")).tasks[0].status == .pending)
    }

    @Test func branchJoinRunsBranchesBeforeJoinAndDoesNotRepeatCompletedTasks() async throws {
        let runtime = WorkflowRuntime()
        let tasks = [
            WorkflowTaskDefinition(id: WorkflowTaskID("A"), task: "A"),
            WorkflowTaskDefinition(id: WorkflowTaskID("B"), task: "B"),
            WorkflowTaskDefinition(id: WorkflowTaskID("D"), task: "D", dependencies: [WorkflowTaskID("A"), WorkflowTaskID("B")])
        ]
        let id = WorkflowID("branch-join")
        _ = try await runtime.create(id: id, rootSessionID: SessionID("parent"), rootRunID: AgentRunID("run"), tasks: tasks)
        #expect(try await runtime.readyTasks(id) == [WorkflowTaskID("A"), WorkflowTaskID("B")])
        try await runtime.complete(workflowID: id, taskID: WorkflowTaskID("A"))
        #expect(try await runtime.readyTasks(id) == [WorkflowTaskID("B")])
        try await runtime.complete(workflowID: id, taskID: WorkflowTaskID("B"))
        #expect(try await runtime.readyTasks(id) == [WorkflowTaskID("D")])
        try await runtime.complete(workflowID: id, taskID: WorkflowTaskID("D"))
        #expect(try await runtime.workflow(id).status == .completed)
    }
}

private func workflowStore() async throws -> SQLitePersistenceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLitePersistenceStore(dataRoot: root.appendingPathComponent("data", isDirectory: true), mainRoot: root)
    let binding = try await store.mainRootBinding()
    let sessionID = SessionID("parent-session")
    let runID = AgentRunID("parent-run")
    try await store.createSession(Session(id: sessionID, createdAt: .now, kind: .primary, rootSessionID: sessionID, projectID: store.projectID, cwdRootBindingID: binding.id))
    try await store.saveAgentRun(AgentRunInfo(runID: runID, sessionID: sessionID, projectID: store.projectID, rootRunID: runID, agentKind: .primary, status: .running, modelSelection: ModelSelection(modelID: "test")))
    return store
}
