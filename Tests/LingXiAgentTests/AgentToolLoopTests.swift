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
        registry: ToolRegistry? = nil,
        interactive: Bool = false
    ) async throws -> LingXiClient {
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: permission,
            toolRegistry: registry,
            interactive: interactive
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
        #expect(requests[0].tools.map(\.id.rawValue) == ["apply_patch", "dependency_query", "edit_file", "find_references", "git", "glob", "grep", "list_directory", "load_tool", "process", "read_file", "search_tools", "shell", "subagent", "symbol_lookup", "write_file"])
        #expect(requests[1].messages.map(\.role) == [.user, .assistant, .tool])
        #expect(requests[1].messages[1].parts.contains(.toolCall(call())))
        #expect(requests[1].messages[2].parts == [.toolResult(ToolResult(callID: call().callID, success: true, content: "LingXiAgent project", toolName: "read_file"))])

        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(snapshot.messages[1].content.isEmpty)
        #expect(snapshot.messages[1].parts == [.toolCall(call())])
        #expect(snapshot.messages[2].content.isEmpty)
        #expect(snapshot.messages[3].content == "这个项目叫 LingXiAgent。")
        #expect(!snapshot.messages[3].content.contains("need file"))
        #expect(events.contains(.toolCallCompleted(call())))
        #expect(events.contains(.toolResult(ToolResult(callID: call().callID, success: true, content: "LingXiAgent project", toolName: "read_file"))))
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
        do {
            for try await _ in stream {}
            Issue.record("step limit 必须终止数据流")
        } catch let error as CoreError {
            #expect(error.code == .agentStepLimitReached)
        }
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
        let results = snapshot.messages.flatMap { message in
            message.parts.compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
        }
        #expect(results.count == 2)
        #expect(results[0].success)
        #expect(results[1].error?.code == "duplicateToolCall")
        #expect(provider.recorder.requests[1].messages.filter { $0.role == .tool }.count == 1)
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
        let results = snapshot.messages.flatMap { message in
            message.parts.compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
        }
        #expect(provider.recorder.requests.count == 2)
        #expect(results.map(\.callID) == [slow.callID, fast.callID, failed.callID])
        #expect(results[0].success && results[1].success && !results[2].success)
        #expect(snapshot.messages.filter { $0.role == .tool }.count == 1)
        #expect(snapshot.messages.first { $0.role == .tool }?.parts.count == 3)
        #expect(await recorder.snapshot().first == "fast")
        #expect(snapshot.messages.last?.content == "settled")
    }

    @Test func interactiveQuestionReturnsReplyToTheNextModelStep() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let question = ToolCall(callID: ToolCallID("question"), toolID: ToolID("question"), arguments: #"{"question":"继续吗？","options":["继续","停止"]}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(question), .completed(.toolCalls)],
            [.textDelta("已继续。"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider, permission: .allow, interactive: true)
        let replyTask = Task {
            for await event in await client.events() {
                if case let .questionAsked(request) = event {
                    try? await client.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
                    return
                }
            }
        }
        defer { replyTask.cancel() }
        await Task.yield()

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "需要确认")
        for try await _ in stream {}
        _ = await replyTask.value
        let snapshot = try await client.session(sessionID)

        #expect(provider.recorder.requests[0].tools.contains(where: { $0.id == ToolID("question") }))
        #expect(snapshot.messages.contains { $0.parts.contains { part in
            if case let .toolResult(result) = part { return result.callID == question.callID && result.success && result.content.contains("继续") }
            return false
        } })
        #expect(snapshot.messages.last?.content == "已继续。")
    }

    @Test func durableQuestionCallRecordsHITLReplyClaimProvenanceAndResult() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let question = ToolCall(callID: ToolCallID("durable-question"), toolID: ToolID("question"), arguments: #"{"question":"继续吗？","options":["继续"]}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(question), .completed(.toolCalls)],
            [.textDelta("已继续。"), .completed(.stop)],
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("data", isDirectory: true), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let replyTask = Task {
            for await event in await client.events() {
                if case let .questionAsked(request) = event {
                    try? await client.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
                    return
                }
            }
        }
        defer { replyTask.cancel() }
        await Task.yield()

        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "需要确认") {}
        _ = await replyTask.value

        let batch = try #require(try await host.persistence?.toolBatches(sessionID: sessionID).first)
        let state = try #require(batch.toolCallStates.first)
        #expect(provider.recorder.requests.count == 2)
        #expect(state.state == .completed)
        #expect(state.provenance.sessionID == sessionID)
        #expect(state.provenance.providerStep == 1)
        #expect(state.executionClaim?.mutatesProject == false)
        #expect({ if case .question = state.request { return true }; return false }())
        #expect({ if case .question = state.reply { return true }; return false }())
        #expect(state.result?.callID == question.callID)
    }

    @Test func restartRepliesToDurableQuestionAndContinuesExactlyOnce() async throws {
        let root = try fixture()
        let data = root.appendingPathComponent("data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let question = ToolCall(callID: ToolCallID("restart-question"), toolID: ToolID("question"), arguments: #"{"question":"继续吗？","options":["继续"]}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(question), .completed(.toolCalls)],
            [.textDelta("恢复完成。"), .completed(.stop)],
        ])
        let first = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: data, permissionDecision: .allow, interactive: true)
        await first.start()
        let firstClient = LingXiClient.inProcess(endpoint: first)
        let questionTask = Task { () -> QuestionRequest? in
            for await event in await firstClient.events() {
                if case let .questionAsked(request) = event { return request }
            }
            return nil
        }
        await Task.yield()
        let sessionID = try await firstClient.createSession()
        let streamTask = Task { for try await _ in try await firstClient.sendMessage(sessionID: sessionID, content: "确认") {} }
        let request = try #require(await questionTask.value)
        await first.shutdown()
        streamTask.cancel()
        let persistedCall = try #require(try await first.persistence?.toolBatches(sessionID: sessionID).first?.toolCallStates.first)
        #expect(persistedCall.state == .waitingForHuman)
        #expect(persistedCall.reply == nil)
        #expect({ if case .question = persistedCall.request { return true }; return false }())
        #expect({ if case let .question(value)? = persistedCall.request { return value == request }; return false }())
        let firstRuns = try await first.persistence!.loadAgentRuns(sessionID: sessionID)
        #expect(firstRuns.first?.status == .waitingForUser)

        let second = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: data, permissionDecision: .allow, interactive: true)
        await second.start()
        defer { Task { await second.shutdown() } }
        let secondClient = LingXiClient.inProcess(endpoint: second)
        #expect(try await secondClient.listAgentRuns(sessionID).first?.status == .waitingForUser)
        #expect(await second.questions.request(request.questionID) == request)
        try await secondClient.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))

        let deadline = Date().addingTimeInterval(2)
        var snapshot = try await secondClient.session(sessionID)
        while snapshot.messages.last?.content != "恢复完成。", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = try await secondClient.session(sessionID)
        }
        #expect(provider.recorder.requests.count == 2)
        #expect(snapshot.messages.filter { $0.role == .tool }.count == 1)
        #expect(snapshot.messages.last?.content == "恢复完成。")
    }

    @Test func restartPermissionReplyResumesAllowAndDenyWithoutReplayingTheBatch() async throws {
        for decision in [PermissionDecision.allow, .deny] {
            let root = try fixture()
            let data = root.appendingPathComponent("data", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "restart".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            let read = ToolCall(callID: ToolCallID("restart-\(decision.rawValue)"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
            let provider = ScriptedFakeProvider(script: [
                [.toolCallCompleted(read), .completed(.toolCalls)],
                [.textDelta("恢复完成。"), .completed(.stop)],
            ])
            let first = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: data, permissionDecision: .ask)
            await first.start()
            let firstClient = LingXiClient.inProcess(endpoint: first)
            let permissionTask = Task { () -> PermissionRequest? in
                for await event in await firstClient.events() {
                    if case let .permissionAsked(request) = event { return request }
                }
                return nil
            }
            await Task.yield()
            let sessionID = try await firstClient.createSession()
            let streamTask = Task { for try await _ in try await firstClient.sendMessage(sessionID: sessionID, content: "读取") {} }
            let request = try #require(await permissionTask.value)
            await first.shutdown()
            streamTask.cancel()

            let second = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: data, permissionDecision: .ask)
            await second.start()
            let secondClient = LingXiClient.inProcess(endpoint: second)
            try await secondClient.replyPermission(PermissionReply(permissionID: request.permissionID, decision: decision))

            let deadline = Date().addingTimeInterval(2)
            var snapshot = try await secondClient.session(sessionID)
            while snapshot.messages.last?.content != "恢复完成。", Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                snapshot = try await secondClient.session(sessionID)
            }
            let result = snapshot.messages.flatMap(\.parts).compactMap { if case let .toolResult(result) = $0 { result } else { nil } }.first
            #expect(provider.recorder.requests.count == 2)
            #expect(snapshot.messages.filter { $0.role == .tool }.count == 1)
            #expect(result?.success == (decision == .allow))
            #expect(snapshot.messages.last?.content == "恢复完成。")
            await second.shutdown()
        }
    }

    @Test func restartSchedulesReadOnlyRemainderAndSettlesMutationClaimAsUnknown() async throws {
        let root = try fixture()
        let data = root.appendingPathComponent("data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let session = try await PersistentSessionStore(persistence: store).create()
        let run = AgentRunInfo(runID: AgentRunID("restart-run"), sessionID: session.id, projectID: store.projectID, rootRunID: AgentRunID("restart-run"), agentKind: .primary, status: .waitingForTool, modelSelection: ModelSelection(modelID: "fake-model"))
        try await store.saveAgentRun(run)
        let read = ToolCall(callID: ToolCallID("read"), toolID: ToolID("delayed_read"), arguments: #"{"path":"fast"}"#)
        let mutation = ToolCall(callID: ToolCallID("mutation"), toolID: ToolID("write_file"), arguments: #"{"path":"never.txt","content":"must not run"}"#)
        let assistant = Message(id: MessageID("restart-assistant"), role: .assistant, parts: [.toolCall(read), .toolCall(mutation)], createdAt: .now)
        let batch = ToolExchangeBatch(
            batchID: "restart-batch", sessionID: session.id, assistantMessageID: assistant.id, toolCalls: [read, mutation],
            toolCallStates: [
                DurableToolCall(call: read, state: .executing, executionClaim: ToolExecutionClaim(claimID: "read-claim", mutatesProject: false), provenance: ToolCallProvenance(batchID: "restart-batch", sessionID: session.id, agentRunID: run.runID, providerRequestID: ModelRequestID("restart-request"), providerStep: 1)),
                DurableToolCall(call: mutation, state: .executing, executionClaim: ToolExecutionClaim(claimID: "mutation-claim", mutatesProject: true), provenance: ToolCallProvenance(batchID: "restart-batch", sessionID: session.id, agentRunID: run.runID, providerRequestID: ModelRequestID("restart-request"), providerStep: 1)),
            ], continuationRequestID: ModelRequestID("restart-request"), providerStep: 1, state: .pending, estimatedTokens: 1
        )
        try await store.appendAssistantMessageAndBatch(sessionID: session.id, message: assistant, batch: batch)

        let recorder = ToolCompletionRecorder()
        let provider = ScriptedFakeProvider(script: [[.textDelta("恢复完成。"), .completed(.stop)]])
        let restoreScheduler = SessionRestoreScheduler()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: data, permissionDecision: .allow, toolRegistry: ToolRegistry([DelayedReadTool(recorder: recorder)]), restoreScheduler: restoreScheduler)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        await restoreScheduler.waitUntilReady()
        await restoreScheduler.waitUntilCompleted()
        let snapshot = try await client.session(session.id)
        let results = snapshot.messages.flatMap(\.parts).compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
        #expect(await recorder.snapshot() == ["fast"])
        #expect(results.first { $0.callID == read.callID }?.success == true)
        #expect(results.first { $0.callID == mutation.callID }?.error?.code == CoreError.Code.executionStateUnknown.rawValue)
        #expect(results.first { $0.callID == mutation.callID }?.metadata["verificationRequired"] == "true")
        #expect(snapshot.messages.filter { $0.role == .tool }.count == 1)
        #expect(provider.recorder.requests.count == 1)
    }
}
