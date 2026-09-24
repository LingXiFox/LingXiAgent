import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

struct TaskRuntimeTests {

    @Test("TaskRuntime registers capsule, serializes state transitions, and records events in SQLitePersistenceStore")
    func taskRuntimeLifecycleAndPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("task_runtime_test_\(UUID().uuidString)")
        let projectDir = tempDir.appendingPathComponent("project_root")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try SQLitePersistenceStore(dataRoot: tempDir, mainRoot: projectDir)
        let runtime = TaskRuntime(persistence: store)

        let sessionID = SessionID("sess-lifecycle-1")
        let taskID = TaskID("task-test-1")
        let workspaceID = WorkspaceID("ws-test-1")

        let capsule = TaskCapsule(
            taskID: taskID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            projectID: store.projectID.rawValue,
            objective: "Build and verify V1.1 foundation",
            state: .queued
        )

        try await runtime.register(capsule: capsule)

        // 1. Verify registered and stored
        let loadedInitial = try await store.loadCapsule(taskID: taskID)
        #expect(loadedInitial != nil)
        #expect(loadedInitial?.state == .queued)
        #expect(loadedInitial?.objective == "Build and verify V1.1 foundation")

        // 2. Transition queued -> running via start command
        let runningCapsule = try await runtime.transition(taskID: taskID, command: .start)
        #expect(runningCapsule.state == .running)
        #expect(await runtime.activeRootTask(for: sessionID)?.taskID == taskID)

        // 3. Transition running -> waiting with approvalPending
        let waitingCapsule = try await runtime.transition(taskID: taskID, command: .enterWaiting, waitingReason: .approvalPending)
        #expect(waitingCapsule.state == .waiting)
        #expect(waitingCapsule.waitingReason == .approvalPending)
        #expect(waitingCapsule.resumePoint != nil)
        #expect(waitingCapsule.resumePoint?.generation == 1)

        // 4. Transition waiting -> running via resume
        let resumedCapsule = try await runtime.transition(taskID: taskID, command: .resume)
        #expect(resumedCapsule.state == .running)
        #expect(resumedCapsule.waitingReason == nil)

        // 5. Transition running -> paused
        let pausedCapsule = try await runtime.transition(taskID: taskID, command: .pause, reason: "Manual user pause")
        #expect(pausedCapsule.state == .paused)
        #expect(pausedCapsule.resumePoint?.generation == 2)
        #expect(pausedCapsule.resumePoint?.statePayload["reason"] == "Manual user pause")

        // 6. Resume store verification
        let resumeStore = TaskResumeStore(persistence: store)
        let latestResume = try await resumeStore.latestResumePoint(for: taskID)
        #expect(latestResume?.generation == 2)
        #expect(latestResume?.statePayload["reason"] == "Manual user pause")

        // 7. Verify task_events audit trail in SQLite
        let events = try await store.loadEvents(taskID: taskID)
        #expect(events.count == 4) // start, enterWaiting, resume, pause
        #expect(events[0].event == "lifecycle.start")
        #expect(events[0].toState == .running)
        #expect(events[1].event == "lifecycle.enterWaiting")
        #expect(events[1].toState == .waiting)
        #expect(events[2].event == "lifecycle.resume")
        #expect(events[2].toState == .running)
        #expect(events[3].event == "lifecycle.pause")
        #expect(events[3].toState == .paused)

        // 8. Terminal transition paused -> completed via TaskLifecycleRequest
        _ = try await runtime.transition(request: TaskLifecycleRequest(taskID: taskID, command: .resume))
        let completed = try await runtime.transition(request: TaskLifecycleRequest(taskID: taskID, command: .complete))
        #expect(completed.state == .completed)
        #expect(await runtime.activeRootTask(for: sessionID) == nil)
    }

    @Test("WorkspaceRuntime forks workspace and preserves origin chain")
    func workspaceRuntimeFork() async throws {
        let runtime = WorkspaceRuntime()
        let origin = WorkspaceEntity(workspaceID: WorkspaceID("ws-origin"), projectID: "proj-100", kind: .main)
        await runtime.register(origin)

        let forked = try await runtime.fork(from: origin.workspaceID, isolationState: .copyOnWrite)
        #expect(forked.kind == .fork)
        #expect(forked.originWorkspaceID == origin.workspaceID)
        #expect(forked.projectID == "proj-100")
        #expect(forked.isolationState == .copyOnWrite)

        let listed = await runtime.list(projectID: "proj-100")
        #expect(listed.count == 2)
    }
}
