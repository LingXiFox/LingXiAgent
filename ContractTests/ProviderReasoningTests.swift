import Darwin
import Foundation
import LingXiFrontendProtocol
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

/// Acceptance for the temporary thinking selection: the frontend may only pick a level the provider
/// declared, the Core reports it as a session override, clearing restores the plugin's own answer,
/// and the choice must reach the actual HTTP body instead of only repainting the UI.

// MARK: - tests

@Test("REASONING-001 the Core refuses an undeclared level and an unknown provider")
func REASONING_001_rejectsUndeclaredSelection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reasoning-refuse-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(directory, config: [
        "protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default",
    ])

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.ok)
    #expect(hello.models == ["mimo-v2.6-flash", "mimo-v2.6-pro"], "\(core.stderrText)")

    let undeclared = try #require(await core.waitReply(core.send(
        .providerReasoningSet, model: "mimo-v2.6-flash", provider: diagnosticsMiMoProviderID,
        reasoningLevel: "hyper"
    )))
    #expect(!undeclared.ok)
    #expect(undeclared.error?.contains("does not declare thinking level") == true, "\(undeclared.error ?? "")")
    #expect(undeclared.providerStates == nil)

    let unknownProvider = try #require(await core.waitReply(core.send(
        .providerReasoningSet, model: "mimo-v2.6-flash", provider: "provider.ghost",
        reasoningLevel: "enabled"
    )))
    #expect(!unknownProvider.ok)
    #expect(unknownProvider.error?.contains("no running provider") == true, "\(unknownProvider.error ?? "")")

    // A level without a model is ambiguous, not "the first model".
    let noModel = try #require(await core.waitReply(core.send(
        .providerReasoningSet, provider: diagnosticsMiMoProviderID, reasoningLevel: "enabled"
    )))
    #expect(!noModel.ok)
    #expect(noModel.error?.contains("needs a provider and a model") == true, "\(noModel.error ?? "")")
}

@Test("REASONING-002 a temporary level is reported as a session override, and clearing restores the plugin state")
func REASONING_002_reportsAndClearsOverride() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reasoning-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(directory, config: [
        "protocolKind": "responses", "model": "mimo-v2.6-flash",
        "thinkingMode": "enabled", "reasoningEffort": "medium",
    ])

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.ok)
    let pluginState = try #require(
        hello.providerStates?.first { $0.providerID == diagnosticsMiMoProviderID },
        "states=\(String(describing: hello.providerStates)) stderr=\(core.stderrText)"
    )
    #expect(pluginState.protocolKind == "responses", "plugin state: \(pluginState)")
    #expect(pluginState.thinkingLevel == "medium")
    #expect(pluginState.thinkingLabel == "medium")
    #expect(pluginState.thinkingAxisLabel == "effort")
    #expect(pluginState.source == "plugin-settings")
    #expect(pluginState.overridden != true)

    let set = try #require(await core.waitReply(core.send(
        .providerReasoningSet, model: "mimo-v2.6-flash", provider: diagnosticsMiMoProviderID,
        reasoningLevel: "none"
    )))
    #expect(set.ok, "\(set.error ?? "")")
    let overridden = try #require(set.providerStates?.first { $0.providerID == diagnosticsMiMoProviderID })
    #expect(overridden.thinkingLevel == "none")
    #expect(overridden.thinkingLabel == "none")
    #expect(overridden.thinkingAxisLabel == "effort")
    #expect(overridden.source == "session-override")
    #expect(overridden.overridden == true)
    // The protocol the plugin reports is unchanged by a thinking selection.
    #expect(overridden.protocolKind == "responses")

    let cleared = try #require(await core.waitReply(core.send(
        .providerReasoningSet, provider: diagnosticsMiMoProviderID, clearReasoning: true
    )))
    #expect(cleared.ok, "\(cleared.error ?? "")")
    let restored = try #require(cleared.providerStates?.first { $0.providerID == diagnosticsMiMoProviderID })
    #expect(restored.thinkingLevel == "medium")
    #expect(restored.source == "plugin-settings")
    #expect(restored.overridden != true)
}

@Test("REASONING-003 a temporary level reaches the Chat Completions body")
func REASONING_003_chatBodyFollowsSelection() async throws {
    let server = try TestLoopbackServer(responses: [
        sseResponse(chatSSE("enabled-reply")),
        sseResponse(chatSSE("disabled-reply")),
        sseResponse(chatSSE("default-reply")),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reasoning-chat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "default"],
        endpoint: server.url
    )

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    func run(_ level: String) async throws -> [String: Any] {
        let set = try #require(await core.waitReply(core.send(
            .providerReasoningSet, model: "mimo-v2.6-flash", provider: diagnosticsMiMoProviderID,
            reasoningLevel: level
        )))
        #expect(set.ok, "\(set.error ?? "")")
        let before = core.snapshot().count
        let sent = try #require(await core.waitReply(core.send(
            .chatSend, model: "mimo-v2.6-flash", text: "ping \(level)"
        )))
        #expect(sent.ok, "\(sent.error ?? "")")
        let terminal = try #require(await core.waitEvent("run.terminal", after: before))
        #expect(
            terminal.status == "completed",
            "status=\(terminal.status ?? "") cause=\(terminal.cause ?? "") detail=\(terminal.detail ?? "") stderr=\(core.stderrText)"
        )
        let index = ["enabled": 1, "disabled": 2, "default": 3][level]!
        return try jsonBody(try await waitForRequest(server, count: index))
    }

    let enabled = try await run("enabled")
    let thinking = try #require(enabled["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "enabled")

    let disabled = try await run("disabled")
    let disabledThinking = try #require(disabled["thinking"] as? [String: Any])
    #expect(disabledThinking["type"] as? String == "disabled")

    let defaultValue = try await run("default")
    #expect(defaultValue["thinking"] == nil)

    // The saved config still says "default"; only the temporary selection varies.
    #expect(enabled["model"] as? String == "mimo-v2.6-flash")
}

@Test("REASONING-004 a temporary level reaches the Responses reasoning.effort")
func REASONING_004_responsesBodyFollowsSelection() async throws {
    let server = try TestLoopbackServer(responses: [
        sseResponse(responsesSSE("disabled-reply")),
        sseResponse(responsesSSE("enabled-reply")),
        sseResponse(responsesSSE("default-reply")),
    ])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reasoning-responses-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: [
            "protocolKind": "responses", "model": "mimo-v2.6-flash",
            "thinkingMode": "enabled", "reasoningEffort": "medium",
        ],
        endpoint: server.url
    )

    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    func run(_ level: String, requestIndex: Int) async throws -> [String: Any] {
        let set = try #require(await core.waitReply(core.send(
            .providerReasoningSet, model: "mimo-v2.6-flash", provider: diagnosticsMiMoProviderID,
            reasoningLevel: level
        )))
        #expect(set.ok, "\(set.error ?? "")")
        let before = core.snapshot().count
        let sent = try #require(await core.waitReply(core.send(
            .chatSend, model: "mimo-v2.6-flash", text: "ping \(level)"
        )))
        #expect(sent.ok, "\(sent.error ?? "")")
        let terminal = try #require(await core.waitEvent("run.terminal", after: before))
        #expect(
            terminal.status == "completed",
            "status=\(terminal.status ?? "") cause=\(terminal.cause ?? "") detail=\(terminal.detail ?? "") stderr=\(core.stderrText)"
        )
        return try jsonBody(try await waitForRequest(server, count: requestIndex))
    }

    let disabled = try await run("none", requestIndex: 1)
    let disabledReasoning = try #require(disabled["reasoning"] as? [String: Any])
    #expect(disabledReasoning["effort"] as? String == "none")

    // The saved configuration still carries effort=medium; another temporary level replaces it.
    let enabled = try await run("high", requestIndex: 2)
    let enabledReasoning = try #require(enabled["reasoning"] as? [String: Any])
    #expect(enabledReasoning["effort"] as? String == "high")

    let defaultValue = try await run("default", requestIndex: 3)
    #expect(defaultValue["reasoning"] == nil)
}

@Test("REASONING-005 a level declared for another protocol is accepted by the Core and ignored safely by the plugin")
func REASONING_005_crossProtocolLevelIsSafe() async throws {
    let server = try TestLoopbackServer(responses: [
        sseResponse(chatSSE("one")),
        sseResponse(chatSSE("two")),
    ])
    let directory = try diagnosticsTempDirectory("reasoning-cross-protocol")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedDiagnosticsProvider(
        directory,
        config: ["protocolKind": "chatCompletions", "model": "mimo-v2.6-flash", "thinkingMode": "enabled"],
        endpoint: server.url
    )
    let core = try ProtocolCore(dataDirectory: directory, extraEnvironment: diagnosticsCredentialEnvironment())
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    // "xhigh" is declared for the model (Responses ladder) but the plugin speaks Chat right now.
    // The Core validates against the declaration, not a protocol it would have to guess.
    let set = try #require(await core.waitReply(core.send(
        .providerReasoningSet, model: "mimo-v2.6-flash", provider: diagnosticsMiMoProviderID,
        reasoningLevel: "xhigh"
    )))
    #expect(set.ok, "\(set.error ?? "")")

    let before = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: "cross protocol"
    )))
    #expect(await core.waitEvent("run.terminal", after: before) != nil)
    let first = try jsonBody(try await waitForRequest(server, count: 1))
    // Chat keeps the saved configuration: thinking.type=enabled. The unknown-for-this-protocol id
    // must not disable, enable twice, or crash the request.
    #expect((first["thinking"] as? [String: Any])?["type"] as? String == "enabled")

    _ = try #require(await core.waitReply(core.send(
        .providerReasoningSet, provider: diagnosticsMiMoProviderID, clearReasoning: true
    )))
    let after = core.snapshot().count
    _ = try #require(await core.waitReply(core.send(
        .chatSend, model: "mimo-v2.6-flash", text: "follow plugin"
    )))
    #expect(await core.waitEvent("run.terminal", after: after) != nil)
    let second = try jsonBody(try await waitForRequest(server, count: 2))
    #expect((second["thinking"] as? [String: Any])?["type"] as? String == "enabled")
}
