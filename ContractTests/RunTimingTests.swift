import Foundation
import LingXiFrontendProtocol
import Testing

/// Acceptance for the run diagnostics: one compact timing report per run, monotonic provider phases,
/// numbers only, and no measurable effect on the stream itself.

private func timingEvents(_ core: ProtocolCore, after start: Int) -> [FrontendEvent] {
    core.snapshot().dropFirst(start).compactMap { try? JSONDecoder().decode(FrontendEvent.self, from: $0) }
        .filter { $0.event == "timing" }
}

private func allEvents(_ core: ProtocolCore, after start: Int) -> [FrontendEvent] {
    core.snapshot().dropFirst(start).compactMap { try? JSONDecoder().decode(FrontendEvent.self, from: $0) }
}

private func timingJSONObjects(_ core: ProtocolCore, after start: Int) -> [[String: Any]] {
    core.snapshot().dropFirst(start).compactMap { line -> [String: Any]? in
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event"] as? String == "timing" else { return nil }
        return object
    }
}

@Test("TIMING-001 one timing report per run, delivered before the terminal, with Core preparation covered")
func TIMING_001_singleReportBeforeTerminal() async throws {
    let directory = try diagnosticsTempDirectory("timing-cassette")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cassette = try #require(
        Bundle.module.url(forResource: "mimo-chat-tui", withExtension: "json", subdirectory: "Fixtures")
    )
    try await seedDiagnosticsProvider(directory, cassette: cassette)

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let before = core.snapshot().count
    let sent = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: "timing probe"
    )))
    #expect(sent.ok, "\(sent.error ?? "")")
    let terminal = try #require(await core.waitEvent("run.terminal", after: before))
    #expect(terminal.status == "completed", "\(terminal.status ?? "") \(terminal.detail ?? "")")

    let events = allEvents(core, after: before)
    let timings = events.filter { $0.event == "timing" }
    #expect(timings.count == 1)
    let timing = try #require(timings.first?.timing)
    let corePrepare = try #require(timing.corePrepareMs)
    let runTotal = try #require(timing.runTotalMs)
    #expect(corePrepare >= 0)
    #expect(runTotal >= corePrepare)
    // A cassette replay has no HTTP phase, but the provider still owns the generation tail.
    if let providerTotal = timing.providerTotalMs {
        #expect(providerTotal >= 0)
        #expect(providerTotal <= runTotal)
    }
    // The report precedes the terminal so the frontend can render it as part of the final frame.
    let timingIndex = try #require(events.firstIndex { $0.event == "timing" })
    let terminalIndex = try #require(events.firstIndex { $0.event == "run.terminal" })
    #expect(timingIndex < terminalIndex)
}

@Test("TIMING-002 a live loopback run reports monotonic provider phases")
func TIMING_002_providerPhases() async throws {
    let server = try TestLoopbackServer(responses: [sseResponse(chatSSE("pong"))])
    let directory = try diagnosticsTempDirectory("timing-live")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default"],
        endpoint: server.url
    )

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let before = core.snapshot().count
    let sent = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: "phase probe"
    )))
    #expect(sent.ok, "\(sent.error ?? "")")
    let terminal = try #require(await core.waitEvent("run.terminal", after: before))
    #expect(terminal.status == "completed", "\(terminal.status ?? "") \(terminal.detail ?? "")")

    let timing = try #require(timingEvents(core, after: before).first?.timing)
    let prepare = try #require(timing.prepareMs)
    let send = try #require(timing.httpSendMs)
    let firstResponse = try #require(timing.firstResponseMs)
    let firstSSE = try #require(timing.firstSSEMs)
    let firstText = try #require(timing.firstTextMs)
    let providerTotal = try #require(timing.providerTotalMs)
    #expect(prepare >= 0)
    #expect(send >= prepare)
    #expect(firstResponse >= send)
    #expect(firstSSE >= firstResponse)
    #expect(firstText >= firstSSE)
    #expect(providerTotal >= firstText)
    #expect((timing.corePrepareMs ?? -1) >= 0)
    #expect((timing.runTotalMs ?? -1) >= providerTotal)
    // No reasoning was requested here, so the reasoning timestamp must stay absent, not zero.
    #expect(timing.firstReasoningMs == nil)
    // Run-level context: one provider call, one step, and every named kernel phase present.
    #expect(timing.providerCalls == 1)
    #expect(timing.steps == 1)
    #expect((timing.providerWaitMs ?? -1) + 5 >= providerTotal)
    #expect((timing.assemblyMs ?? -1) >= 0)
    #expect((timing.budgetMs ?? -1) >= 0)
    #expect((timing.logWriteMs ?? -1) >= 0)
    #expect((timing.terminalCommitMs ?? -1) >= 0)
    #expect((timing.providerCleanupMs ?? -1) >= 0)
    #expect((timing.loopTotalMs ?? -1) >= 0)
    #expect((timing.credentialMs ?? -1) >= 0)
    let runTotal = try #require(timing.runTotalMs)
    #expect((timing.unaccountedMs ?? 999) <= max(50, runTotal / 10), "unaccounted=\(timing.unaccountedMs ?? -1) total=\(runTotal)")
}

@Test("TIMING-003 the report is small, numeric, and carries no prompt or credential text")
func TIMING_003_payloadIsNumbersOnly() async throws {
    let server = try TestLoopbackServer(responses: [sseResponse(chatSSE("pong"))])
    let directory = try diagnosticsTempDirectory("timing-payload")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default"],
        endpoint: server.url
    )
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let prompt = "diagnostics-prompt-marker-\(UUID().uuidString)"
    let before = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: prompt
    )))
    _ = try #require(await core.waitEvent("run.terminal", after: before))

    let objects = timingJSONObjects(core, after: before)
    #expect(objects.count == 1)
    let object = try #require(objects.first)
    let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(encoded.count < 1024, "timing payload is \(encoded.count) bytes")
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains(prompt))
    #expect(!text.contains("offline-test-credential"))
    #expect(!text.contains("Bearer"))

    let timing = try #require(object["timing"] as? [String: Any])
    for (key, value) in timing {
        #expect(value is NSNumber, "timing field \(key) is not numeric: \(value)")
        #expect((value as? Int ?? -1) >= 0, "timing field \(key) is negative: \(value)")
    }
}

@Test("TIMING-004 timing is per request, not per delta, and the reply is unchanged")
func TIMING_004_notPerDelta() async throws {
    let directory = try diagnosticsTempDirectory("timing-count")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cassette = try #require(
        Bundle.module.url(forResource: "mimo-chat-tui", withExtension: "json", subdirectory: "Fixtures")
    )
    try await seedDiagnosticsProvider(directory, cassette: cassette)
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let before = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: "count probe"
    )))
    _ = try #require(await core.waitEvent("run.terminal", after: before))
    let events = allEvents(core, after: before)
    let deltas = events.filter { $0.event == "delta" || $0.event == "reasoning" }
    let timings = events.filter { $0.event == "timing" }
    #expect(deltas.count >= 2)
    #expect(timings.count == 1, "one report per request, not one per streamed event")
    #expect(core.collectDeltas(after: before).lowercased().contains("pong"))
}

@Test("PERF-001 kernel phases account for the whole run on a file-backed journal")
func PERF_001_kernelPhaseAccounting() async throws {
    let server = try TestLoopbackServer(responses: [sseResponse(chatSSE(String(repeating: "token ", count: 40)))])
    let directory = try diagnosticsTempDirectory("perf-accounting")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default"],
        endpoint: server.url
    )
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let before = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(.chatSend, model: "mimo-v2.6-flash", text: "timing")))
    let terminal = try #require(await core.waitEvent("run.terminal", after: before))
    #expect(terminal.status == "completed")
    let timing = try #require(timingEvents(core, after: before).first?.timing)
    let encoded = try JSONEncoder().encode(timing)
    print("PERF-001 TIMING", String(decoding: encoded, as: UTF8.self))
    let total = try #require(timing.runTotalMs)
    let known = [
        timing.corePrepareMs, timing.assemblyMs, timing.budgetMs, timing.contextHookMs,
        timing.requestHookMs, timing.providerWaitMs, timing.toolMs, timing.logWriteMs,
        timing.terminalCommitMs, timing.providerCleanupMs,
    ].reduce(0) { $0 + ($1 ?? 0) }
    let accounted = known + (timing.unaccountedMs ?? 0)
    print("PERF-001 total=\(total) known=\(known) credential=\(timing.credentialMs ?? -1) unaccounted=\(timing.unaccountedMs ?? -1) accounted=\(accounted)")
    #expect((timing.unaccountedMs ?? 0) >= 0)
    // Every millisecond must be accounted for by a named phase or the explicit remainder.
    #expect(abs(accounted - total) <= 5, "total=\(total) accounted=\(accounted)")
}

@Test("PERF-002 a long real stream keeps the Core's own overhead bounded")
func PERF_002_longStreamOverhead() async throws {
    let directory = try diagnosticsTempDirectory("perf-long")
    defer { try? FileManager.default.removeItem(at: directory) }
    // Generated here, not read from /tmp: a missing fixture must not turn this into a silent skip.
    let cassetteURL = directory.appendingPathComponent("long-stream.json")
    var events: [[String: Any]] = (0..<2000).map { _ in ["type": "textDelta", "text": "x"] }
    events.append(["type": "completed", "stopReason": "stop"])
    let cassette: [String: Any] = [
        "version": 1, "provider": "mimo",
        "exchanges": [["requestDigest": "", "events": events]],
    ]
    try JSONSerialization.data(withJSONObject: cassette, options: [.sortedKeys])
        .write(to: cassetteURL)
    try await seedDiagnosticsProvider(directory, cassette: cassetteURL)
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let before = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(.chatSend, model: "mimo-v2.6-flash", text: "long")))
    _ = try #require(await core.waitEvent("run.terminal", after: before))
    let timing = try #require(timingEvents(core, after: before).first?.timing)
    let total = try #require(timing.runTotalMs)
    let provider = try #require(timing.providerTotalMs)
    print("PERF-002 total=\(total) provider=\(provider) wait=\(timing.providerWaitMs ?? -1) log=\(timing.logWriteMs ?? -1) commit=\(timing.terminalCommitMs ?? -1) unaccounted=\(timing.unaccountedMs ?? -1) steps=\(timing.steps ?? -1)")
    // 2000 deltas: the Core may take longer than the replay itself, but the gap must stay bounded
    // and the kernel must not hide an unbounded wait of its own.
    #expect(timing.steps == 1)
    #expect(provider >= 0)
    #expect(total - provider < 1500, "total=\(total) provider=\(provider)")
}

@Test("PERF-004 a long session keeps context assembly and journal phases bounded")
func PERF_004_longSessionPhases() async throws {
    let turns = 60
    let server = try TestLoopbackServer(
        responses: Array(repeating: sseResponse(chatSSE("ok")), count: turns)
    )
    let directory = try diagnosticsTempDirectory("perf-history")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default"],
        endpoint: server.url
    )
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    var lastTiming: RunTiming?
    for turn in 1...turns {
        let before = core.snapshot().count
        _ = try #require(await core.waitReply(core.send(
            .chatSend, model: "mimo-v2.6-flash", text: "turn \(turn) " + String(repeating: "context ", count: 20)
        )))
        #expect(await core.waitEvent("run.terminal", after: before) != nil)
        lastTiming = timingEvents(core, after: before).first?.timing
    }
    let timing = try #require(lastTiming)
    print("PERF-004 total=\(timing.runTotalMs ?? -1) assembly=\(timing.assemblyMs ?? -1) budget=\(timing.budgetMs ?? -1) log=\(timing.logWriteMs ?? -1) wait=\(timing.providerWaitMs ?? -1) unaccounted=\(timing.unaccountedMs ?? -1)")
    // 60 turns of history must not turn preparation into a dominant cost.
    #expect((timing.assemblyMs ?? 0) < 100)
    #expect((timing.budgetMs ?? 0) < 100)
    #expect((timing.unaccountedMs ?? 0) < 100)
}
