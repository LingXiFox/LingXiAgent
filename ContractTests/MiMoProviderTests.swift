import Darwin
import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let mimoID = "site.lingxi.provider.mimo"

private struct RecordedMiMoCassette: Decodable {
    let provider: String
    let exchanges: [Exchange]
    struct Exchange: Decodable { let events: [ProviderWireEvent] }
}
/// A real recording made against the live MiMo API on 2026-10-20 (sanitized: normalized events
/// only, no headers, credential stripped before hashing). Re-record with Scripts/mimo-record.sh.
private let mimoFixtureURL: URL = Bundle.module.url(
    forResource: "mimo-chat-live", withExtension: "json", subdirectory: "Fixtures"
)!

private final class MiMoEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelEvent] = []
    func append(_ event: ModelEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [ModelEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func reset() { lock.lock(); stored.removeAll(); lock.unlock() }
}

private struct MiMoTeeProvider: ModelProvider {
    let inner: any ModelProvider
    let recorder: MiMoEventRecorder
    var capabilities: ModelCapabilities { inner.capabilities }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let upstream = try await inner.stream(request)
        let recorder = self.recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        recorder.append(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func endExecution(_ executionID: ExecutionID) async { await inner.endExecution(executionID) }
}

private final class MiMoEchoExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []
    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        record(call)
        return ToolOutcome(callID: call.callID, content: "echo accepted \(call.argumentsJSON)", isError: false, effect: .readOnly)
    }

    private func record(_ call: ToolCall) {
        lock.lock(); calls.append(call); lock.unlock()
    }
    var executed: [ToolCall] { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct MiMoHarness {
    let loop: AgentLoop
    let coordinator: PluginCoordinator
    let recorder: MiMoEventRecorder
    let executor: MiMoEchoExecutor
    let router: ModelRouter?
}

private func makeMiMoHarness(
    grants: [String], model: String = "mimo-v2.6-flash",
    router ownedRouter: ModelRouter? = nil,
    credential: @escaping @Sendable () -> String?,
    toolExecutor: (any ToolExecutor)? = nil,
    settingsProvider: (any PluginSettingsProviding)? = nil
) async throws -> MiMoHarness {
    let bundle = try makeBundle(
        bundleID: mimoID,
        executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: nil)
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry,
        pipeline: HookPipeline(),
        router: ownedRouter,
        credential: { _, _ in credential() },
        settingsProvider: settingsProvider
    )
    try await coordinator.install(bundleID: mimoID, version: "1.0.0", bundlePath: bundle.url.path)
    _ = try await coordinator.enable(bundleID: mimoID, policy: .development, grantedPermissions: grants)
    let bindings = await coordinator.providerBindings(bundleID: mimoID)
    let binding = try #require(bindings.first)

    let recorder = MiMoEventRecorder()
    let router = ownedRouter ?? ModelRouter()
    if ownedRouter == nil {
        // Single-provider tests observe the stream through a wrapper; the coordinator owns routes
        // only when a router is supplied.
        try await router.register(
            provider: MiMoTeeProvider(inner: binding.adapter, recorder: recorder),
            id: ProviderID(binding.declaration.id),
            models: binding.declaration.models.map { ModelID($0) }
        )
    }
    let tools = ToolRegistry()
    try await tools.register(ToolDescriptor(
        id: "test/echo", name: "echo",
        schemaJSON: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}",
        effect: .readOnly
    ))
    let executor = MiMoEchoExecutor()
    let loop = AgentLoop(
        router: router, toolRegistry: tools, executor: toolExecutor ?? executor,
        log: try DurableEventLog(sink: InMemorySink()),
        runs: RunRegistry(), store: SessionStore(),
        instructions: "You are a test assistant."
    )
    return MiMoHarness(loop: loop, coordinator: coordinator, recorder: recorder, executor: executor, router: ownedRouter)
}

private func mimoRequest(turn: Int, prompt: String, model: String = "mimo-v2.6-flash") -> RunRequest {
    RunRequest(
        sessionID: "session-mimo",
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-mimo-\(turn)"),
        executionID: ExecutionID("exec-mimo-\(turn)"),
        model: ModelID(model),
        prompt: prompt
    )
}

@Test("MIMO a Chat Completions stream drives multi-turn text and a full tool loop offline")
func MIMO_cassetteDrivesMultiTurnAndToolLoop() async throws {
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)"], credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let first = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "Reply with the single word: pong"), policy: LoopPolicy()
    )
    #expect(first.status == .completed)
    #expect(first.assistantText.lowercased().contains("pong"))
    // Real streaming: the recording carries reasoning and text deltas, not one whole reply.
    let deltas = harness.recorder.events.filter {
        switch $0 {
        case .textDelta, .reasoningDelta: true
        default: false
        }
    }
    #expect(deltas.count >= 2)
    #expect(first.usage?.inputTokens == 89)
    #expect(first.usage?.reasoningTokens == 4)

    harness.recorder.reset()
    let second = await harness.loop.run(
        mimoRequest(turn: 2, prompt: "Call the echo tool with value 42, then say what it returned."),
        policy: LoopPolicy()
    )
    #expect(second.status == .completed)
    #expect(second.steps == 2)
    #expect(second.toolOutcomes == 1)
    #expect(second.assistantText.contains("42"))
    #expect(harness.executor.executed.map(\.toolName) == ["echo"])
    #expect(harness.executor.executed.first?.argumentsJSON == "{\"value\": \"42\"}")

    // Third turn replays the recorded follow-up, so history assembled from two prior turns must
    // reproduce the recorded request digest.
    harness.recorder.reset()
    let third = await harness.loop.run(
        mimoRequest(turn: 3, prompt: "In one sentence, what did the tool return?"), policy: LoopPolicy()
    )
    #expect(third.status == .completed)
    #expect(third.assistantText.contains("42"))
    #expect(third.usage?.cacheReadTokens == 128)
}

@Test("MIMO disabling the provider removes its model route and its host process")
func MIMO_disableRemovesProviderRoute() async throws {
    let router = ModelRouter()
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)"], router: router,
        credential: { "offline-test-credential" }
    )
    #expect(await harness.coordinator.isRunning(bundleID: mimoID))
    #expect(await router.offeredModels.map(\.rawValue).sorted() == ["mimo-v2.6-flash", "mimo-v2.6-pro"])
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: mimoID))

    try await harness.coordinator.disable(bundleID: mimoID)

    // Both halves of "disabled": the route is gone and so is the process.
    #expect(await router.offeredModels.isEmpty)
    #expect(await router.providerIDs().isEmpty)
    var refused = false
    do { _ = try await router.resolve(model: "mimo-v2.6-flash") } catch { refused = true }
    #expect(refused)
    #expect(await harness.coordinator.isRunning(bundleID: mimoID) == false)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("LOOP-023 a MiMo provider stream is cancelled at the deadline without leaving a host")
func MIMO_providerStreamCancellation() async throws {
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)", "fault.slow"], credential: { "offline-test-credential" }
    )
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: mimoID))
    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "Reply with the single word: pong"),
        policy: LoopPolicy(overallTimeout: .milliseconds(150))
    )
    #expect(result.status == .deadlineExceeded)
    #expect(await harness.coordinator.isRunning(bundleID: mimoID))
    try await harness.coordinator.disable(bundleID: mimoID)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("MIMO replay with recording enabled writes a real cassette file")
func MIMO_recordingWritesCassette() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-record-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)", "record=\(output.path)"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    #expect((await harness.loop.run(mimoRequest(turn: 1, prompt: "Reply with the single word: pong"), policy: LoopPolicy())).status == .completed)
    let data = try Data(contentsOf: output)
    #expect(!String(decoding: data, as: UTF8.self).contains("offline-test-credential"))
    let cassette = try JSONDecoder().decode(RecordedMiMoCassette.self, from: data)
    #expect(cassette.provider == "mimo")
    #expect(cassette.exchanges.count == 1)
    #expect(cassette.exchanges[0].events.contains { $0.type == "completed" })
}

@Test("MIMO live smoke and optional cassette recording", .enabled(
    if: ProcessInfo.processInfo.environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1"
))
func MIMO_liveSmoke() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["MIMO_API_KEY"])
    let model = ProcessInfo.processInfo.environment["LINGXI_MIMO_MODEL"] ?? "mimo-v2.6-flash"
    var grants: [String] = []
    if let record = ProcessInfo.processInfo.environment["LINGXI_RECORD_MIMO_CASSETTE"] {
        grants.append("record=\(record)")
    }
    // The same smoke body covers both wire families; the recorder script chooses via env.
    if ProcessInfo.processInfo.environment["LINGXI_MIMO_PROTOCOL"] == "responses" {
        var config: [String: Any] = [
            "protocolKind": "responses",
            "model": model,
            "thinkingMode": "enabled",
        ]
        config["reasoningEffort"] = ProcessInfo.processInfo.environment["LINGXI_MIMO_REASONING_EFFORT"] ?? "medium"
        grants.append(try mimoConfigGrant(config))
    }
    let harness = try await makeMiMoHarness(grants: grants, model: model, credential: { key })
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let first = await harness.loop.run(mimoRequest(turn: 1, prompt: "Reply with the single word: pong", model: model), policy: LoopPolicy())
    #expect(first.status == .completed, "live run failed: \(first.status) \(first.detail ?? "")")
    #expect(!first.assistantText.isEmpty)

    let tool = await harness.loop.run(
        mimoRequest(turn: 2, prompt: "Call the echo tool with value 42, then say what it returned.", model: model),
        policy: LoopPolicy()
    )
    #expect(tool.status == .completed, "live tool run failed: \(tool.status) \(tool.detail ?? "")")
    #expect(tool.toolOutcomes == 1, "the model did not complete the echo tool call: \(tool.assistantText)")

    let followUp = await harness.loop.run(
        mimoRequest(turn: 3, prompt: "In one sentence, what did the tool return?", model: model),
        policy: LoopPolicy()
    )
    #expect(followUp.status == .completed)
    #expect(!followUp.assistantText.isEmpty)
}

private final class InvocationGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String? = "first-invocation-sentinel"
    private var seen: [String?] = []
    func replace(_ value: String?) { lock.lock(); defer { lock.unlock() }; current = value }
    func grant() -> String? {
        lock.lock(); defer { lock.unlock() }; seen.append(current); return current
    }
    var history: [String?] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Test("AUTH-001 the real provider adapter asks the Core for a new grant on every request")
func AUTH_001_eachRequestUsesFreshGrant() async throws {
    let fixture = Bundle.module.url(forResource: "mimo-chat-tui", withExtension: "json", subdirectory: "Fixtures")!
    var cassette = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
    let first = try #require((cassette["exchanges"] as? [[String: Any]])?.first)
    cassette["exchanges"] = [first, first, first]
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: cassette).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let grants = InvocationGrants()
    let harness = try await makeMiMoHarness(grants: ["vcr=\(path.path)"], credential: { grants.grant() })
    for turn in 1...3 {
        if turn == 2 { grants.replace("updated-invocation-sentinel") }
        if turn == 3 { grants.replace(nil) }
        let result = await harness.loop.run(mimoRequest(turn: turn, prompt: "grant probe"), policy: LoopPolicy())
        #expect(result.status == .completed && result.cause == .completedWithText)
    }
    #expect(grants.history == ["first-invocation-sentinel", "updated-invocation-sentinel", nil])
    await harness.coordinator.shutdown()
}

// MARK: - MiMo settings / Responses wire tests

private let mimoResponsesFixtureURL: URL = Bundle.module.url(
    forResource: "mimo-responses-sse", withExtension: "json", subdirectory: "Fixtures"
)!
private let mimoResponsesCancelFixtureURL: URL = Bundle.module.url(
    forResource: "mimo-responses-cancel-sse", withExtension: "json", subdirectory: "Fixtures"
)!

private func mimoConfigGrant(_ config: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    return "config=" + data.base64EncodedString()
}

private func mimoSSEResponse(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\n"
        + "Content-Type: text/event-stream\r\n"
        + "Cache-Control: no-cache\r\n"
        + "Connection: close\r\n\r\n"
        + body
}

private func mimoSSE(_ blocks: [[String]]) -> String {
    blocks.map { $0.joined(separator: "\n") + "\n\n" }.joined()
}

private func mimoSSEEvent(_ name: String, _ object: [String: Any]) -> [String] {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return ["event: \(name)", "data: \(String(decoding: data, as: UTF8.self))"]
}

private struct MiMoCapturedRequest: Sendable {
    let path: String
    let body: String
}

/// Minimal loopback HTTP server for offline request-shape assertions. It is deliberately tiny and
/// only understands the shape URLSession sends for these tests (headers + Content-Length body).
private final class MiMoLoopbackServer: @unchecked Sendable {
    private let listenFD: Int32
    private let responses: [String]
    private let lock = NSLock()
    private var captured: [MiMoCapturedRequest] = []
    private var failure: String?
    let port: UInt16

    init(responses: [String]) throws {
        guard !responses.isEmpty else { throw NSError(domain: "MiMoLoopbackServer", code: 1) }
        self.responses = responses
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "MiMoLoopbackServer", code: 2) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw NSError(domain: "MiMoLoopbackServer", code: 3)
        }
        var local = sockaddr_in()
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &localLength)
            }
        }
        guard named == 0 else {
            close(fd)
            throw NSError(domain: "MiMoLoopbackServer", code: 4)
        }
        listenFD = fd
        port = UInt16(bigEndian: local.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func requests(count: Int) -> [MiMoCapturedRequest]? {
        lock.lock(); defer { lock.unlock() }
        return captured.count >= count ? captured : nil
    }

    var errorDescription: String? {
        lock.lock(); defer { lock.unlock() }; return failure
    }

    private func record(_ request: MiMoCapturedRequest) {
        lock.lock(); captured.append(request); lock.unlock()
    }

    private func fail(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
    }

    private func serve() {
        for response in responses {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                fail("accept failed: \(errno)")
                break
            }
            handle(client: client, response: response)
            close(client)
        }
        close(listenFD)
    }

    private func handle(client: Int32, response: String) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Int?
        var bodyLength = 0
        var path = ""

        while true {
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                if let requestLine = lines.first {
                    path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                }
                for line in lines where line.lowercased().hasPrefix("content-length:") {
                    let value = line.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) ?? "0"
                    bodyLength = Int(value) ?? 0
                }
            }
            if let start = headerEnd, data.count - start >= bodyLength {
                let body = String(decoding: data[start..<(start + bodyLength)], as: UTF8.self)
                record(MiMoCapturedRequest(path: path, body: body))
                write(response, to: client)
                return
            }
            let read = buffer.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress, raw.count, 0)
            }
            if read <= 0 {
                fail("client closed before a complete request (read=\(read))")
                return
            }
            data.append(contentsOf: buffer[0..<read])
        }
    }

    private func write(_ response: String, to client: Int32) {
        let bytes = Array(response.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in
                send(client, raw.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 { return }
            offset += sent
        }
    }
}

private func waitForMiMoRequests(
    _ server: MiMoLoopbackServer, count: Int
) async throws -> [MiMoCapturedRequest] {
    for _ in 0..<1000 {
        if let requests = server.requests(count: count) { return requests }
        if let error = server.errorDescription {
            throw NSError(domain: "MiMoLoopbackServer", code: 5, userInfo: [NSLocalizedDescriptionKey: error])
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "MiMoLoopbackServer", code: 6, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for requests"])
}

private func mimoJSON(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func mimoChatSSE(_ text: String, usage: Bool = true) -> String {
    var chunk: [String: Any] = [
        "id": "chatcmpl-test",
        "choices": [[
            "index": 0,
            "delta": ["content": text],
            "finish_reason": "stop",
        ]],
    ]
    if usage {
        chunk["usage"] = [
            "prompt_tokens": 3,
            "completion_tokens": 1,
            "completion_tokens_details": ["reasoning_tokens": 1],
            "prompt_tokens_details": ["cached_tokens": 2],
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys])
    return "data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n"
}

private func mimoResponsesTextSSE(_ text: String, usage: Bool = true) -> String {
    var blocks: [[String]] = [[
        "event: response.output_text.delta",
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"msg_test\",\"delta\":\"\(text)\"}",
    ]]
    var response: [String: Any] = ["id": "resp_test", "status": "completed"]
    if usage {
        response["usage"] = [
            "input_tokens": 2,
            "output_tokens": 1,
            "output_tokens_details": ["reasoning_tokens": 1],
            "input_tokens_details": ["cached_tokens": 4],
        ]
    }
    let completed: [String: Any] = [
        "type": "response.completed",
        "sequence_number": 2,
        "response": response,
    ]
    let data = try! JSONSerialization.data(withJSONObject: completed, options: [.sortedKeys])
    blocks.append(["event: response.completed", "data: \(String(decoding: data, as: UTF8.self))"])
    return mimoSSE(blocks)
}

struct MiMoEffortCase: Sendable {
    let mode: String
    let effort: String?
    let expected: String?
    let name: String
}

@Test("MIMO Chat Completions encodes the thinking object for default/enabled/disabled", arguments: [
    ("default", nil as String?),
    ("enabled", "enabled"),
    ("disabled", "disabled"),
])
func MIMO_chatThinkingBody(_ mode: String, _ expected: String?) async throws {
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(mimoChatSSE("ok"))])
    let options = try mimoConfigGrant([
        "protocolKind": "chatCompletions",
        "model": "mimo-v2.6-flash",
        "thinkingMode": mode,
    ])
    let harness = try await makeMiMoHarness(
        grants: [options, "test.endpoint=http://127.0.0.1:\(server.port)/v1/chat/completions"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "hello"), policy: LoopPolicy()
    )
    #expect(result.status == .completed)
    let requests = try await waitForMiMoRequests(server, count: 1)
    #expect(requests[0].path == "/v1/chat/completions")
    let body = try mimoJSON(requests[0].body)
    if let expected {
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == expected)
    } else {
        #expect(body["thinking"] == nil)
    }
    #expect(body["model"] as? String == "mimo-v2.6-flash")
    #expect(body["stream"] as? Bool == true)
    #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messages.last?["content"] as? String == "hello")
}

@Test("MIMO rejects reasoningEffort when the configured protocol is Chat Completions")
func MIMO_chatRejectsReasoningEffort() async throws {
    let options = try mimoConfigGrant([
        "protocolKind": "chatCompletions",
        "thinkingMode": "enabled",
        "reasoningEffort": "high",
    ])
    var rejected = false
    do {
        _ = try await makeMiMoHarness(
            grants: [options], credential: { "offline-test-credential" }
        )
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@Test("MIMO rejects an unknown reasoning effort instead of guessing")
func MIMO_rejectsUnknownReasoningEffort() async throws {
    let options = try mimoConfigGrant([
        "protocolKind": "responses",
        "thinkingMode": "enabled",
        "reasoningEffort": "turbo",
    ])
    var rejected = false
    do {
        _ = try await makeMiMoHarness(
            grants: [options], credential: { "offline-test-credential" }
        )
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@Test("MIMO Responses serializes and clamps reasoning effort", arguments: [
    MiMoEffortCase(mode: "enabled", effort: "none", expected: "none", name: "none"),
    MiMoEffortCase(mode: "enabled", effort: "minimal", expected: "low", name: "minimal-low"),
    MiMoEffortCase(mode: "enabled", effort: "low", expected: "low", name: "low"),
    MiMoEffortCase(mode: "enabled", effort: "medium", expected: "medium", name: "medium"),
    MiMoEffortCase(mode: "enabled", effort: "high", expected: "high", name: "high"),
    MiMoEffortCase(mode: "enabled", effort: "xhigh", expected: "high", name: "xhigh-high"),
    MiMoEffortCase(mode: "enabled", effort: "max", expected: "high", name: "max-high"),
    MiMoEffortCase(mode: "enabled", effort: "ultra", expected: "high", name: "ultra-high"),
    MiMoEffortCase(mode: "enabled", effort: nil, expected: nil, name: "enabled-default"),
    MiMoEffortCase(mode: "disabled", effort: "high", expected: "none", name: "disabled-none"),
    MiMoEffortCase(mode: "default", effort: nil, expected: nil, name: "default-omitted"),
])
func MIMO_responsesEffortBody(_ testCase: MiMoEffortCase) async throws {
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(mimoResponsesTextSSE("ok"))])
    var options: [String: Any] = [
        "protocolKind": "responses",
        "model": "mimo-v2.6-flash",
        "thinkingMode": testCase.mode,
    ]
    if let effort = testCase.effort { options["reasoningEffort"] = effort }
    let harness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant(options),
            "test.endpoint=http://127.0.0.1:\(server.port)/v1/responses",
        ],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "hello"), policy: LoopPolicy()
    )
    #expect(result.status == .completed)
    let requests = try await waitForMiMoRequests(server, count: 1)
    #expect(requests[0].path == "/v1/responses")
    let body = try mimoJSON(requests[0].body)
    if let expected = testCase.expected {
        let reasoning = try #require(body["reasoning"] as? [String: Any], "\(testCase.name)")
        #expect(reasoning["effort"] as? String == expected, "\(testCase.name)")
    } else {
        #expect(body["reasoning"] == nil, "\(testCase.name)")
    }
    #expect(body["previous_response_id"] == nil)
    #expect(body["background"] == nil)
    #expect(body["context_management"] == nil)
    #expect(body["model"] as? String == "mimo-v2.6-flash")
    #expect(body["stream"] as? Bool == true)
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.first?["type"] as? String == "message")
    #expect(input.first?["role"] as? String == "user")
}

@Test("MIMO Responses SSE normalizes text, reasoning, dedupes deltas and reports incomplete/error")
func MIMO_responsesSSENormalization() async throws {
    let harness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant(["protocolKind": "responses"]),
            "vcr=\(mimoResponsesFixtureURL.path)",
        ],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    // 1. Plain text + reasoning + completed usage; duplicate delta and done segments are deduped.
    let text = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "text"), policy: LoopPolicy()
    )
    #expect(text.status == .completed)
    #expect(text.assistantText == "Hello world")
    #expect(text.usage?.inputTokens == 12)
    #expect(text.usage?.outputTokens == 4)
    #expect(text.usage?.reasoningTokens == 2)
    #expect(text.usage?.cacheReadTokens == 3)
    let textDeltas = harness.recorder.events.compactMap { event -> String? in
        if case .textDelta(let value) = event { return value }
        return nil
    }
    let reasoningDeltas = harness.recorder.events.compactMap { event -> String? in
        if case .reasoningDelta(let value) = event { return value }
        return nil
    }
    #expect(textDeltas == ["Hello", " world"])
    #expect(reasoningDeltas == ["think ", "first"])
    #expect(harness.recorder.events.contains {
        if case .providerRequestID("resp_text") = $0 { return true } else { return false }
    })
    let textTerminals = harness.recorder.events.filter {
        if case .completed = $0 { return true } else { return false }
    }
    #expect(textTerminals.count == 1)

    // 2. Incomplete is a failure, not a completed response; usage survives.
    let incomplete = await harness.loop.run(
        mimoRequest(turn: 2, prompt: "incomplete"), policy: LoopPolicy()
    )
    #expect(incomplete.status == .failed)
    #expect(incomplete.cause == .providerFailure)
    #expect(incomplete.detail?.contains("incomplete") == true)
    #expect(incomplete.usage?.inputTokens == 5)

    // 3. Stream-level error.
    let error = await harness.loop.run(
        mimoRequest(turn: 3, prompt: "error"), policy: LoopPolicy()
    )
    #expect(error.status == .failed)
    #expect(error.cause == .providerFailure)
    #expect(error.detail?.contains("slow down") == true)

    // 4. response.failed carries the provider error through as a failure.
    let responseFailed = await harness.loop.run(
        mimoRequest(turn: 4, prompt: "response-failed"), policy: LoopPolicy()
    )
    #expect(responseFailed.status == .failed)
    #expect(responseFailed.cause == .providerFailure)
    #expect(responseFailed.detail?.contains("upstream exploded") == true)

    // 5. Tool call: started/delta/completed exactly once despite duplicate done markers.
    harness.recorder.reset()
    let tool = await harness.loop.run(
        mimoRequest(turn: 5, prompt: "tool"), policy: LoopPolicy()
    )
    #expect(tool.status == .completed)
    #expect(tool.steps == 2)
    #expect(tool.toolOutcomes == 1)
    #expect(tool.assistantText == "echo accepted 42")
    let started = harness.recorder.events.filter {
        if case .toolCallStarted = $0 { return true } else { return false }
    }
    let completedCalls = harness.recorder.events.filter {
        if case .toolCallCompleted = $0 { return true } else { return false }
    }
    let argumentDeltas = harness.recorder.events.filter {
        if case .toolCallDelta = $0 { return true } else { return false }
    }
    #expect(started.count == 1)
    #expect(argumentDeltas.count == 2)
    #expect(completedCalls.count == 1)
    #expect(harness.executor.executed.map(\.toolName) == ["echo"])
}

@Test("MIMO Responses encodes tool-call history on the follow-up request")
func MIMO_responsesToolHistoryEncoding() async throws {
    let toolSSE = mimoSSE([
        mimoSSEEvent("response.created", [
            "type": "response.created", "sequence_number": 0,
            "response": ["id": "resp_tool", "status": "in_progress"],
        ]),
        mimoSSEEvent("response.output_item.added", [
            "type": "response.output_item.added", "sequence_number": 1,
            "item": [
                "id": "item_1", "type": "function_call", "call_id": "call_1",
                "name": "echo", "arguments": "",
            ],
        ]),
        mimoSSEEvent("response.function_call_arguments.done", [
            "type": "response.function_call_arguments.done", "sequence_number": 2,
            "item_id": "item_1", "arguments": "{\"value\":\"42\"}",
        ]),
        mimoSSEEvent("response.completed", [
            "type": "response.completed", "sequence_number": 3,
            "response": ["id": "resp_tool", "status": "completed"],
        ]),
    ])
    let server = try MiMoLoopbackServer(responses: [
        mimoSSEResponse(toolSSE),
        mimoSSEResponse(mimoResponsesTextSSE("done")),
    ])
    let harness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant([
                "protocolKind": "responses",
                "model": "mimo-v2.6-flash",
                "thinkingMode": "enabled",
                "reasoningEffort": "low",
            ]),
            "test.endpoint=http://127.0.0.1:\(server.port)/v1/responses",
        ],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "call echo"), policy: LoopPolicy()
    )
    #expect(result.status == .completed)
    #expect(result.steps == 2)
    #expect(result.toolOutcomes == 1)
    let requests = try await waitForMiMoRequests(server, count: 2)
    let second = try mimoJSON(requests[1].body)
    let input = try #require(second["input"] as? [[String: Any]])
    let call = try #require(input.first { $0["type"] as? String == "function_call" })
    #expect(call["call_id"] as? String == "call_1")
    #expect(call["name"] as? String == "echo")
    #expect(call["arguments"] as? String == "{\"value\":\"42\"}")
    let output = try #require(input.first { $0["type"] as? String == "function_call_output" })
    #expect(output["call_id"] as? String == "call_1")
    #expect((output["output"] as? String)?.contains("echo accepted") == true)
    let tools = try #require(second["tools"] as? [[String: Any]])
    #expect(tools.first?["type"] as? String == "function")
    #expect(tools.first?["name"] as? String == "echo")
}

@Test("MIMO Responses cancellation drops late replay events")
func MIMO_responsesCancellationDropsLateEvents() async throws {
    let harness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant(["protocolKind": "responses"]),
            "vcr=\(mimoResponsesCancelFixtureURL.path)",
            "fault.slow",
        ],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "cancel"), policy: LoopPolicy(overallTimeout: .milliseconds(150))
    )
    #expect(result.status == .deadlineExceeded)
    let firstCount = harness.recorder.events.filter {
        if case .textDelta = $0 { return true } else { return false }
    }.count
    #expect(firstCount < 40)
    try await Task.sleep(for: .milliseconds(300))
    let laterCount = harness.recorder.events.filter {
        if case .textDelta = $0 { return true } else { return false }
    }.count
    #expect(laterCount == firstCount)
}

@Test("MIMO cassette digest separates protocol/thinking settings and ignores execution id")
func MIMO_digestSeparatesConfigurations() async throws {
    let cassettePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-digest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cassettePath) }

    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(mimoResponsesTextSSE("ok"))])
    var options: [String: Any] = [
        "protocolKind": "responses",
        "model": "mimo-v2.6-flash",
        "thinkingMode": "enabled",
        "reasoningEffort": "high",
    ]
    let recordHarness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant(options),
            "test.endpoint=http://127.0.0.1:\(server.port)/v1/responses",
            "record=\(cassettePath.path)",
        ],
        credential: { "offline-test-credential" }
    )
    let recorded = await recordHarness.loop.run(
        mimoRequest(turn: 1, prompt: "digest"), policy: LoopPolicy()
    )
    #expect(recorded.status == .completed)
    _ = try await waitForMiMoRequests(server, count: 1)
    try await recordHarness.coordinator.disable(bundleID: mimoID)

    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: cassettePath)) as? [String: Any]
    )
    let exchanges = try #require(root["exchanges"] as? [[String: Any]])
    let digest = try #require(exchanges.first?["requestDigest"] as? String)
    #expect(!digest.isEmpty)
    #expect(!digest.contains("offline-test-credential"))
    #expect(!digest.contains("exec-mimo-1"))

    // Same settings, different execution id and credential: replay must still match.
    let replayHarness = try await makeMiMoHarness(
        grants: [try mimoConfigGrant(options), "vcr=\(cassettePath.path)"],
        credential: { "a-different-credential" }
    )
    let replayed = await replayHarness.loop.run(
        mimoRequest(turn: 2, prompt: "digest"), policy: LoopPolicy()
    )
    #expect(replayed.status == .completed)
    #expect(replayed.assistantText == "ok")
    try await replayHarness.coordinator.disable(bundleID: mimoID)

    // Different thinking mode: the same cassette must not serve this request.
    options["thinkingMode"] = "disabled"
    let mismatchHarness = try await makeMiMoHarness(
        grants: [try mimoConfigGrant(options), "vcr=\(cassettePath.path)"],
        credential: { "offline-test-credential" }
    )
    let mismatch = await mismatchHarness.loop.run(
        mimoRequest(turn: 3, prompt: "digest"), policy: LoopPolicy()
    )
    #expect(mismatch.status == .failed)
    #expect(mismatch.detail?.contains("cassette has no exchange") == true)
    try await mismatchHarness.coordinator.disable(bundleID: mimoID)
}


private final class MiMoBlockingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
        }
        return ToolOutcome(
            callID: call.callID, content: "blocked-then-released",
            isError: false, effect: descriptor.effect
        )
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

@Test("MIMO snapshots config per execution across tool rounds, then applies new settings")
func MIMO_executionConfigSnapshot() async throws {
    let toolSSE = mimoSSE([
        mimoSSEEvent("response.created", [
            "type": "response.created", "sequence_number": 0,
            "response": ["id": "resp_snap_tool", "status": "in_progress"],
        ]),
        mimoSSEEvent("response.output_item.added", [
            "type": "response.output_item.added", "sequence_number": 1,
            "item": [
                "id": "item_snap", "type": "function_call", "call_id": "call_snap",
                "name": "echo", "arguments": "",
            ],
        ]),
        mimoSSEEvent("response.function_call_arguments.done", [
            "type": "response.function_call_arguments.done", "sequence_number": 2,
            "item_id": "item_snap", "arguments": "{\"value\":\"42\"}",
        ]),
        mimoSSEEvent("response.completed", [
            "type": "response.completed", "sequence_number": 3,
            "response": ["id": "resp_snap_tool", "status": "completed"],
        ]),
    ])
    let server = try MiMoLoopbackServer(responses: [
        mimoSSEResponse(toolSSE),
        mimoSSEResponse(mimoResponsesTextSSE("first run done")),
        mimoSSEResponse(mimoChatSSE("second run done")),
    ])
    let initial = try mimoConfigGrant([
        "protocolKind": "responses",
        "model": "mimo-v2.6-flash",
        "thinkingMode": "enabled",
        "reasoningEffort": "high",
    ])
    let executor = MiMoBlockingExecutor()
    let harness = try await makeMiMoHarness(
        grants: [
            initial,
            "test.endpoint=http://127.0.0.1:\(server.port)/v1/responses",
        ],
        credential: { "offline-test-credential" },
        toolExecutor: executor
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let runTask = Task {
        await harness.loop.run(mimoRequest(turn: 1, prompt: "snapshot"), policy: LoopPolicy())
    }
    await executor.waitUntilStarted()
    // The provider round with toolCalls has finished; the settings invocation is therefore free
    // to run while the tool itself is still blocked.
    let switched = try JSONValue.encode([
        "protocolKind": "chatCompletions",
        "model": "mimo-v2.6-flash",
        "thinkingMode": "enabled",
    ])
    try await harness.coordinator.applySettings(bundleID: mimoID, config: switched)
    executor.release()
    let first = await runTask.value
    #expect(first.status == .completed)
    #expect(first.steps == 2)

    let requests = try await waitForMiMoRequests(server, count: 2)
    let secondRound = try mimoJSON(requests[1].body)
    let reasoning = try #require(secondRound["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")

    // The next execution sees the newly applied Chat configuration.
    let next = await harness.loop.run(
        mimoRequest(turn: 2, prompt: "after settings"), policy: LoopPolicy()
    )
    #expect(next.status == .completed)
    let all = try await waitForMiMoRequests(server, count: 3)
    let nextBody = try mimoJSON(all[2].body)
    let thinking = try #require(nextBody["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "enabled")
}


private struct MiMoStaticSettings: PluginSettingsProviding {
    let config: JSONValue
    func settings(for bundleID: String) async -> PluginSettingsSnapshot? {
        PluginSettingsSnapshot(version: 1, config: config)
    }
}

@Test("MIMO committed settings are applied before the first run and after a save")
func MIMO_settingsDriveRealRequests() async throws {
    let first = mimoSSE([
        mimoSSEEvent("response.created", [
            "type": "response.created", "sequence_number": 0,
            "response": ["id": "resp_settings_1", "status": "in_progress"],
        ]),
        mimoSSEEvent("response.output_text.delta", [
            "type": "response.output_text.delta", "sequence_number": 1,
            "item_id": "item_1", "output_index": 0, "content_index": 0, "delta": "responses",
        ]),
        mimoSSEEvent("response.completed", [
            "type": "response.completed", "sequence_number": 2,
            "response": ["id": "resp_settings_1", "status": "completed", "usage": ["input_tokens": 3, "output_tokens": 1]],
        ]),
    ])
    let second = mimoSSE([
        ["data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"chat\"},\"finish_reason\":\"stop\"}]}"],
        ["data: [DONE]"],
    ])
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(first), mimoSSEResponse(second)])
    let settings = MiMoStaticSettings(config: .object([
        "protocolKind": .string("responses"),
        "model": .string("mimo-v2.6-flash"),
        "thinkingMode": .string("enabled"),
        "reasoningEffort": .string("medium"),
    ]))
    let harness = try await makeMiMoHarness(
        grants: ["test.endpoint=http://127.0.0.1:\(server.port)/v1/responses"],
        credential: { "test-credential" }, settingsProvider: settings
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }

    let firstRun = await harness.loop.run(mimoRequest(turn: 1, prompt: "settings apply probe"), policy: LoopPolicy())
    #expect(firstRun.status == .completed, "\(firstRun.detail ?? "")")
    _ = await waitUntil { server.requests(count: 1) != nil }
    let firstRequest = try #require(server.requests(count: 1)?.first)
    #expect(firstRequest.path == "/v1/responses")
    #expect(firstRequest.body.contains("\"reasoning\":{\"effort\":\"medium\"}"))

    try await harness.coordinator.applySettings(bundleID: mimoID, config: .object([
        "protocolKind": .string("chatCompletions"),
        "model": .string("mimo-v2.6-flash"),
        "thinkingMode": .string("disabled"),
    ]))
    let secondRun = await harness.loop.run(mimoRequest(turn: 2, prompt: "settings apply probe two"), policy: LoopPolicy())
    #expect(secondRun.status == .completed, "\(secondRun.detail ?? "")")
    _ = await waitUntil { server.requests(count: 2) != nil }
    let requests = try #require(server.requests(count: 2))
    #expect(requests[1].body.contains("\"thinking\":{\"type\":\"disabled\"}"))
}

@Test("MIMO keeps reasoning only for the live tool round and resends it as reasoning_content")
func MIMO_chatReasoningToolRoundTrip() async throws {
    let first = mimoSSE([
        ["data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"private reasoning\"}}]}"],
        ["data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_r\",\"function\":{\"name\":\"echo\",\"arguments\":\"{\\\"value\\\":\\\"42\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"],
        ["data: [DONE]"],
    ])
    let second = mimoSSE([
        ["data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}"],
        ["data: [DONE]"],
    ])
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(first), mimoSSEResponse(second)])
    let harness = try await makeMiMoHarness(
        grants: ["test.endpoint=http://127.0.0.1:\(server.port)/v1/chat/completions"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }
    let run = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "call the echo tool"), policy: LoopPolicy()
    )
    #expect(run.status == .completed, "\(run.detail ?? "")")
    #expect(run.toolOutcomes == 1)
    #expect(harness.recorder.events.contains { if case .reasoningDelta = $0 { true } else { false } })
    _ = await waitUntil { server.requests(count: 2) != nil }
    let requests = try #require(server.requests(count: 2))
    #expect(requests[1].body.contains("\"reasoning_content\":\"private reasoning\""), "body=\(requests[1].body)")
    // The reasoning is not in the assistant's visible text or in a user message.
    #expect(!run.assistantText.contains("private reasoning"))
}

private func mimoStatusResponse(_ status: Int, reason: String) -> String {
    "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
}

@Test("MIMO maps HTTP 401/429/500 and a terminal-less EOF to provider failures", arguments: [
    (401, "Unauthorized", "unauthorized"),
    (429, "Too Many Requests", "rateLimited"),
    (500, "Internal Server Error", "serverOverloaded"),
])
func MIMO_httpFailures(status: Int, reason: String, kind: String) async throws {
    let server = try MiMoLoopbackServer(responses: [mimoStatusResponse(status, reason: reason)])
    let harness = try await makeMiMoHarness(
        grants: ["test.endpoint=http://127.0.0.1:\(server.port)/v1/chat/completions"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }
    let run = await harness.loop.run(mimoRequest(turn: 1, prompt: "http failure"), policy: LoopPolicy())
    #expect(run.status == .failed)
    #expect(run.cause == .providerFailure)
    #expect(run.detail?.lowercased().contains("http \(status)") == true)
    #expect(run.detail?.lowercased().contains("http \(status)") == true)
}

@Test("MIMO EOF without a terminal event is a protocol failure, not a successful stop")
func MIMO_eofWithoutTerminal() async throws {
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(mimoSSE([
        ["data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}"],
    ]))])
    let harness = try await makeMiMoHarness(
        grants: ["test.endpoint=http://127.0.0.1:\(server.port)/v1/chat/completions"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }
    let run = await harness.loop.run(mimoRequest(turn: 1, prompt: "eof"), policy: LoopPolicy())
    #expect(run.status == .failed)
    #expect(run.cause == .providerFailure)
    #expect(run.detail?.contains("terminal") == true)
}

@Test("MIMO Responses tolerates duplicate and out-of-order events without duplicating output")
func MIMO_responsesDuplicateAndReorder() async throws {
    let sse = mimoSSE([
        mimoSSEEvent("response.created", [
            "type": "response.created", "sequence_number": 0,
            "response": ["id": "resp_dup", "status": "in_progress"],
        ]),
        mimoSSEEvent("response.output_text.delta", [
            "type": "response.output_text.delta", "sequence_number": 2,
            "item_id": "item_d", "output_index": 0, "content_index": 0, "delta": "hello",
        ]),
        // Duplicate sequence number must not repeat text.
        mimoSSEEvent("response.output_text.delta", [
            "type": "response.output_text.delta", "sequence_number": 2,
            "item_id": "item_d", "output_index": 0, "content_index": 0, "delta": "hello",
        ]),
        mimoSSEEvent("response.completed", [
            "type": "response.completed", "sequence_number": 4,
            "response": ["id": "resp_dup", "status": "completed", "usage": ["input_tokens": 2, "output_tokens": 1]],
        ]),
        // A terminal repeated after completion must be ignored.
        mimoSSEEvent("response.completed", [
            "type": "response.completed", "sequence_number": 5,
            "response": ["id": "resp_dup", "status": "completed", "usage": ["input_tokens": 2, "output_tokens": 1]],
        ]),
    ])
    let server = try MiMoLoopbackServer(responses: [mimoSSEResponse(sse)])
    let harness = try await makeMiMoHarness(
        grants: [
            try mimoConfigGrant([
                "protocolKind": "responses", "model": "mimo-v2.6-flash",
                "thinkingMode": "default",
            ]),
            "test.endpoint=http://127.0.0.1:\(server.port)/v1/responses",
        ],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: mimoID) } }
    let run = await harness.loop.run(mimoRequest(turn: 1, prompt: "dedupe"), policy: LoopPolicy())
    #expect(run.status == .completed, "\(run.detail ?? "")")
    #expect(run.assistantText == "hello")
}
