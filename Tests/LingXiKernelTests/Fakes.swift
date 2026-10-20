import Foundation
import LingXiKernel

/// One-shot rendezvous so a test can act at an exact suspension point instead of sleeping.
/// Waiters are always resumed, by a signal or by their own deadline, so a missed signal fails
/// instead of hanging the suite.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var fired = false

    private func attach(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume(returning: true)
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func resumeAll(returning value: Bool) {
        lock.lock()
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: value) }
    }

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
        resumeAll(returning: true)
    }

    /// true when the signal arrived, false when the deadline passed first.
    func wait(within limit: Duration = .seconds(5)) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                attach(continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.resumeAll(returning: false)
                }
            }
        } onCancel: {
            resumeAll(returning: false)
        }
    }
}

final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let capabilities: ModelCapabilities
    private let lock = NSLock()
    private var scripts: [[ModelEvent]]
    private var recorded: [ModelRequest] = []
    private let preStreamError: (any Error)?

    /// Called on the run task before the stream is built, so a test can cancel deterministically.
    var onStream: ((Int) -> Void)?
    var arrivalGate: Gate?
    var proceedGate: Gate?

    init(
        scripts: [[ModelEvent]],
        capabilities: ModelCapabilities = ModelCapabilities(
            supportsReasoning: false,
            supportsParallelToolCalls: true,
            toolResultPlacement: .anywhereInHistory
        ),
        preStreamError: (any Error)? = nil
    ) {
        self.scripts = scripts
        self.capabilities = capabilities
        self.preStreamError = preStreamError
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    func request(at index: Int) -> ModelRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.indices.contains(index) ? recorded[index] : nil
    }

    private var ended: [ExecutionID] = []

    /// LOOP-026: every terminal path must release the provider's per-execution state.
    var endedExecutions: [ExecutionID] {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func endExecution(_ executionID: ExecutionID) async {
        appendEnded(executionID)
    }

    private func appendEnded(_ executionID: ExecutionID) {
        lock.lock()
        ended.append(executionID)
        lock.unlock()
    }

    private func takeScript(for request: ModelRequest) -> (index: Int, events: [ModelEvent]) {
        lock.lock()
        defer { lock.unlock() }
        let index = recorded.count
        recorded.append(request)
        // Consume from the front: the request index keeps growing while the script queue shrinks.
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        return (index, events)
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let (index, events) = takeScript(for: request)
        onStream?(index)
        arrivalGate?.fire()
        _ = await proceedGate?.wait(within: .seconds(10))

        if let preStreamError {
            throw preStreamError
        }

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []
    var onExecute: ((ToolCall) -> Void)?
    var throwsSideEffect = false

    private func record(_ call: ToolCall) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        record(call)
        onExecute?(call)

        if throwsSideEffect {
            struct Landed: Error {}
            throw Landed()
        }
        return ToolOutcome(
            callID: call.callID,
            content: "\(descriptor.name)<-\(call.callID.rawValue)",
            isError: false,
            effect: descriptor.effect
        )
    }

    var executed: [ToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class MemorySink: EventLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var failOnAppendCount: Int?
    var failOnTruncate = false

    init(lines: [String] = []) {
        self.lines = lines
    }

    func append(line: String) throws {
        lock.lock()
        let attempt = lines.count + 1
        lock.unlock()
        if let limit = failOnAppendCount, attempt >= limit {
            throw EventSinkFault.writeFailed
        }
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func truncate(toLineCount count: Int) throws {
        if failOnTruncate { throw EventSinkFault.truncateFailed }
        lock.lock()
        lines = Array(lines.prefix(count))
        lock.unlock()
    }

    func readLines() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }
}

enum EventSinkFault: Error {
    case writeFailed
    case truncateFailed
}

/// Injected monotonic clock. `sleep` registers a waiter and `advance` resumes every waiter whose
/// deadline has passed, so time-outs are deterministic instead of relying on real wall time
/// (QA-002).
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private final class Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Bool, Never>

        init(deadline: Duration, continuation: CheckedContinuation<Bool, Never>) {
            self.deadline = deadline
            self.continuation = continuation
        }
    }

    private final class SleepToken: @unchecked Sendable {
        var id: Int?
        var cancelled = false
    }

    /// Fires when a `sleep` waiter has been registered. Tests await this before advancing time so
    /// the watchdog's deadline is deterministic regardless of task scheduling order.
    let sleepStarted = Gate()

    private let lock = NSLock()
    private var elapsed = Duration.zero
    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0

    init(elapsed: Duration = .zero) {
        self.elapsed = elapsed
    }

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    func advance(_ amount: Duration) {
        lock.lock()
        elapsed += amount
        var due: [Waiter] = []
        for (id, waiter) in waiters where waiter.deadline <= elapsed {
            due.append(waiter)
            waiters[id] = nil
        }
        lock.unlock()
        for waiter in due { waiter.continuation.resume(returning: true) }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let token = SleepToken()
        let fired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if token.cancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                let deadline = elapsed + duration
                let id = nextID
                nextID += 1
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                token.id = id
                lock.unlock()
                sleepStarted.fire()
            }
        } onCancel: {
            let pending: CheckedContinuation<Bool, Never>? = {
                lock.lock()
                defer { lock.unlock() }
                if let id = token.id, let waiter = waiters.removeValue(forKey: id) {
                    token.id = nil
                    return waiter.continuation
                }
                token.cancelled = true
                return nil
            }()
            pending?.resume(returning: false)
        }
        if !fired { throw CancellationError() }
    }
}

func registerEchoTool(_ registry: ToolRegistry, name: String = "echo") async throws {
    try await registry.register(
        ToolDescriptor(id: "test/\(name)", name: name, schemaJSON: "{}", effect: .readOnly)
    )
}

func makeCall(_ id: String, tool: String = "echo", arguments: String = "{}") -> ToolCall {
    ToolCall(callID: ToolCallID(id), toolName: tool, argumentsJSON: arguments)
}

func completed(_ text: String) -> [ModelEvent] {
    [.started, .textDelta(text), .completed(.stop)]
}

func toolBatch(_ calls: [ToolCall]) -> [ModelEvent] {
    var events: [ModelEvent] = [.started]
    for call in calls {
        events.append(.toolCallStarted(ToolCallStart(callID: call.callID, toolName: call.toolName)))
        events.append(.toolCallCompleted(call))
    }
    events.append(.completed(.toolCalls))
    return events
}

func newRunID(_ tag: String) -> RunID { RunID(tag) }

/// A provider whose stream yields `.started` and then blocks until the test opens `release`. The
/// test can cancel/time the run while the stream is blocked, then release late terminal events to
/// prove they are discarded (LOOP-023).
final class BlockingStreamProvider: ModelProvider, @unchecked Sendable {
    let capabilities: ModelCapabilities
    let arrival = Gate()
    let release = Gate()

    private let terminalEvents: [ModelEvent]
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []

    init(
        terminalEvents: [ModelEvent],
        capabilities: ModelCapabilities = ModelCapabilities(
            supportsReasoning: false,
            supportsParallelToolCalls: true,
            toolResultPlacement: .anywhereInHistory
        )
    ) {
        self.terminalEvents = terminalEvents
        self.capabilities = capabilities
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    func request(at index: Int) -> ModelRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.indices.contains(index) ? recorded[index] : nil
    }

    private func record(_ request: ModelRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    private var ended: [ExecutionID] = []

    /// LOOP-026: every terminal path must release the provider's per-execution state.
    var endedExecutions: [ExecutionID] {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func endExecution(_ executionID: ExecutionID) async {
        markEnded(executionID)
    }

    private func markEnded(_ executionID: ExecutionID) {
        lock.lock()
        ended.append(executionID)
        lock.unlock()
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        record(request)
        arrival.fire()
        let release = self.release
        let terminalEvents = self.terminalEvents
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            Task {
                _ = await release.wait(within: .seconds(10))
                for event in terminalEvents { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

final class GatingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []
    let arrivalGate = Gate()
    let proceedGate = Gate()

    private func record(_ call: ToolCall) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        record(call)
        arrivalGate.fire()
        _ = await proceedGate.wait(within: .seconds(10))
        return ToolOutcome(callID: call.callID, content: "\(descriptor.name)<-\(call.callID.rawValue)", isError: false, effect: descriptor.effect)
    }

    var executedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }
}

func makeLoop(
    provider: any ModelProvider,
    executor: any ToolExecutor,
    registry: ToolRegistry = ToolRegistry(),
    log: DurableEventLog,
    runs: RunRegistry = RunRegistry(),
    store: SessionStore = SessionStore(),
    clock: any MonotonicClock = ManualClock()
) async -> AgentLoop {
    let router = ModelRouter()
    await router.register(provider: provider, id: "test.provider", models: ["test-model"])
    return AgentLoop(
        router: router,
        toolRegistry: registry,
        executor: executor,
        log: log,
        runs: runs,
        store: store,
        clock: clock,
        instructions: "instructions"
    )
}

func runRequest(_ tag: String) -> RunRequest {
    RunRequest(
        sessionID: SessionID("session-\(tag)"),
        turnID: TurnID(tag),
        runID: RunID("run-\(tag)"),
        executionID: ExecutionID("exec-\(tag)"),
        model: ModelID("test-model"),
        prompt: "prompt"
    )
}
