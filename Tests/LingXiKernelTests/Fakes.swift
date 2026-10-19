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
}

final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = Duration.zero

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
        lock.unlock()
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
    provider: ScriptedProvider,
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
