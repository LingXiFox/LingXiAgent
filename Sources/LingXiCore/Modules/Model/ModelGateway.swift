import Foundation
import LingXiProtocol

/// 模型网关：Core 内所有模型推理的正式入口。
/// 持有当前 Provider，屏蔽 Provider 的构建与选择细节。
public struct ModelGateway: Sendable {
    public struct Unavailable: Sendable, Equatable {
        public let missingRequirements: [String]
    }

    private let provider: (any ModelProvider)?
    public let endpoint: ResolvedModelEndpoint?
    public let missingRequirements: [String]
    public let reasoning: String?
    public let deadlinePolicy: ExecutionDeadlinePolicy
    private let rateScheduler: ProviderRateScheduler
    public var modelID: ModelID? { endpoint?.modelID }
    public var contextProfile: ModelContextProfile { endpoint?.contextProfile ?? ModelContextProfile() }

    public init(provider: (any ModelProvider)?, modelID: ModelID?, missingRequirements: [String] = [], contextProfile: ModelContextProfile = ModelContextProfile(), reasoning: String? = nil, deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy()) {
        self.provider = provider
        endpoint = modelID.map { ResolvedModelEndpoint(providerID: "default", modelID: $0, baseURL: nil, wireProtocol: .chatCompletions, contextProfile: contextProfile) }
        self.missingRequirements = missingRequirements
        self.reasoning = reasoning
        self.deadlinePolicy = deadlinePolicy
        rateScheduler = .shared
    }

    public init(assembly: ModelRuntimeAssembly?, missingRequirements: [String] = [], reasoning: String? = nil, deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy()) {
        provider = assembly?.provider
        endpoint = assembly?.endpoint
        self.missingRequirements = missingRequirements
        self.reasoning = reasoning
        self.deadlinePolicy = deadlinePolicy
        rateScheduler = .shared
    }

    public var isConfigured: Bool { provider != nil && modelID != nil }

    public var status: ProviderStatus {
        ProviderStatus(
            configured: isConfigured,
            model: modelID?.rawValue,
            baseURL: endpoint?.baseURL?.absoluteString,
            missingRequirements: missingRequirements
        )
    }

    /// Fast Path：进入模型高速总线。
    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        guard let provider else {
            throw CoreError(
                code: .provider,
                message: "未配置模型 Provider；请检查 providers.json 与 CredentialStore: \(missingRequirements.joined(separator: ", "))"
            )
        }
        guard let endpoint else { throw CoreError(code: .provider, message: "未配置模型 Endpoint") }

        let currentContext = AgentExecutionContext.current
        let sessionID = currentContext?.sessionID ?? SessionID("ephemeral")
        let runID = request.executionID ?? currentContext?.runID
        let providerRequestID = "local:\(request.requestID.rawValue)"

        if await ProviderActivityRegistry.shared.isCancelled(providerRequestID: providerRequestID, runID: runID) {
            throw CancellationError()
        }

        await ProviderActivityRegistry.shared.record(
            sessionID: sessionID,
            runID: runID,
            providerRequestID: providerRequestID,
            state: .scheduled,
            model: request.model.rawValue
        )

        let estimate = ConservativeTokenEstimator().estimate(text: request.messages.map(\.content).joined(separator: "\n")) + ConservativeTokenEstimator().estimate(tools: request.tools)
        let policy = endpoint.rateLimits.retryPolicy
        var retries = 0

        while true {
            try Task.checkCancellation()
            if await ProviderActivityRegistry.shared.isCancelled(providerRequestID: providerRequestID, runID: runID) {
                throw CancellationError()
            }
            await ProviderActivityRegistry.shared.record(
                sessionID: sessionID,
                runID: runID,
                providerRequestID: providerRequestID,
                state: .waitingForRateBudget,
                model: request.model.rawValue
            )
            try await rateScheduler.admit(endpoint: endpoint, requestID: request.requestID, estimatedTokens: estimate)
            await ProviderActivityRegistry.shared.record(
                sessionID: sessionID,
                runID: runID,
                providerRequestID: providerRequestID,
                state: .requesting,
                model: request.model.rawValue
            )
            do {
                // Admission intentionally precedes the provider watchdog: queueing must not consume inference, tool, or HITL timeouts.
                let deadline = deadlinePolicy.deadline(
                    for: .provider,
                    requested: request.overallTimeoutSeconds.map { .milliseconds(Int($0 * 1_000)) }
                )
                let source = try await ExecutionWatchdog.run(deadline) {
                    try await provider.stream(request)
                }
                let effective = ExecutionDeadline(category: .provider, startedAt: deadline.startedAt, timeout: deadline.timeout, idleTimeout: request.idleTimeoutSeconds.map { .milliseconds(Int($0 * 1_000)) } ?? deadline.idleTimeout)
                return releaseRatePermit(
                    ExecutionWatchdog.stream(source, deadline: effective),
                    endpoint: endpoint,
                    requestID: request.requestID,
                    sessionID: sessionID,
                    runID: runID,
                    providerRequestID: providerRequestID
                )
            } catch let error as ProviderRateLimitError {
                await rateScheduler.release(endpoint: endpoint)
                let delay = retryDelay(error.retryAfter, policy: policy, retry: retries + 1)
                await rateScheduler.recordRateLimit(endpoint: endpoint, requestID: request.requestID, cooldown: delay)
                guard retries < policy.maxRetries else { throw error.underlying }
                retries += 1
                await rateScheduler.recordRetry(requestID: request.requestID)
                try await Task.sleep(for: delay)
                await rateScheduler.recordWait(requestID: request.requestID, duration: delay)
            } catch {
                await rateScheduler.release(endpoint: endpoint)
                let coreErr = error as? CoreError
                let isTransient = (coreErr?.code == .transportLost || coreErr?.code == .commandTimedOut)
                if isTransient && !(error is CancellationError) && retries < policy.maxRetries {
                    retries += 1
                    let delay = retryDelay(nil, policy: policy, retry: retries)
                    await rateScheduler.recordRetry(requestID: request.requestID)
                    await ProviderActivityRegistry.shared.record(
                        sessionID: sessionID,
                        runID: runID,
                        providerRequestID: providerRequestID,
                        state: .scheduled,
                        model: request.model.rawValue
                    )
                    try? await Task.sleep(for: delay)
                    await rateScheduler.recordWait(requestID: request.requestID, duration: delay)
                    continue
                }
                let terminalState: ProviderActivityState = (error is CancellationError) ? .cancelled : .failed
                await ProviderActivityRegistry.shared.record(
                    sessionID: sessionID,
                    runID: runID,
                    providerRequestID: providerRequestID,
                    state: terminalState,
                    model: request.model.rawValue
                )
                throw error
            }
        }
    }

    public func rateMetrics(for requestID: ModelRequestID) async -> ProviderRateMetrics {
        await rateScheduler.metrics(for: requestID)
    }

    private func releaseRatePermit(
        _ source: AsyncThrowingStream<ModelEvent, Error>,
        endpoint: ResolvedModelEndpoint,
        requestID: ModelRequestID,
        sessionID: SessionID,
        runID: AgentRunID?,
        providerRequestID: String
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let doneFlag = StreamDoneFlag()
        return AsyncThrowingStream { continuation in
            let pump = Task {
                defer { Task { await rateScheduler.release(endpoint: endpoint) } }
                do {
                    var streamedFirstChunk = false
                    for try await event in source {
                        if Task.isCancelled {
                            doneFlag.markDone()
                            await ProviderActivityRegistry.shared.record(
                                sessionID: sessionID,
                                runID: runID,
                                providerRequestID: providerRequestID,
                                state: .cancelled,
                                model: endpoint.modelID.rawValue
                            )
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if await ProviderActivityRegistry.shared.isCancelled(providerRequestID: providerRequestID, runID: runID) {
                            doneFlag.markDone()
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if !streamedFirstChunk {
                            streamedFirstChunk = true
                            await ProviderActivityRegistry.shared.record(
                                sessionID: sessionID,
                                runID: runID,
                                providerRequestID: providerRequestID,
                                state: .streaming,
                                model: endpoint.modelID.rawValue
                            )
                        }
                        if case let .usage(usage) = event {
                            await rateScheduler.recordUsage(endpoint: endpoint, requestID: requestID, usage: usage)
                        }
                        continuation.yield(event)
                    }
                    doneFlag.markDone()
                    await ProviderActivityRegistry.shared.record(
                        sessionID: sessionID,
                        runID: runID,
                        providerRequestID: providerRequestID,
                        state: .completed,
                        model: endpoint.modelID.rawValue
                    )
                    continuation.finish()
                } catch {
                    doneFlag.markDone()
                    let terminalState: ProviderActivityState = (error is CancellationError) ? .cancelled : .failed
                    await ProviderActivityRegistry.shared.record(
                        sessionID: sessionID,
                        runID: runID,
                        providerRequestID: providerRequestID,
                        state: terminalState,
                        model: endpoint.modelID.rawValue
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                guard !doneFlag.isDone else { return }
                pump.cancel()
                Task {
                    await ProviderActivityRegistry.shared.cancel(providerRequestID: providerRequestID)
                }
            }
        }
    }

    private func retryDelay(_ retryAfter: Duration?, policy: ProviderRetryPolicy, retry: Int) -> Duration {
        if let retryAfter { return retryAfter }
        let base = min(policy.maxDelayMilliseconds, policy.initialDelayMilliseconds * (1 << min(retry - 1, 20)))
        let jitter = Int(Double(base) * policy.jitterRatio * Double.random(in: 0...1))
        return .milliseconds(base + jitter)
    }
}

private final class StreamDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

/// 模型高速总线：所有 Adapter 在这里收口为“恰好一个合法 terminal”。
public struct ModelBus: Sendable {
    public let gateway: ModelGateway

    public init(gateway: ModelGateway) {
        self.gateway = gateway
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let source = try await gateway.stream(request)
        return AsyncThrowingStream { continuation in
            let pump = Task {
                var terminal: ModelFinishReason?
                var completedCalls = 0
                do {
                    for try await event in source {
                        if terminal != nil {
                            continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider terminal 后仍返回事件")))
                            continuation.finish()
                            return
                        }
                        switch event {
                        case .toolCallCompleted:
                            completedCalls += 1
                            continuation.yield(event)
                        case let .completed(reason):
                            terminal = reason
                        case .failed:
                            continuation.yield(event)
                            continuation.finish()
                            return
                        default:
                            continuation.yield(event)
                        }
                    }
                    if Task.isCancelled { continuation.finish(); return }
                    guard let terminal else {
                        continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider stream 缺少 terminal")))
                        continuation.finish()
                        return
                    }
                    guard (completedCalls > 0) == (terminal == .toolCalls) else {
                        continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider terminal 与 ToolCall 不一致")))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.completed(terminal))
                    continuation.finish()
                } catch let error as CoreError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider stream 连接中断")))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in pump.cancel() }
        }
    }
}
