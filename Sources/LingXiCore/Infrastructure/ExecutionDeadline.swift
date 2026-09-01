import Foundation
import LingXiProtocol

public enum ExecutionTimeoutCategory: String, Codable, Sendable, CaseIterable {
    case quickFilesystem
    case search
    case foregroundShell
    case buildTest
    case mcp
    case provider
    case subagent
    case agentRun
}

public enum ExecutionFailure: String, Codable, Sendable, Equatable {
    case timedOut
    case idleTimedOut
    case cancelled
    case transportLost
    case executionStateUnknown
}

public struct ExecutionTimeoutSettings: Codable, Sendable, Equatable {
    public var quickFilesystemSeconds: Double
    public var searchSeconds: Double
    public var foregroundShellSeconds: Double
    public var buildTestSeconds: Double
    public var mcpSeconds: Double
    public var providerSeconds: Double
    public var providerIdleSeconds: Double
    public var subagentSeconds: Double
    public var agentRunSeconds: Double
    public var maximumSeconds: Double

    public init(
        quickFilesystemSeconds: Double = 10,
        searchSeconds: Double = 30,
        foregroundShellSeconds: Double = 60,
        buildTestSeconds: Double = 300,
        mcpSeconds: Double = 60,
        providerSeconds: Double = 120,
        providerIdleSeconds: Double = 45,
        subagentSeconds: Double = 600,
        agentRunSeconds: Double = 1_800,
        maximumSeconds: Double = 3_600
    ) {
        self.quickFilesystemSeconds = max(0.001, quickFilesystemSeconds)
        self.searchSeconds = max(0.001, searchSeconds)
        self.foregroundShellSeconds = max(0.001, foregroundShellSeconds)
        self.buildTestSeconds = max(0.001, buildTestSeconds)
        self.mcpSeconds = max(0.001, mcpSeconds)
        self.providerSeconds = max(0.001, providerSeconds)
        self.providerIdleSeconds = max(0.001, providerIdleSeconds)
        self.subagentSeconds = max(0.001, subagentSeconds)
        self.agentRunSeconds = max(0.001, agentRunSeconds)
        self.maximumSeconds = max(0.001, maximumSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case quickFilesystemSeconds, searchSeconds, foregroundShellSeconds, buildTestSeconds, mcpSeconds, providerSeconds, providerIdleSeconds, subagentSeconds, agentRunSeconds, maximumSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quickFilesystemSeconds: try values.decodeIfPresent(Double.self, forKey: .quickFilesystemSeconds) ?? 10,
            searchSeconds: try values.decodeIfPresent(Double.self, forKey: .searchSeconds) ?? 30,
            foregroundShellSeconds: try values.decodeIfPresent(Double.self, forKey: .foregroundShellSeconds) ?? 60,
            buildTestSeconds: try values.decodeIfPresent(Double.self, forKey: .buildTestSeconds) ?? 300,
            mcpSeconds: try values.decodeIfPresent(Double.self, forKey: .mcpSeconds) ?? 60,
            providerSeconds: try values.decodeIfPresent(Double.self, forKey: .providerSeconds) ?? 120,
            providerIdleSeconds: try values.decodeIfPresent(Double.self, forKey: .providerIdleSeconds) ?? 45,
            subagentSeconds: try values.decodeIfPresent(Double.self, forKey: .subagentSeconds) ?? 600,
            agentRunSeconds: try values.decodeIfPresent(Double.self, forKey: .agentRunSeconds) ?? 1_800,
            maximumSeconds: try values.decodeIfPresent(Double.self, forKey: .maximumSeconds) ?? 3_600
        )
    }
}

public struct ExecutionDeadlinePolicy: Sendable, Equatable {
    public let settings: ExecutionTimeoutSettings

    public init(settings: ExecutionTimeoutSettings = ExecutionTimeoutSettings()) {
        self.settings = settings
    }

    public func defaultTimeout(for category: ExecutionTimeoutCategory) -> Duration {
        .milliseconds(Int(seconds(for: category) * 1_000))
    }

    public func idleTimeout(for category: ExecutionTimeoutCategory) -> Duration? {
        category == .provider ? .milliseconds(Int(min(settings.providerIdleSeconds, settings.maximumSeconds) * 1_000)) : nil
    }

    public func deadline(for category: ExecutionTimeoutCategory, requested: Duration? = nil, parent: ExecutionDeadline? = nil) -> ExecutionDeadline {
        let requestedSeconds = requested.map(Self.seconds) ?? seconds(for: category)
        let parentSeconds = parent?.remainingSeconds() ?? .greatestFiniteMagnitude
        let effective = max(0, min(requestedSeconds, settings.maximumSeconds, parentSeconds))
        return ExecutionDeadline(category: category, timeout: .milliseconds(max(0, Int(effective * 1_000))), idleTimeout: idleTimeout(for: category))
    }

    private func seconds(for category: ExecutionTimeoutCategory) -> Double {
        switch category {
        case .quickFilesystem: settings.quickFilesystemSeconds
        case .search: settings.searchSeconds
        case .foregroundShell: settings.foregroundShellSeconds
        case .buildTest: settings.buildTestSeconds
        case .mcp: settings.mcpSeconds
        case .provider: settings.providerSeconds
        case .subagent: settings.subagentSeconds
        case .agentRun: settings.agentRunSeconds
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public struct ExecutionDeadline: Sendable, Equatable {
    public let category: ExecutionTimeoutCategory
    public let startedAt: ContinuousClock.Instant
    public let timeout: Duration
    public let idleTimeout: Duration?

    public init(category: ExecutionTimeoutCategory, startedAt: ContinuousClock.Instant = ContinuousClock().now, timeout: Duration, idleTimeout: Duration? = nil) {
        self.category = category
        self.startedAt = startedAt
        self.timeout = timeout
        self.idleTimeout = idleTimeout
    }

    public var overallDeadline: ContinuousClock.Instant { startedAt.advanced(by: timeout) }
    public var timeoutSeconds: Double { Self.seconds(timeout) }
    public func remaining() -> Duration { max(.zero, ContinuousClock().now.duration(to: overallDeadline)) }
    public func remainingSeconds() -> Double { Self.seconds(remaining()) }
    public func elapsedMilliseconds() -> Double { Self.seconds(startedAt.duration(to: ContinuousClock().now)) * 1_000 }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

struct ExecutionWatchdogClock: Sendable {
    let now: @Sendable () async -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = Self(
        now: { ContinuousClock().now },
        sleep: { try await Task.sleep(until: $0, clock: ContinuousClock()) }
    )
}

public enum ExecutionWatchdog {
    public static func run<T: Sendable>(_ deadline: ExecutionDeadline, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let traceID = UUID().uuidString
        lifecycle("operationStarted", traceID: traceID, category: deadline.category)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            lifecycle("watchdogStarted", traceID: traceID, category: deadline.category)
            group.addTask {
                do {
                    try await Task.sleep(until: deadline.overallDeadline, clock: ContinuousClock())
                } catch {
                    lifecycle("watchdogCancelled", traceID: traceID, category: deadline.category)
                    throw error
                }
                lifecycle("cancellationRequested", traceID: traceID, category: deadline.category)
                throw CoreError(code: .commandTimedOut, message: "执行超过 overall deadline (", category: deadline.category.rawValue)
            }
            do {
                let result = try await group.next()!
                lifecycle("operationCompleted", traceID: traceID, category: deadline.category)
                group.cancelAll()
                lifecycle("cleanupStarted", traceID: traceID, category: deadline.category)
                lifecycle("cleanupCompleted", traceID: traceID, category: deadline.category)
                lifecycle("watchdogCompleted", traceID: traceID, category: deadline.category)
                return result
            } catch {
                lifecycle("operationCompleted", traceID: traceID, category: deadline.category)
                group.cancelAll()
                lifecycle("cleanupStarted", traceID: traceID, category: deadline.category)
                lifecycle("cleanupCompleted", traceID: traceID, category: deadline.category)
                lifecycle("watchdogCompleted", traceID: traceID, category: deadline.category)
                throw error
            }
        }
    }

    public static func stream(_ source: AsyncThrowingStream<ModelEvent, Error>, deadline: ExecutionDeadline) -> AsyncThrowingStream<ModelEvent, Error> {
        stream(source, deadline: deadline, clock: .continuous)
    }

    static func stream(_ source: AsyncThrowingStream<ModelEvent, Error>, deadline: ExecutionDeadline, clock: ExecutionWatchdogClock) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let traceID = UUID().uuidString
            let state = ExecutionWatchdogState(deadline: deadline, traceID: traceID, clock: clock)
            lifecycle("operationStarted", traceID: traceID, category: deadline.category)
            let pump = Task {
                do {
                    for try await event in source {
                        if let error = await state.recordActivity() {
                            continuation.yield(.failed(error))
                            continuation.finish()
                            await state.complete()
                            lifecycle("terminalState", traceID: traceID, category: deadline.category)
                            return
                        }
                        continuation.yield(event)
                    }
                    if let error = await state.failure() {
                        continuation.yield(.failed(error))
                        lifecycle("terminalState", traceID: traceID, category: deadline.category)
                    } else {
                        lifecycle("operationCompleted", traceID: traceID, category: deadline.category)
                    }
                    await state.complete()
                    continuation.finish()
                } catch let error as CoreError {
                    continuation.yield(.failed(error))
                    lifecycle("operationCompleted", traceID: traceID, category: deadline.category)
                    await state.complete()
                    continuation.finish()
                } catch is CancellationError {
                    lifecycle("cleanupCompleted", traceID: traceID, category: deadline.category)
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(CoreError(code: .transportLost, message: "执行流连接中断")))
                    lifecycle("operationCompleted", traceID: traceID, category: deadline.category)
                    await state.complete()
                    continuation.finish()
                }
            }
            lifecycle("watchdogStarted", traceID: traceID, category: deadline.category)
            let watchdog = Task {
                while let wake = await state.nextWake() {
                    do {
                        try await clock.sleep(wake)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    if let error = await state.failure() {
                        continuation.yield(.failed(error))
                        continuation.finish()
                        pump.cancel()
                        await state.complete()
                        lifecycle("terminalState", traceID: traceID, category: deadline.category)
                        return
                    }
                }
            }
            Task { await state.setWatchdog(watchdog) }
            continuation.onTermination = { @Sendable _ in
                lifecycle("cancellationRequested", traceID: traceID, category: deadline.category)
                pump.cancel()
                watchdog.cancel()
                Task { await state.complete() }
            }
        }
    }
}

private actor ExecutionWatchdogState {
    private let deadline: ExecutionDeadline
    private let traceID: String
    private let clock: ExecutionWatchdogClock
    private var lastActivity: ContinuousClock.Instant
    private var completed = false
    private var watchdog: Task<Void, Never>?
    init(deadline: ExecutionDeadline, traceID: String, clock: ExecutionWatchdogClock) {
        self.deadline = deadline
        self.traceID = traceID
        self.clock = clock
        lastActivity = deadline.startedAt
    }
    func setWatchdog(_ task: Task<Void, Never>) {
        if completed { task.cancel() }
        else { watchdog = task }
    }
    func recordActivity() async -> CoreError? {
        if let failure = await failure() { return failure }
        lastActivity = await clock.now()
        return nil
    }
    func nextWake() -> ContinuousClock.Instant? {
        guard !completed else { return nil }
        guard let idle = deadline.idleTimeout else { return deadline.overallDeadline }
        return min(deadline.overallDeadline, lastActivity.advanced(by: idle))
    }
    func failure() async -> CoreError? {
        guard !completed else { return nil }
        let now = await clock.now()
        if now >= deadline.overallDeadline {
            return CoreError(code: .commandTimedOut, message: "执行流超过 overall timeout")
        }
        if let idle = deadline.idleTimeout, now >= lastActivity.advanced(by: idle) {
            return CoreError(code: .idleTimedOut, message: "执行流超过 idle timeout")
        }
        return nil
    }
    func complete() {
        guard !completed else { return }
        completed = true
        watchdog?.cancel()
        watchdog = nil
        lifecycle("watchdogCancelled", traceID: traceID, category: deadline.category)
        lifecycle("watchdogCompleted", traceID: traceID, category: deadline.category)
    }
}

enum ExecutionLifecycleTrace {
    static let enabled = ProcessInfo.processInfo.environment["LINGXI_EXECUTION_TRACE"] == "1"

    static func log(_ event: String, traceID: String? = nil, category: ExecutionTimeoutCategory, waitingOn: String = "watchdog-or-operation") {
        guard enabled else { return }
        let trace = traceID.map { " traceID=\($0)" } ?? ""
        FileHandle.standardError.write(Data("[execution-lifecycle] event=\(event)\(trace) kind=\(category.rawValue) waitingOn=\(waitingOn)\n".utf8))
    }
}

private func lifecycle(_ event: String, traceID: String, category: ExecutionTimeoutCategory) {
    ExecutionLifecycleTrace.log(event, traceID: traceID, category: category)
}

private extension CoreError {
    init(code: Code, message: String, category: String) {
        self.init(code: code, message: "\(message) category=\(category)")
    }
}
