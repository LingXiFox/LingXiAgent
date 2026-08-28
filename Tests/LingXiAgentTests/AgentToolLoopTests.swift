import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor AgentEventCapture {
    private var events: [CoreEvent] = []

    func append(_ event: CoreEvent) { events.append(event) }

    func waitForTerminal() async -> [CoreEvent] {
        while !events.contains(where: {
            if case .turnCompleted = $0 { return true }
            if case .turnFailed = $0 { return true }
            return false
        }) {
            await Task.yield()
        }
        return events
    }
}

private actor ToolCompletionRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private struct DelayedReadTool: ToolExecutor {
    let recorder: ToolCompletionRecorder
    let definition = ToolDefinition(
        id: ToolID("delayed_read"), description: "Test-only delayed read.",
        inputSchema: ToolInputSchema(properties: ["path": ToolInputProperty(type: .string, description: "path")], required: ["path"]),
        capability: ToolCapability(readOnly: true)
    )

    func resource(for arguments: String, profile: ExecutionProfile) throws -> String { arguments }

    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let path = arguments.contains("slow") ? "slow" : arguments.contains("fast") ? "fast" : "failure"
        if path == "slow" { try await Task.sleep(for: .milliseconds(80)) }
        if path == "failure" { throw CoreError(code: .toolExecutionFailed, message: "expected") }
        await recorder.append(path)
        return path
    }
}

struct AgentToolLoopTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func call() -> ToolCall {
        ToolCall(callID: ToolCallID("call-readme"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
    }

    private func makeClient(
        root: URL,
        provider: any ModelProvider,
        permission: PermissionDecision,
        registry: ToolRegistry? = nil
    ) async throws -> LingXiClient {
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: permission,
            toolRegistry: registry
        )
        await host.start()
        return LingXiClient.inProcess(endpoint: host)
    }

    private func collectEvents(_ client: LingXiClient) async -> (AgentEventCapture, Task<Void, Never>) {
        let capture = AgentEventCapture()
        let stream = await client.events()
        return (capture, Task {
            for await event in stream { await capture.append(event) }
        })
    }

    @Test func toolResultReturnsToSecondModelStepAsStructuredHistory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "LingXiAgent project".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let provider = ScriptedFakeProvider(script: [
            [.reasoningDelta("need file"), .toolCallStarted(callID: call().callID, toolID: call().toolID), .toolCallDelta(callID: call().callID, arguments: call().arguments), .toolCallCompleted(call()), .completed(.toolCalls)],
            [.textDelta("这个项目叫 LingXiAgent。"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider, permission: .allow)
        let (capture, eventTask) = await collectEvents(client)
        defer { eventTask.cancel() }

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "读取 README")
        for try await _ in stream {}
        let events = await capture.waitForTerminal()

        let requests = provider.recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.id.rawValue) == ["list_directory", "read_file"])
        #expect(requests[1].messages.map(\.role) == [.user, .assistant, .tool])
        #expect(requests[1].messages[1].parts.contains(.toolCall(call())))
        #expect(requests[1].messages[2].parts == [.toolResult(ToolResult(callID: call().callID, success: true, content: "LingXiAgent project"))])

        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(snapshot.messages[1].content.isEmpty)
        #expect(snapshot.messages[1].parts == [.toolCall(call())])
        #expect(snapshot.messages[2].content.isEmpty)
        #expect(snapshot.messages[3].content == "这个项目叫 LingXiAgent。")
        #expect(!snapshot.messages[3].content.contains("need file"))
        #expect(events.contains(.toolCallCompleted(call())))
        #expect(events.contains(.toolResult(ToolResult(callID: call().callID, success: true, content: "LingXiAgent project"))))
    }

    @Test func deniedToolIsRecordedAndModelCanFinish() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [
            [.toolCallStarted(callID: call().callID, toolID: call().toolID), .toolCallCompleted(call()), .completed(.toolCalls)],
            [.textDelta("无法读取，权限被拒绝。"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider, permission: .deny)

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "读取 README")
        for try await _ in stream {}

        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        guard case let .toolResult(result) = snapshot.messages[2].parts.first else {
            Issue.record("应保存结构化 ToolResult")
            return
        }
        #expect(result.success == false)
        #expect(result.error?.code == CoreError.Code.permissionDenied.rawValue)
        #expect(snapshot.messages.last?.content == "无法读取，权限被拒绝。")
    }

    @Test func stepLimitFailsInsteadOfLoopingForever() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Loop".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let provider = ScriptedFakeProvider(script: [[
            .toolCallStarted(callID: call().callID, toolID: call().toolID), .toolCallCompleted(call()), .completed(.toolCalls),
        ]])
        let client = try await makeClient(root: root, provider: provider, permission: .allow)
        let (capture, eventTask) = await collectEvents(client)
        defer { eventTask.cancel() }

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "loop")
        for try await _ in stream {}
        let events = await capture.waitForTerminal()
        guard case let .turnFailed(failure)? = events.last else {
            Issue.record("step limit 必须触发 turnFailed: \(events)")
            return
        }
        #expect(failure.error.code == .agentStepLimitReached)
        #expect(provider.recorder.requests.count == 8)
    }

    @Test func consecutiveIdenticalReadIsRecordedOnceAndSecondCallIsBlocked() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "LingXiAgent".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let first = call()
        let second = ToolCall(callID: ToolCallID("call-readme-2"), toolID: first.toolID, arguments: first.arguments)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallStarted(callID: first.callID, toolID: first.toolID), .toolCallCompleted(first), .toolCallStarted(callID: second.callID, toolID: second.toolID), .toolCallCompleted(second), .completed(.toolCalls)],
            [.textDelta("完成。"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider, permission: .allow)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "读取 README")
        for try await _ in stream {}

        let snapshot = try await client.session(sessionID)
        #expect(provider.recorder.requests.count == 2)
        #expect(snapshot.messages[1].parts.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }.count == 2)
        let results = snapshot.messages.dropFirst(2).prefix(2).compactMap { message -> ToolResult? in
            guard case let .toolResult(result) = message.parts.first else { return nil }
            return result
        }
        #expect(results.count == 2)
        #expect(results[0].success)
        #expect(results[1].error?.code == "duplicateToolCall")
        #expect(provider.recorder.requests[1].messages.filter { $0.role == .tool }.count == 2)
    }

    @Test func multiToolBatchExecutesInParallelAndSettlesInProviderOrder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ToolCompletionRecorder()
        let slow = ToolCall(callID: ToolCallID("slow"), toolID: ToolID("delayed_read"), arguments: #"{"path":"slow"}"#)
        let fast = ToolCall(callID: ToolCallID("fast"), toolID: ToolID("delayed_read"), arguments: #"{"path":"fast"}"#)
        let failed = ToolCall(callID: ToolCallID("failed"), toolID: ToolID("delayed_read"), arguments: #"{"path":"failure"}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(slow), .toolCallCompleted(fast), .toolCallCompleted(failed), .completed(.toolCalls)],
            [.textDelta("settled"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider, permission: .allow, registry: ToolRegistry([DelayedReadTool(recorder: recorder)]))
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "read three")
        for try await _ in stream {}

        let snapshot = try await client.session(sessionID)
        let results = snapshot.messages.compactMap { message -> ToolResult? in
            guard case let .toolResult(result) = message.parts.first else { return nil }
            return result
        }
        #expect(provider.recorder.requests.count == 2)
        #expect(results.map(\.callID) == [slow.callID, fast.callID, failed.callID])
        #expect(results[0].success && results[1].success && !results[2].success)
        #expect(await recorder.snapshot().first == "fast")
        #expect(snapshot.messages.last?.content == "settled")
    }
}
