import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// FakeProvider：离线验证 Session → Agent → DMA → 控制面的完整多轮链路。
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelRequest] = []

    func record(_ request: ModelRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    var requests: [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [TurnResult] = []
    private var failures: [TurnFailure] = []
    private var sequence: [String] = []

    func recordStarted() {
        lock.lock()
        sequence.append("started")
        lock.unlock()
    }

    func recordCompleted(_ result: TurnResult) {
        lock.lock()
        completed.append(result)
        sequence.append("completed")
        lock.unlock()
    }

    func recordFailed(_ failure: TurnFailure) {
        lock.lock()
        failures.append(failure)
        sequence.append("failed")
        lock.unlock()
    }

    var completions: [TurnResult] {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    var failuresRecorded: [TurnFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    var eventSequence: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }
}

/// 即时完成、按脚本回放事件的 Provider。
final class ScriptedFakeProvider: ModelProvider {
    let script: [[ModelEvent]]
    let recorder: RequestRecorder

    init(script: [[ModelEvent]], recorder: RequestRecorder = RequestRecorder()) {
        self.script = script
        self.recorder = recorder
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let turnEvents = script[min(recorder.requests.count - 1, script.count - 1)]
        return AsyncThrowingStream { continuation in
            for event in turnEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// 可控节奏的 Provider：外部手动 emit/finish，用于并发与失败时序测试。
actor ControllableFakeProvider: ModelProvider {
    let recorder = RequestRecorder()
    private var continuations: [AsyncThrowingStream<ModelEvent, Error>.Continuation] = []
    private(set) var streamCount = 0

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        // 在 actor 内同步注册，保证 emit 不会早于注册。
        var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ModelEvent, Error> { continuation = $0 }
        continuations.append(continuation!)
        streamCount += 1
        return stream
    }

    /// 确定性等待：直到指定数量的 provider 流已被建立（pump 已挂上）。
    func waitStreams(_ count: Int) async {
        while streamCount < count {
            await Task.yield()
        }
    }

    func emit(_ events: [ModelEvent], finish: Bool) {
        for continuation in continuations {
            for event in events {
                continuation.yield(event)
            }
            if finish {
                continuation.finish()
            }
        }
        if finish {
            continuations.removeAll()
        }
    }
}

struct AgentSessionTests {
    private func makeHost(_ provider: any ModelProvider) async -> CoreHost {
        let host = try! CoreHost(providerAssembly: ModelRuntimeAssembly(
            provider: provider,
            modelID: ModelID("fake-model")
        ))
        await host.start()
        return host
    }

    /// 启动事件收集 Task，等待指定数量 turn 结束（completed 或 failed）。
    private func startEventCollector(_ client: LingXiClient, recorder: OutcomeRecorder) async -> Task<Void, Never> {
        let eventStream = await client.events()
        return Task {
            for await event in eventStream {
                switch event {
                case .turnStarted:
                    recorder.recordStarted()
                case let .turnCompleted(result):
                    recorder.recordCompleted(result)
                case let .turnFailed(failure):
                    recorder.recordFailed(failure)
                default:
                    break
                }
            }
        }
    }

    private func waitForTurns(_ recorder: OutcomeRecorder, count: Int) async {
        let deadline = Date().addingTimeInterval(10)
        while recorder.completions.count + recorder.failuresRecorded.count < count {
            if Date() > deadline {
                Issue.record("等待 turn 完成超时（completed=\(recorder.completions.count) failed=\(recorder.failuresRecorded.count)）")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func firstTurnSendsOnlyUserMessage() async throws {
        let provider = ScriptedFakeProvider(script: [[
            .textDelta("你好！"),
            .completed(.stop),
        ]])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "我叫小狐狸")
        for try await _ in stream {}

        await waitForTurns(recorder, count: 1)
        events.cancel()

        let request = try #require(provider.recorder.requests.first)
        #expect(request.messages.first?.content == "我叫小狐狸")
        #expect(request.messages.first?.role == .user)
        #expect(request.messages.dropFirst().allSatisfy { $0.role == .system })
        #expect(recorder.eventSequence == ["started", "completed"])
    }

    @Test func shutdownCancelsActiveTurnAndClosesItsDataStream() async throws {
        let provider = ControllableFakeProvider()
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "等待")
        await provider.waitStreams(1)

        await host.shutdown()
        for try await _ in stream {}

        #expect(try await client.coreState() == .stopped)
    }

    @Test func secondTurnCarriesFullHistory() async throws {
        let provider = ScriptedFakeProvider(script: [
            [.textDelta("你好，小狐狸！"), .completed(.stop)],
            [.textDelta("你叫小狐狸。"), .completed(.stop)],
        ])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionID = try await client.createSession()
        let turn1 = try await client.sendMessage(sessionID: sessionID, content: "我叫小狐狸，请记住")
        for try await _ in turn1 {}
        await waitForTurns(recorder, count: 1)

        let turn2 = try await client.sendMessage(sessionID: sessionID, content: "我叫什么？")
        for try await _ in turn2 {}
        await waitForTurns(recorder, count: 2)
        events.cancel()

        let requests = provider.recorder.requests
        #expect(requests.count == 2)
        // 第 2 轮必须包含 user#1 / assistant#1 / user#2 的完整历史。
        #expect(requests[1].messages.prefix(3).map(\.role) == [.user, .assistant, .user])
        #expect(requests[1].messages.prefix(3).map(\.content) == [
            "我叫小狐狸，请记住",
            "你好，小狐狸！",
            "我叫什么？",
        ])
        #expect(requests[1].messages.dropFirst(3).allSatisfy { $0.role == .system })
    }

    @Test func reasoningNeverEntersAssistantContent() async throws {
        let provider = ScriptedFakeProvider(script: [[
            .reasoningDelta("内心思考："),
            .reasoningDelta("他要的是名字"),
            .textDelta("你叫"),
            .textDelta("小狐狸"),
            .completed(.stop),
        ]])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "我叫小狐狸")

        var reasoningChunks = 0
        var textChunks = 0
        for try await chunk in stream {
            switch chunk.kind {
            case .reasoning: reasoningChunks += 1
            case .text: textChunks += 1
            }
        }
        await waitForTurns(recorder, count: 1)
        events.cancel()

        // DMA 两种 chunk 分离。
        #expect(reasoningChunks == 2)
        #expect(textChunks == 2)

        // Session 中 assistant message 只有一条，且不含 reasoning。
        let snapshot = try await client.session(sessionID)
        let assistants = snapshot.messages.filter { $0.role == .assistant }
        #expect(assistants.count == 1, "turn 完成时只写一次 assistant message")
        #expect(assistants.first?.content == "你叫小狐狸")
        #expect(assistants.first?.content.contains("内心思考") == false)

        // history 里也不应有 reasoning 内容。
        #expect(snapshot.messages.contains { $0.content.contains("内心思考") } == false)
    }

    @Test func failedTurnKeepsUserMessageWithoutFakeAssistant() async throws {
        let provider = ScriptedFakeProvider(script: [[
            .textDelta("部分输出"),
            .failed(CoreError(code: .modelStream, message: "中断")),
        ]])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "这条会失败")
        for try await _ in stream {}

        await waitForTurns(recorder, count: 1)
        events.cancel()

        #expect(recorder.failuresRecorded.count == 1)
        #expect(recorder.failuresRecorded.first?.error.code == .modelStream)

        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user], "失败 turn 只保留 user message")
        #expect(snapshot.messages.first?.content == "这条会失败")
        #expect(!snapshot.messages.contains { $0.role == .assistant })
        #expect(recorder.eventSequence == ["started", "failed"])
    }

    @Test func concurrentTurnsOnSameSessionAreSerialized() async throws {
        let provider = ControllableFakeProvider()
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let sessionID = try await client.createSession()

        // 两个首请求同时起跑：只能一个占用该 Session 的 Lane。
        let requestA = Task { try await client.sendMessage(sessionID: sessionID, content: "并发请求 A") }
        let requestB = Task { try await client.sendMessage(sessionID: sessionID, content: "并发请求 B") }
        let results = [await requestA.result, await requestB.result]
        var activeStream: AsyncThrowingStream<StreamChunk, Error>?
        var rejected = 0
        for result in results {
            switch result {
            case let .success(stream):
                activeStream = stream
            case let .failure(error as CoreError):
                #expect(error.code == .turnAlreadyRunning)
                rejected += 1
            case let .failure(error):
                Issue.record("收到非预期错误: \(error)")
            }
        }
        #expect(rejected == 1)
        let stream1 = try #require(activeStream)

        await provider.waitStreams(1)
        await provider.emit([
            .textDelta("done"),
            .completed(.stop),
        ], finish: true)
        for try await _ in stream1 {}

        // Session 状态正确：只有 user#1 + assistant#1，无乱序。
        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant])
        #expect(["并发请求 A", "并发请求 B"].contains(snapshot.messages[0].content))
        #expect(snapshot.messages[1].content == "done")

        // turn 1 结束后，turn 2 可以正常启动（顺序链延续）。
        let stream2 = try await client.sendMessage(sessionID: sessionID, content: "现在轮到我")
        await provider.waitStreams(2)
        await provider.emit([.textDelta("second done"), .completed(.stop)], finish: true)
        for try await _ in stream2 {}

        let final = try await client.session(sessionID)
        #expect(final.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(final.messages.dropFirst().map(\.content) == ["done", "现在轮到我", "second done"])
    }

    @Test func differentSessionsRunIndependently() async throws {
        let provider = ScriptedFakeProvider(script: [
            [.textDelta("A"), .completed(.stop)],
            [.textDelta("B"), .completed(.stop)],
        ])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionA = try await client.createSession()
        let sessionB = try await client.createSession()

        // 两个 Session 的 turn 交错启动，互不拒绝、互不串数据。
        let streamA = try await client.sendMessage(sessionID: sessionA, content: "A 的消息")
        let streamB = try await client.sendMessage(sessionID: sessionB, content: "B 的消息")
        for try await _ in streamA {}
        for try await _ in streamB {}
        await waitForTurns(recorder, count: 2)
        events.cancel()

        let snapshotA = try await client.session(sessionA)
        let snapshotB = try await client.session(sessionB)
        #expect(snapshotA.messages.first?.content == "A 的消息")
        #expect(snapshotB.messages.first?.content == "B 的消息")
        #expect(Set([snapshotA.messages.last?.content, snapshotB.messages.last?.content]) == ["A", "B"])
    }

    @Test func unconfiguredProviderFailsFast() async throws {
        let host = try CoreHost(providerAssembly: ProviderSetup.unavailable)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)

        let sessionID = try await client.createSession()
        do {
            _ = try await client.sendMessage(sessionID: sessionID, content: "hi")
            Issue.record("未配置 Provider 应快速失败")
        } catch let error as CoreError {
            #expect(error.code == .provider)
        }

        // Provider 启动失败仍保留 user message；不能写虚假 assistant message。
        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.map(\.role) == [.user])
        #expect(snapshot.messages.first?.content == "hi")
    }

    @Test func turnCompletedReportsUsageAndMessageID() async throws {
        let provider = ScriptedFakeProvider(script: [[
            .textDelta("答案"),
            .usage(ModelUsage(inputTokens: 3, outputTokens: 7, reasoningTokens: 2)),
            .completed(.stop),
        ]])
        let host = await makeHost(provider)
        let client = LingXiClient.inProcess(endpoint: host)

        let recorder = OutcomeRecorder()
        let events = await startEventCollector(client, recorder: recorder)

        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "问题")
        for try await _ in stream {}
        await waitForTurns(recorder, count: 1)
        events.cancel()

        let result = try #require(recorder.completions.first)
        #expect(result.sessionID == sessionID)
        #expect(result.finishReason == .stop)
        #expect(result.usage?.outputTokens == 7)
        #expect(result.usage?.reasoningTokens == 2)

        // assistantMessageID 与 Session 内消息一致。
        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.last?.id == result.assistantMessageID)
    }
}
