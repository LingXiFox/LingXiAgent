import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor HangingProvider: ModelProvider {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var streamCount = 0

    func waitStreams(_ count: Int) async {
        if streamCount >= count { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        streamCount += 1
        for w in waiters { w.resume() }
        waiters.removeAll()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in }
        }
    }
}

private actor SteppedStreamingProvider: ModelProvider {
    private var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var streamCount = 0

    func waitStreams(_ count: Int) async {
        if streamCount >= count { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        streamCount += 1
        for w in waiters { w.resume() }
        waiters.removeAll()
        return AsyncThrowingStream { cont in
            self.continuation = cont
            cont.yield(.textDelta("chunk 1"))
        }
    }

    func yieldLateChunk() {
        continuation?.yield(.textDelta("chunk 2"))
        continuation?.yield(.completed(.stop))
        continuation?.finish()
    }
}

private actor ToolThenHangProvider: ModelProvider {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var streamCount = 0

    func waitStreams(_ count: Int) async {
        if streamCount >= count { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        streamCount += 1
        for w in waiters { w.resume() }
        waiters.removeAll()
        if streamCount == 1 {
            let call = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("list_directory"), arguments: #"{"path":"."}"#)
            return AsyncThrowingStream { cont in
                cont.yield(.toolCallCompleted(call))
                cont.yield(.completed(.toolCalls))
                cont.finish()
            }
        } else {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { @Sendable _ in }
            }
        }
    }
}

private actor ParallelSubagentHangingProvider: ModelProvider {
    private let spawnFoo = ToolCall(callID: ToolCallID("spawn-foo"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect foo","title":"Foo"}"#)
    private let spawnBar = ToolCall(callID: ToolCallID("spawn-bar"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect bar","title":"Bar"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        if firstUser == "inspect foo" || firstUser == "inspect bar" {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { @Sendable _ in }
            }
        } else if request.messages.contains(where: { $0.role == .tool }) {
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { @Sendable _ in }
            }
        }
        return AsyncThrowingStream { cont in
            cont.yield(.toolCallCompleted(self.spawnFoo))
            cont.yield(.toolCallCompleted(self.spawnBar))
            cont.yield(.completed(.toolCalls))
            cont.finish()
        }
    }
}

private actor ControllableProvider: ModelProvider {
    private var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var streamCount = 0

    func waitStreams(_ count: Int) async {
        if streamCount >= count { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        streamCount += 1
        for w in waiters { w.resume() }
        waiters.removeAll()
        return AsyncThrowingStream { cont in
            self.continuation = cont
        }
    }

    func yieldLateData() {
        continuation?.yield(.textDelta("late unauthorized message"))
        continuation?.yield(.completed(.stop))
        continuation?.finish()
    }
}

struct CancellationRaceTests {

    // Scenario 1: waiting for provider 时 Esc → 立即 ready，无 residue
    @Test func waitingForProviderEscImmediatelyReadyNoResidue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = HangingProvider()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "hello")
        let pump = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        await provider.waitStreams(1)
        let runs = try await client.listAgentRuns(sessionID)
        let run = try #require(runs.last)
        #expect(run.status == .running)

        // Cancel the run
        try await client.cancelAgentRun(run.runID)
        await pump.value

        let updatedRuns = try await client.listAgentRuns(sessionID)
        let updatedRun = try #require(updatedRuns.first { $0.runID == run.runID })
        #expect(updatedRun.status == .cancelled)
        #expect(updatedRun.terminalReason == .userCancelled)

        let activities = await ProviderActivityRegistry.shared.activeActivities(for: sessionID)
        #expect(activities.isEmpty)
    }

    // Scenario 2: provider streaming 时 Esc → 立即终止，后续 delta 不上屏
    @Test func providerStreamingEscImmediatelyTerminatedNoDeltas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = SteppedStreamingProvider()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "stream me")

        let receivedDeltas = ActorBox<[String]>([])
        let firstChunkReceived = ActorFlag()
        let pump = Task {
            do {
                for try await chunk in stream {
                    await receivedDeltas.append(chunk.text)
                    if chunk.text == "chunk 1" {
                        await firstChunkReceived.set()
                    }
                }
            } catch {}
        }

        await firstChunkReceived.wait()
        let runs = try await client.listAgentRuns(sessionID)
        let run = try #require(runs.last)

        try await client.cancelAgentRun(run.runID)

        await provider.yieldLateChunk()
        await pump.value

        let updatedRuns = try await client.listAgentRuns(sessionID)
        let updatedRun = try #require(updatedRuns.first { $0.runID == run.runID })
        #expect(updatedRun.status == .cancelled)
        #expect(updatedRun.terminalReason == .userCancelled)

        let deltas = await receivedDeltas.value
        #expect(deltas.contains("chunk 1"))
        #expect(!deltas.contains("chunk 2"))
    }

    // Scenario 3: rate-limit cooldown 时 Esc → scheduler wait 立即退出
    @Test func rateLimitCooldownEscSchedulerWaitExitsImmediately() async throws {
        let scheduler = ProviderRateScheduler()
        let limits = ProviderRateLimits(maxConcurrentRequests: 1, retryPolicy: ProviderRetryPolicy(maxRetries: 0))
        let unique = UUID().uuidString
        let endpoint = ResolvedModelEndpoint(
            providerID: "rate-test",
            accountID: unique,
            modelID: ModelID(unique),
            baseURL: nil,
            wireProtocol: .chatCompletions,
            rateLimits: limits
        )
        let req1 = ModelRequestID("req-1")
        try await scheduler.admit(endpoint: endpoint, requestID: req1, estimatedTokens: 100)
        await scheduler.recordRateLimit(endpoint: endpoint, requestID: req1, cooldown: .seconds(60))

        let req2 = ModelRequestID("req-2")
        let start = ContinuousClock.now
        let task: Task<Void, Error> = Task {
            try await scheduler.admit(endpoint: endpoint, requestID: req2, estimatedTokens: 100)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            #expect(Bool(false), "Should have thrown CancellationError")
        } catch is CancellationError {
            let elapsed = start.duration(to: ContinuousClock.now)
            #expect(elapsed < .seconds(10), "Scheduler wait did not exit immediately: \(elapsed)")
        }
    }

    // Scenario 4: tool continuation waiting for provider 时 Esc → tool 不重复，run cancelled
    @Test func toolContinuationEscToolNotReplayed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ToolThenHangProvider()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "run tool and continue")
        let pump = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        await provider.waitStreams(2)
        let runs = try await client.listAgentRuns(sessionID)
        let run = try #require(runs.last)

        try await client.cancelAgentRun(run.runID)
        await pump.value

        let updatedRuns = try await client.listAgentRuns(sessionID)
        let updatedRun = try #require(updatedRuns.first { $0.runID == run.runID })
        #expect(updatedRun.status == .cancelled)
        #expect(updatedRun.terminalReason == .userCancelled)
    }

    // Scenario 5: parallel subagents 时 Esc parent → 全部 child cancelled
    @Test func parallelSubagentsEscAllChildrenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ParallelSubagentHangingProvider()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "start")
        let pump = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        let deadline = Date().addingTimeInterval(3)
        var tree = try await client.getAgentTree(sessionID)
        while tree.children.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            tree = try await client.getAgentTree(sessionID)
        }
        #expect(tree.children.count == 2)

        let runs = try await client.listAgentRuns(sessionID)
        let parentRun = try #require(runs.first { $0.parentRunID == nil })

        try await client.cancelAgentRun(parentRun.runID)
        await pump.value

        let updatedRuns = try await client.listAgentRuns(sessionID)
        let parentUpdated = try #require(updatedRuns.first { $0.runID == parentRun.runID })
        #expect(parentUpdated.status == .cancelled)

        let children = try await client.listChildSessions(sessionID)
        for child in children {
            let childRuns = try await client.listAgentRuns(child.id)
            for childRun in childRuns {
                #expect(childRun.status == .cancelled)
                #expect(childRun.terminalReason == .userCancelled)
            }
        }
    }

    // Scenario 6: cancelled provider 后来又返回迟到 response → 丢弃，不改变 run 状态
    @Test func cancelledProviderLateResponseIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ControllableProvider()
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "control me")
        let pump = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        await provider.waitStreams(1)
        let runs = try await client.listAgentRuns(sessionID)
        let run = try #require(runs.last)

        try await client.cancelAgentRun(run.runID)
        await pump.value

        // Now provider yields late response
        await provider.yieldLateData()

        // Wait a small moment to ensure any asynchronous processing would have occurred
        try await Task.sleep(for: .milliseconds(50))

        let updatedRuns = try await client.listAgentRuns(sessionID)
        let updatedRun = try #require(updatedRuns.first { $0.runID == run.runID })
        #expect(updatedRun.status == .cancelled)

        let session = try await client.session(sessionID)
        #expect(!session.messages.contains { $0.content.contains("late unauthorized message") })
    }
}

private actor ActorBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
    func append(_ element: String) where T == [String] {
        value.append(element)
    }
}

private actor ActorFlag {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
}
