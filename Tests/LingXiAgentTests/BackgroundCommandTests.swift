import Foundation
@testable import LingXiCore
@testable import LingXiPlatform
import LingXiProtocol
import Testing

@Suite("Background Command System & Watchdog Inspection Tests")
struct BackgroundCommandTests {
    private func makeTemporaryWorkspace() throws -> (URL, WorkspaceRoot) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-bg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = try WorkspaceRoot(path: tempDir.path)
        return (tempDir, root)
    }

    @Test("Mandatory timeout enforcement rejects missing or zero timeout")
    func testMandatoryTimeoutEnforcement() async throws {
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

    @Test("Spawn and poll background task lifecycle with incremental output")
    func testSpawnAndPollLifecycle() async throws {
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

    @Test("Watchdog kills process when timeout_seconds is exceeded")
    func testWatchdogTimeoutTermination() async throws {
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
    }

    @Test("Manual termination immediately stops background task")
    func testManualTermination() async throws {
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
    }

    @Test("Proactive system notices alert when tasks finish and inject cadence reminders")
    func testProactiveSystemNoticeGeneration() async throws {
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

    @Test("TerminateAll kills all running tasks and cleans store")
    func testTerminateAllCleansProcesses() async throws {
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
}
