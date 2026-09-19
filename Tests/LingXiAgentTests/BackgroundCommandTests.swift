import Foundation
@testable import LingXiCore
@testable import LingXiPlatform
import LingXiProtocol
import LingXiClient
import LingXiApplication
import Testing

struct BackgroundCommandTests {
    private func makeTemporaryWorkspace() throws -> (URL, WorkspaceRoot) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-bg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = try WorkspaceRoot(path: tempDir.path)
        return (tempDir, root)
    }

    @Test func testMandatoryTimeoutEnforcement() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)

        // 1. Missing timeout_seconds should be rejected
        let missingArgs = """
        {"command": "echo hello"}
        """
        await #expect(throws: CoreError.self) {
            _ = try await runTool.execute(arguments: missingArgs, profile: .workspace)
        }

        // 2. Zero timeout_seconds should be rejected
        let zeroArgs = """
        {"command": "echo hello", "timeout_seconds": 0}
        """
        await #expect(throws: CoreError.self) {
            _ = try await runTool.execute(arguments: zeroArgs, profile: .workspace)
        }

        // 3. Negative timeout_seconds should be rejected
        let negativeArgs = """
        {"command": "echo hello", "timeout_seconds": -10}
        """
        await #expect(throws: CoreError.self) {
            _ = try await runTool.execute(arguments: negativeArgs, profile: .workspace)
        }
    }

    @Test func testSpawnAndPollLifecycle() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)
        let manageTool = ManageBackgroundCommandTool(manager: manager)

        let spawnArgs = """
        {"command": "echo 'LingXi-BG-Output-1' && echo 'LingXi-BG-Output-2'", "timeout_seconds": 30, "task_id": "test-task-1"}
        """
        let spawnResult = try await runTool.execute(arguments: spawnArgs, profile: .workspace)
        #expect(spawnResult.contains("test-task-1"))
        #expect(spawnResult.contains("running"))

        // Wait a short moment for process completion
        try? await Task.sleep(for: .milliseconds(600))

        let pollArgs = """
        {"action": "poll", "task_id": "test-task-1"}
        """
        let pollResult = try await manageTool.execute(arguments: pollArgs, profile: .workspace)
        #expect(pollResult.contains("LingXi-BG-Output-1"))
        #expect(pollResult.contains("LingXi-BG-Output-2"))
        #expect(pollResult.contains("exited"))
    }

    @Test func testWatchdogTimeoutTermination() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)
        let manageTool = ManageBackgroundCommandTool(manager: manager)

        // Run a sleep 30 command with a 1-second timeout
        let spawnArgs = """
        {"command": "sleep 30", "timeout_seconds": 1, "task_id": "sleep-timeout-test"}
        """
        _ = try await runTool.execute(arguments: spawnArgs, profile: .workspace)

        // Wait for watchdog to trigger (1.5s > 1s)
        try? await Task.sleep(for: .milliseconds(1600))

        let pollArgs = """
        {"action": "poll", "task_id": "sleep-timeout-test"}
        """
        let pollResult = try await manageTool.execute(arguments: pollArgs, profile: .workspace)
        #expect(pollResult.contains("timed_out"))
        await manager.terminateAll()
    }

    @Test func testManualTermination() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)
        let manageTool = ManageBackgroundCommandTool(manager: manager)

        let spawnArgs = """
        {"command": "sleep 60", "timeout_seconds": 120, "task_id": "manual-kill-test"}
        """
        _ = try await runTool.execute(arguments: spawnArgs, profile: .workspace)

        let terminateArgs = """
        {"action": "terminate", "task_id": "manual-kill-test"}
        """
        let termResult = try await manageTool.execute(arguments: terminateArgs, profile: .workspace)
        #expect(termResult.contains("terminated"))
        await manager.terminateAll()
    }

    @Test func testProactiveSystemNoticeGeneration() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)
        let manageTool = ManageBackgroundCommandTool(manager: manager)

        // 1. Spawn a fast background command
        let spawnArgs = """
        {"command": "echo done-fast", "timeout_seconds": 10, "task_id": "fast-task"}
        """
        _ = try await runTool.execute(arguments: spawnArgs, profile: .workspace)

        // Allow process to finish
        try? await Task.sleep(for: .milliseconds(500))

        // Before poll, generate notice: should detect unobserved completed task
        let notice1 = await manager.generateSystemNotice(currentStep: 1)
        #expect(notice1 != nil)
        #expect(notice1?.contains("fast-task") == true)
        #expect(notice1?.contains("后台命令执行状态更新") == true)
        #expect(notice1?.contains("manage_background_command") == true)

        // Now observe the task via poll
        let pollArgs = """
        {"action": "poll", "task_id": "fast-task"}
        """
        _ = try await manageTool.execute(arguments: pollArgs, profile: .workspace)

        // Notice should now be cleared
        let notice2 = await manager.generateSystemNotice(currentStep: 2)
        #expect(notice2 == nil)

        // 2. Spawn a running task for cadence testing
        let runningSpawn = """
        {"command": "sleep 10", "timeout_seconds": 60, "task_id": "cadence-task"}
        """
        _ = try await runTool.execute(arguments: runningSpawn, profile: .workspace)

        // Step 1: should produce running cadence reminder
        let cadenceNotice = await manager.generateSystemNotice(currentStep: 3)
        #expect(cadenceNotice != nil)
        #expect(cadenceNotice?.contains("cadence-task") == true)
        #expect(cadenceNotice?.contains("正在异步执行") == true)

        // Clean up
        await manager.terminateAll()
    }

    @Test func testTerminateAllCleansProcesses() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)

        _ = try await runTool.execute(arguments: "{\"command\": \"sleep 30\", \"timeout_seconds\": 60, \"task_id\": \"task-a\"}", profile: .workspace)
        _ = try await runTool.execute(arguments: "{\"command\": \"sleep 30\", \"timeout_seconds\": 60, \"task_id\": \"task-b\"}", profile: .workspace)

        let before = await manager.list()
        #expect(before.count == 2)

        await manager.terminateAll()

        let after = await manager.list()
        #expect(after.isEmpty)
    }

    @Test func testShellToolRejectsBackgroundAmpersand() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let shellTool = ShellTool(workspace: workspace)

        // 1. Rejects single trailing &
        await #expect(throws: CoreError.self) {
            try await shellTool.execute(arguments: #"{"command": "sleep 5 &"}"#, profile: .workspace)
        }

        // 2. Rejects shell background with redirect
        await #expect(throws: CoreError.self) {
            try await shellTool.execute(arguments: #"{"command": "sleep 5 >/dev/null 2>&1 & echo background_pid=$!"}"#, profile: .workspace)
        }

        // 3. Accepts regular command
        let normalResult = try await shellTool.execute(arguments: #"{"command": "echo hello-lingxi"}"#, profile: .workspace)
        #expect(normalResult.contains("hello-lingxi"))

        // 4. Accepts command chain with &&
        let chainResult = try await shellTool.execute(arguments: #"{"command": "echo a && echo b"}"#, profile: .workspace)
        #expect(chainResult.contains("a") && chainResult.contains("b"))
    }

    @Test func testTasksCommandInspectionAndClassification() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registry = ApplicationCommandRegistry()
        for cmd in BuiltinCommands.createAll() {
            registry.register(cmd)
        }

        let manager = BackgroundCommandManager()
        let coreHost = try CoreHost(workspaceRoot: workspace, permissionDecision: .allow, backgroundManager: manager)
        await coreHost.start()
        let client = try await LingXiClientVNext.connectInProcess(service: coreHost)
        let state = ApplicationState()

        // 1. Initial /tasks with empty list
        let emptyResult = try await registry.execute(input: "/tasks", sessionID: nil, client: client, state: state)
        #expect(emptyResult.output.contains("后台命令任务状态 (/tasks)"))
        #expect(emptyResult.output.contains("暂无后台任务"))

        // 2. Run a background command to have a completed task
        let runBgTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)
        _ = try await runBgTool.execute(arguments: #"{"command": "echo task-finished-ok", "timeout_seconds": 10, "task_id": "test-task-1"}"#, profile: .workspace)

        // Give it a moment to exit
        try? await Task.sleep(for: .milliseconds(500))

        // 3. /tasks shows completed task
        let listResult = try await registry.execute(input: "/tasks", sessionID: nil, client: client, state: state)
        #expect(listResult.output.contains("test-task-1"))
        #expect(listResult.output.contains("已完成"))

        // 4. /tasks <task_id> shows detail card with output
        let detailResult = try await registry.execute(input: "/tasks test-task-1", sessionID: nil, client: client, state: state)
        #expect(detailResult.output.contains("后台任务详情 (/tasks)"))
        #expect(detailResult.output.contains("test-task-1"))
        #expect(detailResult.output.contains("task-finished-ok"))

        // 5. Test kill subcmd
        let killResult = try await registry.execute(input: "/tasks kill test-task-1", sessionID: nil, client: client, state: state)
        #expect(killResult.output.contains("已向后台任务 [test-task-1] 发送终止信号"))

        await manager.terminateAll()
        await client.disconnect()
        await coreHost.shutdown()
    }

    @Test func testCoreHostDefaultBackgroundManagerSharingWithoutExternalInjection() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Initialize CoreHost without passing backgroundManager (default nil in production)
        let coreHost = try CoreHost(workspaceRoot: workspace, permissionDecision: .allow)
        await coreHost.start()
        let client = try await LingXiClientVNext.connectInProcess(service: coreHost)

        // Execute run_background_command via coreHost.toolRuntimeRef
        let spawnArgs = """
        {"command": "echo 'singleton-bg-verified'", "timeout_seconds": 15, "task_id": "corehost-bg-singleton-task"}
        """
        let toolCall = ToolCall(
            callID: ToolCallID("call-1"),
            toolID: ToolID("run_background_command"),
            arguments: spawnArgs
        )
        let execution = await coreHost.toolRuntimeRef.execute(
            toolCall,
            sessionID: SessionID("test-session")
        )
        #expect(execution.content.contains("corehost-bg-singleton-task"))

        // Query background tasks via Diagnostics RPC
        let rpcTasks = try await client.diagnostics.getBackgroundTasks()
        #expect(rpcTasks.contains(where: { $0.id == "corehost-bg-singleton-task" }))

        // Clean up
        await coreHost.backgroundManagerRef.terminateAll()
        await client.disconnect()
        await coreHost.shutdown()
    }

    @Test func testWaitForTaskCompletionWakeupOnProcessExit() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = BackgroundCommandManager()
        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: manager)

        let spawnArgs = """
        {"command": "sleep 0.4 && echo 'bg-result-42'", "timeout_seconds": 10, "task_id": "wake-test-task"}
        """
        _ = try await runTool.execute(arguments: spawnArgs, profile: .workspace)

        let running = await manager.hasRunningTasks
        #expect(running == true)

        let startedAt = Date()
        await manager.waitForTaskCompletion()
        let elapsed = Date().timeIntervalSince(startedAt)

        // It should have waited roughly 0.4s and then been awakened
        #expect(elapsed >= 0.3)
        let runningAfter = await manager.hasRunningTasks
        #expect(runningAfter == false)

        // Notice should now contain stdout
        let notice = await manager.generateSystemNotice(currentStep: 1)
        #expect(notice?.contains("bg-result-42") == true)

        await manager.terminateAll()
    }

    @Test func testEscCancellationKillsAllBackgroundTasksAndAborts() async throws {
        let (tempDir, workspace) = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coreHost = try CoreHost(workspaceRoot: workspace, permissionDecision: .allow)
        await coreHost.start()
        let client = try await LingXiClientVNext.connectInProcess(service: coreHost)

        let spawnArgs = """
        {"command": "sleep 60", "timeout_seconds": 120, "task_id": "esc-kill-test-task"}
        """
        let toolCall = ToolCall(
            callID: ToolCallID("call-esc-1"),
            toolID: ToolID("run_background_command"),
            arguments: spawnArgs
        )
        _ = await coreHost.toolRuntimeRef.execute(
            toolCall,
            sessionID: SessionID("test-esc-session")
        )

        let runningBefore = await coreHost.backgroundManagerRef.hasRunningTasks
        #expect(runningBefore == true)

        // Simulate Esc dispatch: terminateAllBackgroundTasks via client
        let success = try await client.runtime.terminateAllBackgroundTasks()
        #expect(success == true)

        let runningAfter = await coreHost.backgroundManagerRef.hasRunningTasks
        #expect(runningAfter == false)

        let tasksAfter = await coreHost.backgroundManagerRef.list()
        #expect(tasksAfter.isEmpty)

        await client.disconnect()
        await coreHost.shutdown()
    }
}
