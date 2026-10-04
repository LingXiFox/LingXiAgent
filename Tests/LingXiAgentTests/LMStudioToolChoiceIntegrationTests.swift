import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Opt-in real HTTP/SSE integration; no fake transport and no file tool execution.
/// LINGXI_LMSTUDIO_BASE_URL=http://host:port/v1 LINGXI_LMSTUDIO_MODEL=loaded-instance swift test --filter LMStudioToolChoiceIntegrationTests
@Suite("Live LM Studio tool choice", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LINGXI_LMSTUDIO_BASE_URL"] != nil))
struct LMStudioToolChoiceIntegrationTests {
    @Test func nativeModelReadsFailureAfterPersistentPERecallAdmission() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"].flatMap(URL.init(string:)))
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"])
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: baseURL,
            apiKey: nil, model: model, wireProtocol: .responses))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: provider, modelID: ModelID(model),
                contextProfile: .init(contextWindowTokens: 65536)),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        let sid = try await host.sessionStore.create().id
        let fixture = PEContextIntegrityTests()
        let failure = try fixture.failedResult()
        let call = ToolCall(callID: failure.callID, toolID: ToolID("shell"), arguments: "{}")
        let a = try await host.sessionStore.appendMessage(sid, role: .assistant, parts: [.toolCall(call)])
        let r = try await host.sessionStore.appendMessage(sid, role: .tool, parts: [.toolResult(failure)])
        let batch = ToolExchangeBatch(batchID: "native-T011", sessionID: sid,
            assistantMessageID: a.id, resultMessageID: r.id, toolCalls: [call],
            toolResults: [failure], providerStep: 1, state: .consumed, estimatedTokens: 4000)
        let engine = PCoreContextEngine()
        let before = try await host.sessionStore.session(sid)
        let canonical = await engine.entries(for: before)
        _ = try await host.compactor.compact(sessionID: sid, entries: canonical,
            budget: fixture.budget, batches: [batch], trigger: .manual)
        let fabric = await host.ecoreStoreRef
        let ref = try #require(await fabric.references(sessionID: sid).first)
        let resident = await host.compactor.activeEntries(sessionID: sid, canonicalEntries: canonical)
        #expect(!resident.contains { $0.messageID == r.id })
        let indexed = await host.compactor.projectIndex(sessionID: sid, entries: resident,
            hardInputLimit: 65536, query: "test failure NameError")
        #expect(indexed.contains { $0.segment == .eCoreRetrievalProjection && ContextCompactor.content(of: $0.part).contains(ref.referenceID) })
        let recall = ContextRecallTool(ecoreStore: fabric, sessionID: sid)
        _ = try await recall.execute(arguments: "{\"id\":\"\(ref.referenceID)\"}", profile: .workspace)
        let admitted = await host.compactor.admitRequestedRecalls(sessionID: sid,
            canonicalEntries: canonical, activeEntries: indexed, hardInputLimit: 65536)
        #expect(admitted.contains { $0.messageID == r.id && $0.segment == .recalledOccurrence })
        _ = try await host.sessionStore.appendMessage(sid, role: .user,
            content: "Read the restored historical failure. Return only a JSON object with exception containing the exact NameError signature and exitCode containing the original numeric exit code. Do not execute tools.")
        let after = try await host.sessionStore.session(sid)
        let cacheProjection = try #require(try await LingXiClient.inProcess(endpoint: host).contextProjection(sid))
        #expect(cacheProjection.pCore.usedTokens < 65536)
        let tail = await engine.entries(for: after).filter { $0.messageID == after.messages.last?.id }
        let messages = await engine.snapshot(for: after, activeEntries: admitted + tail).modelMessages()
        let request = ModelRequest(model: ModelID(model), messages: messages,
            reasoning: "off", overallTimeoutSeconds: 60, idleTimeoutSeconds: 30)
        let body = try OpenAIResponsesProvider.makeRequestBody(request)
        #expect(String(decoding: body, as: UTF8.self).contains("NameError: name 'select' is not defined"))
        try fixture.evidence("native-recall-provider-request.json", data: body)
        var text = ""
        var terminal: ModelFinishReason?
        for try await event in try await provider.stream(request) {
            if case let .textDelta(delta) = event { text += delta }
            if case let .failed(error) = event { throw error }
            if case let .completed(reason) = event { terminal = reason }
        }
        #expect(terminal == .stop)
        let answer = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((answer["exception"] as? String)?.contains("NameError: name 'select' is not defined") == true)
        #expect(answer["exitCode"] as? Int == failure.exitCode)
        #expect(try await host.sessionStore.session(sid).messages.contains { $0.id == r.id && $0.parts.contains(.toolResult(failure)) })
        let lifecycle = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(lifecycle.recallResolved == 1 && lifecycle.recallAdmitted == 1 && lifecycle.recallRejected == 0)
        try fixture.evidence("native-recall-answer.json", data: Data(text.utf8))
        print("LIVE_P_E_RECALL_ACTIVE ref=\(ref.referenceID) phases=\(lifecycle.events.map { $0.phase.rawValue }) answer=\(text)")
    }

    @Test func responsesAcceptsPEContextDataAndRetainsFailureEvidence() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"].flatMap(URL.init(string:)))
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"])
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: baseURL, apiKey: nil,
            model: model, wireProtocol: .responses))
        let system = "Environment facts:\nworkspace: /tmp/isolated-native-probe\n\nRead the supplied context data accurately. Do not use tools."
        let engine = PCoreContextEngine()
        let session = Session(id: SessionID("isolated-native-probe"), createdAt: .now, messages: [
            Message(id: MessageID("probe"), role: .user,
                content: "Return the exact exception signature and exact recall reference from the following context data.", createdAt: .now)])
        var entries = await engine.entries(for: session, systemContext: system, systemContextAtBeginning: false)
        entries.append(.init(messageID: MessageID("project-data"), role: .system, source: .projectPage,
            part: .text("[Project context] Independent native compatibility probe.")))
        entries.append(.init(messageID: MessageID("restored"), role: .system, source: .derivedPage,
            part: .text("[Restored session context]\nNameError: name 'retained_symbol_731' is not defined"), segment: .recalledOccurrence))
        entries.append(.init(messageID: ContextCompactor.eCoreIndexMessageID, role: .system, source: .derivedPage,
            part: .text("[E-Core index]\nreference=ref_native_evidence_731"), segment: .eCoreRetrievalProjection))
        let messages = await engine.snapshot(for: session, activeEntries: entries, systemContext: system).modelMessages()
        let plan = CanonicalCachePlan(epochIdentity: .init(epoch: 1), immutableBase: .init(systemPrompt: system),
            appendOnlyContext: .init(messages: messages), structuralHealth: .init(stablePrefixHash: "fixed"))
        let request = ModelRequest(model: ModelID(model), messages: messages, reasoning: "off",
            overallTimeoutSeconds: 60, idleTimeoutSeconds: 30, cachePlan: plan)
        var text = ""
        var terminal: ModelFinishReason?
        for try await event in try await provider.stream(request) {
            if case let .textDelta(delta) = event { text += delta }
            if case let .failed(error) = event { throw error }
            if case let .completed(reason) = event { terminal = reason }
        }
        #expect(terminal == .stop)
        #expect(text.contains("NameError: name 'retained_symbol_731' is not defined"))
        #expect(text.contains("ref_native_evidence_731"))
        print("LIVE_RESPONSES_PE_CONTEXT \(text)")
    }

    @Test func responsesReportsRealCacheReuse() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"].flatMap(URL.init(string:)))
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"])
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: baseURL, apiKey: nil,
            model: model, wireProtocol: .responses))
        let reference = (0..<96).map { "Reference \($0): amber cedar river cloud stone meadow." }.joined(separator: "\n")
        let request = ModelRequest(model: ModelID(model), messages: [ModelMessage(role: .user,
            content: "Independent cache telemetry test.\n\(reference)\nReply with only OK; do not use any tools.")],
            reasoning: "off", overallTimeoutSeconds: 60, idleTimeoutSeconds: 30)
        var usages: [ModelUsage] = []
        for _ in 0..<2 {
            var usage: ModelUsage?
            var terminal: ModelFinishReason?
            for try await event in try await provider.stream(request) {
                if case let .usage(value) = event { usage = value }
                if case let .failed(error) = event { throw error }
                if case let .completed(reason) = event { terminal = reason }
            }
            #expect(terminal == .stop)
            let measured = try #require(usage)
            let input = try #require(measured.inputTokens)
            let cached = try #require(measured.cacheReadTokens, "Missing cache telemetry must not pass as zero")
            #expect(cached >= 0 && cached <= input)
            usages.append(measured)
        }
        #expect(try #require(usages.last?.cacheReadTokens) > 0, "Repeated input must produce a measured cache hit on this runtime")
        print("LIVE_RESPONSES_CACHE usages=\(usages)")
    }

    @Test(arguments: [ModelWireProtocol.chatCompletions, .responses])
    func autoAllowsTextRequiredParsesWriteFile(wire: ModelWireProtocol) async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"].flatMap(URL.init(string:)))
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"], "Provide a currently loaded model instance")
        let config = ProviderConfig(baseURL: baseURL, apiKey: nil, model: model, wireProtocol: wire)
        let provider: any ModelProvider = wire == .responses
            ? OpenAIResponsesProvider(config: config)
            : OpenAICompatibleProvider(config: config,
                wireExtension: LMStudioChatExtension(reasoningToggle: true, reasoningDefaultOn: true,
                    externalDraftModel: nil, mtpConfigured: false, sink: { _ in }))
        let tool = ToolDefinition(id: ToolID("write_file"), description: "Write UTF-8 text to a file at path.",
                                  inputSchema: ToolInputSchema(properties: [
                                    "path": ToolInputProperty(type: .string, description: "File path"),
                                    "content": ToolInputProperty(type: .string, description: "File content")
                                  ], required: ["path", "content"]), capability: ToolCapability(readOnly: false))
        func events(choice: ToolChoice, prompt: String) async throws -> [ModelEvent] {
            let request = ModelRequest(model: ModelID(model),
                system: "You are a file assistant. Use write_file when asked to create a file. Never claim a file exists before a tool result.",
                messages: [ModelMessage(role: .user, content: prompt)], tools: [tool], toolChoice: choice,
                reasoning: "off", overallTimeoutSeconds: 120, idleTimeoutSeconds: 30)
            var events: [ModelEvent] = []
            for try await event in try await provider.stream(request) { events.append(event) }
            return events
        }
        let auto = try await events(choice: .auto, prompt: "Explain in one short sentence what a text file is. Do not create any files.")
        #expect(auto.contains { if case let .textDelta(text) = $0 { return !text.isEmpty }; return false }, "Auto must allow a normal text answer")
        #expect(!auto.contains { if case .toolCallCompleted = $0 { return true }; return false })
        #expect(auto.contains(.completed(.stop)))

        let actionPrompt = "Create /tmp/lingxi-tool-choice-probe.txt with the exact content hello. Call write_file now."
        let autoAction = try await events(choice: .auto, prompt: actionPrompt)
        #expect(autoAction.contains { event in
            if case let .textDelta(text) = event { return !text.isEmpty }
            if case .toolCallCompleted = event { return true }
            return false
        }, "Auto may return text or tools for the action prompt")
        let required = try await events(choice: .required, prompt: actionPrompt)
        let calls = required.compactMap { event -> ToolCall? in
            if case let .toolCallCompleted(call) = event { return call }; return nil
        }
        let call = try #require(calls.first { $0.toolID == tool.id }, "Required must produce a parsed write_file ToolCall; text alone fails")
        #expect(!call.callID.rawValue.isEmpty)
        let args = try #require(JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String])
        #expect(args["path"] == "/tmp/lingxi-tool-choice-probe.txt")
        #expect(args["content"] == "hello")
        #expect(required.contains(.completed(.toolCalls)))
    }
}
