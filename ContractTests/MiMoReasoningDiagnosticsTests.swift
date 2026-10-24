import Darwin
import Foundation
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

/// Acceptance for the MiMo plugin's request diagnostics: the read-only provider state capability,
/// the temporary thinking selection (which must change the real HTTP body and the cassette digest
/// for that one request only), and the per-request timing report.
///
/// Everything runs against the real plugin host through `PluginSession` and a loopback HTTP server:
/// no cassette is hand-written and no request is faked inside the plugin.

private let diagnosticsProviderID = "site.lingxi.provider.mimo"
private let diagnosticsModel = "mimo-v2.6-flash"

// MARK: - real plugin session

private struct MiMoDiagnosticsHarness {
    let session: PluginSession
    let declaration: ProviderIdentity
}

private func openMiMoDiagnostics(_ grants: [String]) async throws -> MiMoDiagnosticsHarness {
    let bundle = try makeBundle(
        bundleID: diagnosticsProviderID, executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let session = PluginSession(
        bundlePath: bundle.url.path, hostExecutableURL: builtProduct("LingXiPluginHost")
    )
    try await session.enable(policy: .development, grantedPermissions: grants)
    let declaration = try #require(await session.providers.first)
    return MiMoDiagnosticsHarness(session: session, declaration: declaration)
}

private func configGrant(_ config: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    return "config=" + data.base64EncodedString()
}

private func diagnosticRequest(
    _ prompt: String, reasoningLevel: String? = nil,
    instructions: String = "You are a test assistant.",
    tools: [ProviderWireTool] = []
) -> ProviderWireRequest {
    ProviderWireRequest(
        model: diagnosticsModel,
        instructions: instructions,
        input: [ProviderWireItem(kind: .message, role: "user", text: prompt)],
        tools: tools,
        maxOutputTokens: nil,
        credential: "offline-test-credential",
        reasoningLevel: reasoningLevel
    )
}

private func streamWireEvents(
    _ harness: MiMoDiagnosticsHarness, request: ProviderWireRequest, allowFailure: Bool = false
) async throws -> [ProviderWireEvent] {
    let requestID = UUID().uuidString
    var events: [ProviderWireEvent] = []
    do {
        for try await value in await harness.session.invokeStreaming(
            capability: "provider.\(harness.declaration.id)",
            payload: try JSONValue.encode(request),
            requestID: requestID,
            timeout: .seconds(30)
        ) {
            events.append(try value.decode(ProviderWireEnvelope.self).event)
        }
    } catch {
        // A provider invoke streams events and returns no reply payload, so the host reports the
        // invoke as failed once the stream is over. What matters to the caller is what arrived
        // before the terminal: once that is present the request itself succeeded.
        let sawTerminal = events.contains { $0.type == "completed" || $0.type == "failed" }
        if !allowFailure && !sawTerminal { throw error }
    }
    return events
}

private func askProviderState(_ harness: MiMoDiagnosticsHarness) async throws -> ProviderState {
    let raw = try await harness.session.invoke(
        capability: "provider.state.v1", payload: .object([:]), requestID: UUID().uuidString
    )
    return try raw.decode(ProviderState.self)
}

// MARK: - loopback HTTP

private final class MiMoDiagnosticsLoopback: @unchecked Sendable {
    private let listenFD: Int32
    private let responses: [String]
    private let lock = NSLock()
    private var captured: [(path: String, body: String)] = []
    private var failure: String?
    let port: UInt16

    init(responses: [String]) throws {
        guard !responses.isEmpty else { throw NSError(domain: "MiMoDiagnosticsLoopback", code: 1) }
        self.responses = responses
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "MiMoDiagnosticsLoopback", code: 2) }
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
            throw NSError(domain: "MiMoDiagnosticsLoopback", code: 3)
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
            throw NSError(domain: "MiMoDiagnosticsLoopback", code: 4)
        }
        listenFD = fd
        port = UInt16(bigEndian: local.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func requests(count: Int) -> [(path: String, body: String)]? {
        lock.lock(); defer { lock.unlock() }
        return captured.count >= count ? captured : nil
    }

    var failureDescription: String? {
        lock.lock(); defer { lock.unlock() }; return failure
    }

    private func record(_ request: (path: String, body: String)) {
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
                record((path: path, body: body))
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

private func waitForDiagnosticRequests(
    _ server: MiMoDiagnosticsLoopback, count: Int
) async throws -> [(path: String, body: String)] {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let requests = server.requests(count: count) { return requests }
        if let failure = server.failureDescription {
            throw NSError(
                domain: "MiMoDiagnosticsLoopback", code: 5,
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(
        domain: "MiMoDiagnosticsLoopback", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(count) requests"]
    )
}

// MARK: - SSE + cassette helpers

private func diagnosticSSEResponse(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\n"
        + "Content-Type: text/event-stream\r\n"
        + "Cache-Control: no-cache\r\n"
        + "Connection: close\r\n\r\n"
        + body
}

private func diagnosticChatSSE(_ text: String) -> String {
    let chunk: [String: Any] = [
        "id": "chatcmpl-diagnostics",
        "choices": [[
            "index": 0,
            "delta": ["content": text],
            "finish_reason": "stop",
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys])
    return "data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n"
}

private func diagnosticResponsesSSE(_ text: String) -> String {
    func block(_ name: String, _ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    return block("response.output_text.delta", [
        "type": "response.output_text.delta", "sequence_number": 1,
        "item_id": "msg_diagnostics", "output_index": 0, "content_index": 0, "delta": text,
    ]) + block("response.completed", [
        "type": "response.completed", "sequence_number": 2,
        "response": ["id": "resp_diagnostics", "status": "completed"],
    ])
}

private func diagnosticStatusResponse(_ status: Int, reason: String) -> String {
    "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
}

private struct DiagnosticsCassette: Decodable {
    struct Exchange: Decodable {
        let requestDigest: String
        let events: [ProviderWireEvent]?
    }
    let exchanges: [Exchange]
}

private func decodeDiagnosticsCassette(_ url: URL) throws -> DiagnosticsCassette {
    try JSONDecoder().decode(DiagnosticsCassette.self, from: Data(contentsOf: url))
}

private func diagnosticsCassettePath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-diagnostics-\(UUID().uuidString).json")
}

private func jsonObject(_ body: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

private func orderedTimings(_ timing: ProviderTiming) -> [Int?] {
    [
        timing.prepareMs, timing.sendMs, timing.firstResponseMs, timing.firstSSEMs,
        timing.firstReasoningMs, timing.firstTextMs, timing.terminalMs, timing.totalMs,
    ]
}

// MARK: - provider state

@Test("MIMO-DIAG-001 provider.state.v1 is declared and answers with plugin-owned labels, never secrets")
func mimoProviderStateCapability() async throws {
    let harness = try await openMiMoDiagnostics([
        try configGrant([
            "protocolKind": "responses", "model": diagnosticsModel,
            "thinkingMode": "enabled", "reasoningEffort": "medium",
        ])
    ])
    defer { Task { await harness.session.disable() } }
    #expect(harness.declaration.state?.capability == "provider.state.v1")

    let state = try await askProviderState(harness)
    #expect(state.protocolKind == "responses")
    #expect(state.protocolLabel == "Responses")
    #expect(state.thinkingLevel == "enabled")
    #expect(state.thinkingLabel == "开启思考")
    #expect(state.source == "plugin-settings")
    #expect(state.detail == "effort=medium")
    let encoded = try JSONEncoder().encode(state)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("offline-test-credential"))
    #expect(!text.contains("Authorization"))
    #expect(!text.contains("You are a test assistant"))

    // The default mode is reported as the server's choice, not as a plugin setting.
    let defaultHarness = try await openMiMoDiagnostics([
        try configGrant([
            "protocolKind": "chatCompletions", "model": diagnosticsModel, "thinkingMode": "default",
        ])
    ])
    defer { Task { await defaultHarness.session.disable() } }
    let defaultState = try await askProviderState(defaultHarness)
    #expect(defaultState.protocolKind == "chatCompletions")
    #expect(defaultState.protocolLabel == "Chat Completions")
    #expect(defaultState.thinkingLevel == "default")
    #expect(defaultState.source == "server-default")
}

// MARK: - temporary thinking level

@Test("MIMO-DIAG-002 a temporary level changes the Chat Completions body and the cassette digest")
func mimoChatReasoningOverrideBodyAndDigest() async throws {
    let server = try MiMoDiagnosticsLoopback(
        responses: Array(repeating: diagnosticSSEResponse(diagnosticChatSSE("ok")), count: 4)
    )
    let cassette = diagnosticsCassettePath()
    defer { try? FileManager.default.removeItem(at: cassette) }
    let harness = try await openMiMoDiagnostics([
        try configGrant([
            "protocolKind": "chatCompletions", "model": diagnosticsModel, "thinkingMode": "default",
        ]),
        "test.endpoint=\(server.baseURL)/v1/chat/completions",
        "record=\(cassette.path)",
    ])
    defer { Task { await harness.session.disable() } }

    // Same prompt and model; only the temporary level differs. The unknown id is the fail-safe case.
    let requests = [
        diagnosticRequest("same prompt"),
        diagnosticRequest("same prompt", reasoningLevel: "enabled"),
        diagnosticRequest("same prompt", reasoningLevel: "disabled"),
        diagnosticRequest("same prompt", reasoningLevel: "not-a-level"),
    ]
    for request in requests {
        let events = try await streamWireEvents(harness, request: request)
        #expect(events.contains { $0.type == "completed" })
    }

    let captured = try await waitForDiagnosticRequests(server, count: 4)
    let bodies = try captured.map { try jsonObject($0.body) }
    #expect(bodies[0]["thinking"] == nil)
    #expect((bodies[1]["thinking"] as? [String: Any])?["type"] as? String == "enabled")
    #expect((bodies[2]["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    // Unknown level: the saved configuration wins and the outgoing bytes are identical.
    #expect(captured[3].body == captured[0].body)
    #expect(bodies[3]["model"] as? String == diagnosticsModel)

    let recorded = try decodeDiagnosticsCassette(cassette)
    #expect(recorded.exchanges.count == 4)
    let digests = recorded.exchanges.map(\.requestDigest)
    #expect(digests[0] == digests[3], "an unknown level must not change the digest")
    #expect(digests[1] != digests[2], "enabled and disabled must not share a cassette key")
    #expect(digests[0] != digests[1])
    #expect(digests[0] != digests[2])
    for exchange in recorded.exchanges {
        #expect(exchange.events?.allSatisfy { $0.type != "timing" } == true)
        #expect(exchange.events?.last?.type == "completed")
    }
}

@Test("MIMO-DIAG-003 a temporary level changes Responses reasoning.effort and the digest")
func mimoResponsesReasoningOverrideBodyAndDigest() async throws {
    let server = try MiMoDiagnosticsLoopback(
        responses: Array(repeating: diagnosticSSEResponse(diagnosticResponsesSSE("ok")), count: 4)
    )
    let cassette = diagnosticsCassettePath()
    defer { try? FileManager.default.removeItem(at: cassette) }
    let harness = try await openMiMoDiagnostics([
        try configGrant([
            "protocolKind": "responses", "model": diagnosticsModel,
            "thinkingMode": "enabled", "reasoningEffort": "medium",
        ]),
        "test.endpoint=\(server.baseURL)/v1/responses",
        "record=\(cassette.path)",
    ])
    defer { Task { await harness.session.disable() } }

    let requests = [
        diagnosticRequest("same prompt"),
        diagnosticRequest("same prompt", reasoningLevel: "enabled"),
        diagnosticRequest("same prompt", reasoningLevel: "disabled"),
        diagnosticRequest("same prompt", reasoningLevel: "default"),
    ]
    for request in requests {
        let events = try await streamWireEvents(harness, request: request)
        #expect(events.contains { $0.type == "completed" })
    }

    let captured = try await waitForDiagnosticRequests(server, count: 4)
    let bodies = try captured.map { try jsonObject($0.body) }
    #expect((bodies[0]["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
    // The saved effort still applies when the temporary level keeps thinking enabled.
    #expect((bodies[1]["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
    #expect((bodies[2]["reasoning"] as? [String: Any])?["effort"] as? String == "none")
    #expect(bodies[3]["reasoning"] == nil)

    let recorded = try decodeDiagnosticsCassette(cassette)
    let digests = recorded.exchanges.map(\.requestDigest)
    #expect(digests[0] == digests[1], "an enabled override must describe the same effective config")
    #expect(digests[0] != digests[2])
    #expect(digests[0] != digests[3])
    #expect(recorded.exchanges.allSatisfy { ($0.events ?? []).allSatisfy { $0.type != "timing" } })
}

// MARK: - timing

@Test("MIMO-DIAG-004 each request emits one bounded, monotonic timing event right before its terminal")
func mimoTimingEvent() async throws {
    let server = try MiMoDiagnosticsLoopback(responses: [
        diagnosticSSEResponse(diagnosticChatSSE("ok")),
        diagnosticSSEResponse(diagnosticChatSSE("ok")),
    ])
    let cassette = diagnosticsCassettePath()
    defer { try? FileManager.default.removeItem(at: cassette) }
    let harness = try await openMiMoDiagnostics([
        try configGrant([
            "protocolKind": "chatCompletions", "model": diagnosticsModel, "thinkingMode": "default",
        ]),
        "test.endpoint=\(server.baseURL)/v1/chat/completions",
        "record=\(cassette.path)",
    ])
    defer { Task { await harness.session.disable() } }

    for prompt in ["timing one", "timing two"] {
        let events = try await streamWireEvents(harness, request: diagnosticRequest(prompt))
        let timingIndexes = events.indices.filter { events[$0].type == "timing" }
        #expect(timingIndexes.count == 1, "one report per request")
        let terminalIndex = try #require(events.firstIndex {
            $0.type == "completed" || $0.type == "failed"
        })
        #expect(timingIndexes.first == terminalIndex - 1, "the report must directly precede the terminal")
        let timing = try #require(events[timingIndexes[0]].timing)
        let ordered = orderedTimings(timing).compactMap { $0 }
        // Seven phases on a live text-only request: reasoning never started, so it stays absent.
        #expect(ordered.count == 7, "a live request reports every reached phase: \(timing)")
        #expect(ordered.allSatisfy { $0 >= 0 })
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0 <= $1 }, "phases: \(ordered)")
        // No reasoning was requested, so that timestamp stays absent rather than zero.
        #expect(timing.firstReasoningMs == nil)
        let encoded = try JSONEncoder().encode(events[timingIndexes[0]])
        #expect(encoded.count < 1024, "timing payload is \(encoded.count) bytes")
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(prompt))
        #expect(!text.contains("offline-test-credential"))
        #expect(!text.contains("Bearer"))
    }

    let recorded = try decodeDiagnosticsCassette(cassette)
    #expect(recorded.exchanges.count == 2)
    for exchange in recorded.exchanges {
        #expect(exchange.events?.allSatisfy { $0.type != "timing" } == true)
        #expect(exchange.events?.contains { $0.type == "completed" } == true)
    }
}

@Test("MIMO-DIAG-005 a failed request still gets exactly one timing event before the failure")
func mimoTimingOnFailure() async throws {
    let server = try MiMoDiagnosticsLoopback(responses: [
        diagnosticStatusResponse(401, reason: "Unauthorized"),
    ])
    let harness = try await openMiMoDiagnostics([
        "test.endpoint=\(server.baseURL)/v1/chat/completions"
    ])
    defer { Task { await harness.session.disable() } }

    let events = try await streamWireEvents(
        harness, request: diagnosticRequest("fail"), allowFailure: true
    )
    #expect(events.map(\.type) == ["timing", "failed"])
    let timing = try #require(events.first?.timing)
    #expect(timing.prepareMs != nil)
    #expect(timing.sendMs != nil)
    #expect(timing.firstResponseMs != nil)
    #expect(timing.firstSSEMs == nil)
    #expect(timing.firstTextMs == nil)
    #expect(timing.terminalMs != nil)
    #expect(timing.totalMs != nil)
    #expect(events.last?.failureKind == "unauthorized")
}

@Test("MIMO-DIAG-006 a cassette replay reports a total-only timing and old recordings replay unchanged")
func mimoReplayTimingAndLegacyCassette() async throws {
    let fixture = try #require(
        Bundle.module.url(forResource: "mimo-chat-live", withExtension: "json", subdirectory: "Fixtures")
    )
    let harness = try await openMiMoDiagnostics(["vcr=\(fixture.path)"])
    defer { Task { await harness.session.disable() } }

    // This is the exact first request the recorded run made; the shipped cassette predates both the
    // settings digest and the timing event, so replaying it proves neither changed the old key.
    let request = diagnosticRequest(
        "Reply with the single word: pong",
        tools: [ProviderWireTool(
            name: "echo", description: nil,
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}"
        )]
    )
    let events = try await streamWireEvents(harness, request: request)
    #expect(events.contains { $0.type == "completed" })
    #expect(events.contains { $0.type == "textDelta" })
    let timingIndexes = events.indices.filter { events[$0].type == "timing" }
    #expect(timingIndexes.count == 1)
    let terminalIndex = try #require(events.firstIndex { $0.type == "completed" })
    #expect(timingIndexes.first == terminalIndex - 1)
    let timing = try #require(events[timingIndexes[0]].timing)
    // A replay has no HTTP phases: only the generation tail is observable offline.
    #expect(timing.totalMs != nil)
    #expect(timing.prepareMs == nil)
    #expect(timing.sendMs == nil)
    #expect(timing.firstResponseMs == nil)
    #expect(timing.firstSSEMs == nil)
    #expect(timing.terminalMs == nil)
}
