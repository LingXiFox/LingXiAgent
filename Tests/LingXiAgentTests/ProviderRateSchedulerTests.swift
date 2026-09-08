import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
import LingXiClient

@Suite struct ProviderRateSchedulerTests {
    @Test func rateLimitedRequestRetriesBeforeAnyProviderEvent() async throws {
        let provider = ScriptedRateProvider(outcomes: [.rateLimited, .events([.started, .textDelta("recovered"), .completed(.stop)])])
        let gateway = gateway(provider: provider, retryPolicy: ProviderRetryPolicy(maxRetries: 1, initialDelayMilliseconds: 0, maxDelayMilliseconds: 0, jitterRatio: 0))
        let request = request()

        let events = try await collect(gateway.stream(request))
        let metrics = await gateway.rateMetrics(for: request.requestID)

        #expect(events.contains(.textDelta("recovered")))
        #expect(await provider.callCount() == 2)
        #expect(metrics.retryCount == 1)
        #expect(metrics.rateLimit429Count == 1)
    }

    @Test func retryBudgetExhaustionReturnsTheOriginalProviderError() async throws {
        let provider = ScriptedRateProvider(outcomes: [.rateLimited, .rateLimited])
        let gateway = gateway(provider: provider, retryPolicy: ProviderRetryPolicy(maxRetries: 1, initialDelayMilliseconds: 0, maxDelayMilliseconds: 0, jitterRatio: 0))
        let request = request()

        await #expect(throws: CoreError.self) {
            _ = try await gateway.stream(request)
        }
        let metrics = await gateway.rateMetrics(for: request.requestID)
        #expect(await provider.callCount() == 2)
        #expect(metrics.retryCount == 1)
        #expect(metrics.rateLimit429Count == 2)
    }

    @Test func retryDoesNotDuplicateToolEvents() async throws {
        let call = ToolCall(callID: ToolCallID("tool-once"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
        let provider = ScriptedRateProvider(outcomes: [.rateLimited, .events([.started, .toolCallCompleted(call), .completed(.toolCalls)])])
        let gateway = gateway(provider: provider, retryPolicy: ProviderRetryPolicy(maxRetries: 1, initialDelayMilliseconds: 0, maxDelayMilliseconds: 0, jitterRatio: 0))

        let events = try await collect(gateway.stream(request()))
        #expect(events.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } } == [call])
        #expect(await provider.callCount() == 2)
    }

    @Test func recoveryMetricsReachPerformanceAndDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedRateProvider(outcomes: [.rateLimited, .events([.started, .textDelta("recovered"), .completed(.stop)])])
        let endpoint = rateEndpoint(retryPolicy: ProviderRetryPolicy(maxRetries: 1, initialDelayMilliseconds: 0, maxDelayMilliseconds: 0, jitterRatio: 0))
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: endpoint.modelID, endpoint: endpoint)
        let selection = ModelSelection(providerID: endpoint.providerID, accountID: endpoint.accountID, profileID: endpoint.profileID, modelID: endpoint.modelID.rawValue)
        let host = try CoreHost(providerAssembly: assembly, modelRuntimes: ["\(endpoint.accountID!)::\(endpoint.profileID!)": assembly], defaultModelSelection: selection, workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "retry") {}

        let trace = try #require(await host.performanceStoreRef.providerCalls(for: sessionID).first)
        let diagnostics = try await client.diagnostics()
        #expect(trace.retryCount == 1)
        #expect(trace.rateLimit429Count == 1)
        #expect(diagnostics.trace.contains { $0.event == "provider.call.trace" && $0.metadata["retryCount"] == "1" && $0.metadata["rateLimit429Count"] == "1" })
    }

    @Test func retryDelayContributesToRateWaitMetrics() async throws {
        let provider = ScriptedRateProvider(outcomes: [.rateLimitedWithoutRetryAfter, .events([.started, .completed(.stop)])])
        let gateway = gateway(provider: provider, retryPolicy: ProviderRetryPolicy(maxRetries: 1, initialDelayMilliseconds: 1, maxDelayMilliseconds: 1, jitterRatio: 0))
        let request = request()

        _ = try await collect(gateway.stream(request))

        #expect((await gateway.rateMetrics(for: request.requestID)).rateWaitMilliseconds >= 1)
    }

    @Test func rateLimitCooldownBlocksMatchingRequests() async throws {
        let scheduler = ProviderRateScheduler()
        let endpoint = rateEndpoint(retryPolicy: ProviderRetryPolicy(maxRetries: 0))
        let requestID = ModelRequestID("cooldown")
        await scheduler.recordRateLimit(endpoint: endpoint, requestID: requestID, cooldown: .milliseconds(10))
        let clock = ContinuousClock()
        let started = clock.now

        try await scheduler.admit(endpoint: endpoint, requestID: requestID, estimatedTokens: 1)

        #expect(started.duration(to: clock.now) >= .milliseconds(10))
        await scheduler.release(endpoint: endpoint)
    }

    @Test func rateLimitPrefersRetryAfterMilliseconds() throws {
        let error = ProviderRateLimitError.from(
            statusCode: 429,
            headers: ["Retry-After-Ms": "1250", "Retry-After": "10"],
            body: "rate limited",
            underlying: CoreError(code: .provider, message: "status=429")
        )

        #expect((error as? ProviderRateLimitError)?.retryAfter == .milliseconds(1_250))
    }

    @Test func globalConcurrencyIsSharedByMatchingProviderModelAndAccount() async throws {
        let provider = ConcurrentRateProvider()
        let limits = ProviderRateLimits(maxConcurrentRequests: 1, retryPolicy: ProviderRetryPolicy(maxRetries: 0))
        let unique = UUID().uuidString
        let configured = ResolvedModelEndpoint(providerID: "concurrency", accountID: unique, modelID: ModelID(unique), baseURL: nil, wireProtocol: .chatCompletions, rateLimits: limits)
        let first = ModelGateway(assembly: ModelRuntimeAssembly(provider: provider, modelID: configured.modelID, endpoint: configured))
        let second = ModelGateway(assembly: ModelRuntimeAssembly(provider: provider, modelID: configured.modelID, endpoint: configured))

        async let firstEvents = collect(first.stream(request(model: configured.modelID)))
        async let secondEvents = collect(second.stream(request(model: configured.modelID)))
        _ = try await (firstEvents, secondEvents)

        #expect(await provider.maximumConcurrency() == 1)
    }

    private func gateway(provider: any ModelProvider, retryPolicy: ProviderRetryPolicy) -> ModelGateway {
        let endpoint = rateEndpoint(retryPolicy: retryPolicy)
        return ModelGateway(assembly: ModelRuntimeAssembly(provider: provider, modelID: endpoint.modelID, endpoint: endpoint))
    }

    private func rateEndpoint(retryPolicy: ProviderRetryPolicy) -> ResolvedModelEndpoint {
        let unique = UUID().uuidString
        return ResolvedModelEndpoint(providerID: "rate-test", accountID: unique, profileID: unique, modelID: ModelID(unique), baseURL: nil, wireProtocol: .chatCompletions, rateLimits: ProviderRateLimits(retryPolicy: retryPolicy))
    }

    private func request(model: ModelID = ModelID("rate-test")) -> ModelRequest {
        ModelRequest(model: model, messages: [ModelMessage(role: .user, content: "test")])
    }

    private func collect(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

private actor ScriptedRateProvider: ModelProvider {
    enum Outcome: Sendable {
        case rateLimited
        case rateLimitedWithoutRetryAfter
        case events([ModelEvent])
    }

    private var outcomes: [Outcome]
    private var calls = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        calls += 1
        switch outcomes.removeFirst() {
        case .rateLimited:
            throw ProviderRateLimitError(statusCode: 429, retryAfter: .zero, underlying: CoreError(code: .provider, message: "Provider HTTP 请求失败: status=429"))
        case .rateLimitedWithoutRetryAfter:
            throw ProviderRateLimitError(statusCode: 429, underlying: CoreError(code: .provider, message: "Provider HTTP 请求失败: status=429"))
        case let .events(events):
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func callCount() -> Int { calls }
}

private actor ConcurrentRateProvider: ModelProvider {
    private var active = 0
    private var maximum = 0

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        active += 1
        maximum = max(maximum, active)
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                continuation.yield(.started)
                continuation.yield(.completed(.stop))
                self.finished()
                continuation.finish()
            }
        }
    }

    func maximumConcurrency() -> Int { maximum }

    private func finished() { active -= 1 }
}
