import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

private struct HangingTool: ToolExecutor {
    let definition = ToolDefinition(id: ToolID("hang"), description: "hang", inputSchema: ToolInputSchema(properties: [:], required: []), capability: ToolCapability(readOnly: true))
    func resource(for arguments: String, profile: ExecutionProfile) throws -> String { "hang" }
    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        try await Task.sleep(for: .seconds(10))
        return "unreachable"
    }
}

struct ExecutionDeadlineTests {
    @Test func effectiveDeadlineClampsRequestedAndParent() {
        let policy = ExecutionDeadlinePolicy(settings: ExecutionTimeoutSettings(providerSeconds: 10, maximumSeconds: 5))
        let parent = ExecutionDeadline(category: .agentRun, timeout: .milliseconds(40))
        let child = policy.deadline(for: .provider, requested: .seconds(30), parent: parent)
        #expect(child.timeoutSeconds <= 0.04)
        #expect(child.timeoutSeconds > 0)
    }

    @Test func toolOverallTimeoutBecomesTypedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ExecutionDeadlinePolicy(settings: ExecutionTimeoutSettings(foregroundShellSeconds: 0.02, maximumSeconds: 0.2))
        let runtime = ToolRuntime(registry: ToolRegistry([HangingTool()]), permissions: PermissionEngine(defaultDecision: .allow), deadlinePolicy: policy)
        let result = await runtime.execute(ToolCall(callID: ToolCallID("hang-1"), toolID: ToolID("hang"), arguments: "{}"), sessionID: SessionID("scenario")) { _ in }
        #expect(result.outcome == .timedOut)
        #expect(result.error?.code == CoreError.Code.commandTimedOut.rawValue)
        #expect(result.metadata["deadlineCategory"] == ExecutionTimeoutCategory.foregroundShell.rawValue)
    }

    @Test func watchdogCancellationIsNotTimeout() async {
        let deadline = ExecutionDeadline(category: .provider, timeout: .seconds(10))
        let task = Task {
            try await ExecutionWatchdog.run(deadline) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后的 watchdog 不应成功")
        } catch is CancellationError {
        } catch {
            Issue.record("应保留 CancellationError，实际为 \(error)")
        }
    }
}
