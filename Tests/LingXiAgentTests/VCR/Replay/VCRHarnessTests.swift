import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

private actor ScriptedProviderHTTPTransport: ProviderHTTPTransport {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    let delayMilliseconds: Int
    let failsAfterChunks: Bool

    init(status: Int = 200, headers: [String: String] = ["Content-Type": "text/event-stream"], chunks: [String], delayMilliseconds: Int = 0, failsAfterChunks: Bool = false) {
        self.status = status
        self.headers = headers
        self.chunks = chunks.map { Data($0.utf8) }
        self.delayMilliseconds = delayMilliseconds
        self.failsAfterChunks = failsAfterChunks
    }

    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        let chunks = chunks
        let delayMilliseconds = delayMilliseconds
        let failsAfterChunks = failsAfterChunks
        return ProviderHTTPResponse(statusCode: status, headers: headers, body: AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                    if delayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(delayMilliseconds)) }
                }
                if failsAfterChunks { continuation.finish(throwing: URLError(.networkConnectionLost)) }
                else { continuation.finish() }
            }
        })
    }
}

private actor ForbiddenNetworkTransport: ProviderHTTPTransport {
    private var callCount = 0

    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        callCount += 1
        throw URLError(.notConnectedToInternet)
    }

    func calls() -> Int { callCount }
}

@Suite(.serialized)
struct VCRHarnessTests {
    @Test func recordThenOfflineReplayUsesTheRealResponsesDecoderAndStrictMatching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "wire-regression", lingXiCommit: "test", createdAt: "2026-08-30T00:00:00Z")
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, workspaceRoot: directory, create: true)
        let upstream = ScriptedProviderHTTPTransport(chunks: [
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item-random\",\"call_id\":\"call-random\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n",
            "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item-random\",\"delta\":\"{\\\"path\\\":\\\"Fix\"}\n\n",
            "data: {\"type\":\"response.function_call_arguments.done\",\"call_id\":\"call-random\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"Fixture.md\\\"}\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_random\",\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}\n\n",
        ])
        let request = ModelRequest(model: ModelID("actual-model"), executionID: AgentRunID(UUID().uuidString), messages: [ModelMessage(role: .user, content: "read fixture")], tools: [ToolDefinition(id: ToolID("read_file"), description: "read", inputSchema: ToolInputSchema(properties: ["path": ToolInputProperty(type: .string, description: "path")], required: ["path"]), capability: ToolCapability(readOnly: true))], debugStep: 1)
        let recordProvider = provider(transport: VCRProviderTransport(mode: .record, cassette: recordStore, upstream: upstream))
        let recorded = try await collect(try await recordProvider.stream(request))
        #expect(recorded.contains { if case .toolCallCompleted = $0 { true } else { false } })

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, workspaceRoot: directory, create: false)
        let replayProvider = provider(transport: VCRProviderTransport(mode: .replay, cassette: replayStore))
        let replayRequest = ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID(UUID().uuidString), messages: request.messages, tools: request.tools, debugStep: 1)
        let replayed = try await collect(try await replayProvider.stream(replayRequest))
        let replayedCall = try #require(replayed.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }.first)
        #expect(replayedCall.toolID == ToolID("read_file"))
        #expect(replayedCall.arguments == #"{"path":"Fixture.md"}"#)
        #expect(replayed.contains(.usage(ModelUsage(inputTokens: 7, outputTokens: 3))))
        try await replayStore.assertFullyConsumed()

        let mismatchStore = try VCRCassetteStore(directory: directory, manifest: manifest, workspaceRoot: directory, create: false)
        let mismatchProvider = provider(transport: VCRProviderTransport(mode: .replay, cassette: mismatchStore))
        await #expect(throws: CassetteMismatch.self) {
            _ = try await mismatchProvider.stream(ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID(UUID().uuidString), messages: [ModelMessage(role: .user, content: "different request")], tools: request.tools, debugStep: 1))
        }
        let wrongModelStore = try VCRCassetteStore(directory: directory, manifest: manifest, workspaceRoot: directory, create: false)
        let wrongModelProvider = provider(transport: VCRProviderTransport(mode: .replay, cassette: wrongModelStore))
        await #expect(throws: CassetteMismatch.self) {
            _ = try await wrongModelProvider.stream(ModelRequest(model: ModelID("wrong-model"), executionID: AgentRunID(UUID().uuidString), messages: request.messages, tools: request.tools, debugStep: 1))
        }
    }

    @Test func replayNeverUsesAnInjectedUpstreamTransportAfterCassetteMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-no-network-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "no-network", lingXiCommit: "test")
        let store = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        let request = providerRequest("recorded")
        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("record-run"), step: 1)
        let prepared = try await store.prepareRecording(request, context: context)
        try await store.record(prepared: prepared, context: context, status: 200, responseHeaders: [:], chunks: [], terminalOffsetMilliseconds: 0, termination: .completed)

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        let forbiddenNetwork = ForbiddenNetworkTransport()
        let replay = VCRProviderTransport(mode: .replay, cassette: replayStore, upstream: forbiddenNetwork)
        await #expect(throws: CassetteMismatch.self) {
            _ = try await replay.send(providerRequest("unrecorded"), context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("replay-run"), step: 1))
        }
        #expect(await forbiddenNetwork.calls() == 0)
    }

    @Test func sanitizerRejectsCredentialsAndNormalizesPrivatePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-workspace")
        let sanitizer = VCRSanitizer(forbiddenSecrets: ["sentinel-api-key"], workspaceRoot: root)
        #expect(try sanitizer.sanitize("\(root.path)/Fixture.md") == "<workspace>/Fixture.md")
        #expect(throws: CassetteMismatch.self) { try sanitizer.sanitize("Bearer sentinel-api-key") }
        #expect(throws: CassetteMismatch.self) { try sanitizer.sanitize(#"{"access_token":"another-secret"}"#) }
    }

    @Test func rawDynamicIdentifiersAreCanonicalizedSequentiallyDuringRecord() throws {
        var normalizer1 = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        var normalizer2 = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        var normalizer3 = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")

        var req1 = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req1.httpBody = Data(#"{"input":[{"type":"function_call","name":"skill","call_id":"call-5"},{"type":"function_call_output","call_id":"call-5","output":"ok"}],"model_id":"","run_id":""}"#.utf8)

        var req2 = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req2.httpBody = Data(#"{"input":[{"type":"function_call","name":"skill","call_id":"call_abc123"},{"type":"function_call_output","call_id":"call_abc123","output":"ok"}],"model_id":"","run_id":""}"#.utf8)

        var req3 = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req3.httpBody = Data(#"{"input":[{"type":"function_call","name":"skill","call_id":"call-1"},{"type":"function_call_output","call_id":"call-1","output":"ok"}],"model_id":"","run_id":""}"#.utf8)

        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 1)
        let norm1 = try normalizer1.normalizeRequest(req1, context: context)
        let norm2 = try normalizer2.normalizeRequest(req2, context: context)
        let norm3 = try normalizer3.normalizeRequest(req3, context: context)

        #expect(norm1.0 == norm2.0)
        #expect(norm1.0 == norm3.0)
        #expect(norm1.1 == norm2.1)
        #expect(norm1.1 == norm3.1)
        #expect(norm1.0.contains(#""call_id":"call-1""#))
        #expect(!norm1.0.contains("call-5"))
        #expect(!norm2.0.contains("call_abc123"))
        #expect(norm1.0.contains(#""model_id":"""#))
        #expect(norm1.0.contains(#""run_id":"""#))
    }

    @Test func multipleCallIDsAndOutputsBindToOneToOneCanonicalTokens() throws {
        var recordNormalizer = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        let chunkData = Data((#"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item-99","call_id":"call-foo","name":"read_file","arguments":""}}"# + "\n\n" +
                              #"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"item-100","call_id":"call-bar","name":"grep","arguments":""}}"# + "\n\n").utf8)
        let normalizedChunk = try recordNormalizer.normalizeResponseChunk(chunkData, contentType: "text/event-stream")
        #expect(normalizedChunk.contains(#""call_id":"call-1""#))
        #expect(normalizedChunk.contains(#""call_id":"call-2""#))
        #expect(normalizedChunk.contains(#""id":"item-1""#))
        #expect(normalizedChunk.contains(#""id":"item-2""#))

        var nextRequest = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        nextRequest.httpBody = Data(#"{"input":[{"type":"function_call_output","call_id":"call-foo","output":"foo_content"},{"type":"function_call_output","call_id":"call-bar","output":"bar_content"}]}"#.utf8)
        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 2)
        let normalizedRequest = try recordNormalizer.normalizeRequest(nextRequest, context: context)
        #expect(normalizedRequest.0.contains(#"{"call_id":"call-1","output":"foo_content","type":"function_call_output"}"#))
        #expect(normalizedRequest.0.contains(#"{"call_id":"call-2","output":"bar_content","type":"function_call_output"}"#))
    }

    @Test func replayPreservesCanonicalTokensRegardlessOfArrivalOrder() throws {
        var replayNormalizer = VCRNormalizer(mode: .replay, sanitizer: VCRSanitizer(), modelAlias: "model")

        var req1 = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req1.httpBody = Data(#"{"input":[{"type":"function_call_output","call_id":"call-8","output":"result8"}]}"#.utf8)

        var req2 = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req2.httpBody = Data(#"{"input":[{"type":"function_call_output","call_id":"call-2","output":"result2"}]}"#.utf8)

        let context1 = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 1)
        let context2 = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 2)

        let norm1 = try replayNormalizer.normalizeRequest(req1, context: context1)
        let norm2 = try replayNormalizer.normalizeRequest(req2, context: context2)

        #expect(norm1.0.contains(#""call_id":"call-8""#))
        #expect(!norm1.0.contains(#""call_id":"call-1""#))
        #expect(norm2.0.contains(#""call_id":"call-2""#))
    }

    @Test func dynamicIdentifierCategoriesCoverItemResponseSessionRunAndOpaque() throws {
        var recorder = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        var req = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        req.httpBody = Data(#"{"item_id":"item-5","previous_response_id":"resp_xyz99","project_id":"project-alpha","questionID":"question-random","reasoning":{"encrypted_content":"raw_opaque_bytes"}}"#.utf8)

        let normalizedRecord = try recorder.normalizeRequest(req, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 1)).0
        #expect(normalizedRecord.contains(#""item_id":"item-1""#))
        #expect(normalizedRecord.contains(#""previous_response_id":"response-1""#))
        #expect(normalizedRecord.contains(#""project_id":"project-1""#))
        #expect(normalizedRecord.contains(#""questionID":"question-1""#))
        #expect(normalizedRecord.contains(#""encrypted_content":"<opaque-opaque-1>""#))

        var replayer = VCRNormalizer(mode: .replay, sanitizer: VCRSanitizer(), modelAlias: "model")
        var replayReq = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        replayReq.httpBody = Data(#"{"item_id":"item-1","previous_response_id":"response-1","project_id":"project-1","questionID":"question-1","reasoning":{"encrypted_content":"<opaque-opaque-1>"}}"#.utf8)
        let normalizedReplay = try replayer.normalizeRequest(replayReq, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 1)).0
        #expect(normalizedReplay.contains(#""item_id":"item-1""#))
        #expect(normalizedReplay.contains(#""previous_response_id":"response-1""#))
        #expect(normalizedReplay.contains(#""project_id":"project-1""#))
        #expect(normalizedReplay.contains(#""questionID":"question-1""#))
        #expect(normalizedReplay.contains(#""encrypted_content":"<opaque-opaque-1>""#))
        #expect(normalizedRecord == normalizedReplay)
    }

    @Test func childSessionAndRunIdentifiersNormalizeStably() throws {
        var record = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        var replay = VCRNormalizer(mode: .replay, sanitizer: VCRSanitizer(), modelAlias: "model")
        var recorded = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        recorded.httpBody = Data(#"{"childSessionID":{"rawValue":"record-session"},"run":{"runID":{"rawValue":"record-run"}}}"#.utf8)
        var replayed = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        replayed.httpBody = Data(#"{"childSessionID":{"rawValue":"fresh-session"},"run":{"runID":{"rawValue":"fresh-run"}}}"#.utf8)
        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 1)
        let normalizedRecord = try record.normalizeRequest(recorded, context: context).0
        let normalizedReplay = try replay.normalizeRequest(replayed, context: context).0
        #expect(normalizedRecord == normalizedReplay)
        #expect(normalizedRecord.contains("session-1"))
    }

    @Test func nonDeterministicIDsProduceStableRequestFingerprints() throws {
        func body(symbolID: String, childSession: String, modelID: String, startedAt: Double) -> Data {
            Data(#"{"input":[{"type":"function_call_output","call_id":"call-1","output":"[{\"id\":\"\#(symbolID)\",\"kind\":\"struct\"}]"},{"type":"function_call_output","call_id":"call-2","output":"{\"childSessionID\":{\"rawValue\":\"\#(childSession)\"},\"run\":{\"modelSelection\":{\"modelID\":\"\#(modelID)\"},\"startedAt\":\#(startedAt)}}"}]}"#.utf8)
        }
        var recordSide = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        var replaySide = VCRNormalizer(mode: .replay, sanitizer: VCRSanitizer(), modelAlias: "model")
        var recordRequest = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        recordRequest.httpBody = body(symbolID: "3c96ee46b7c3eee1", childSession: UUID().uuidString, modelID: "gpt-5.6-terra", startedAt: 1_788_069_809)
        var replayRequest = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        replayRequest.httpBody = body(symbolID: "1ebe7a4a9fac40db", childSession: UUID().uuidString, modelID: "model", startedAt: 1_788_069_999)
        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "model", executionID: nil, step: 3)
        let recordNormalized = try recordSide.normalizeRequest(recordRequest, context: context)
        let replayNormalized = try replaySide.normalizeRequest(replayRequest, context: context)
        #expect(recordNormalized.0 == replayNormalized.0)
        #expect(recordNormalized.1 == replayNormalized.1)
    }

    @Test func normalizedRunRelationshipsBindBackToFreshReplayRuns() throws {
        let oldRun = AgentRunID(UUID().uuidString)
        var recorder = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        #expect(recorder.role(for: oldRun) == "run-1")
        let recorded = try recorder.normalizeResponseChunk(Data("data: {\"type\":\"response.function_call_arguments.done\",\"call_id\":\"call-a\",\"name\":\"subagent\",\"arguments\":\"{\\\"action\\\":\\\"result\\\",\\\"run_id\\\":\\\"\(oldRun.rawValue)\\\"}\"}\n\n".utf8), contentType: "text/event-stream")
        #expect(recorded.contains("run-1"))
        #expect(!recorded.contains(oldRun.rawValue))

        let freshRun = AgentRunID(UUID().uuidString)
        var replay = VCRNormalizer(mode: .replay, sanitizer: VCRSanitizer(), modelAlias: "model")
        replay.bindRun(freshRun, to: "run-1")
        let replayed = String(decoding: replay.denormalizeResponseChunk(recorded), as: UTF8.self)
        #expect(replayed.contains(freshRun.rawValue))
        #expect(!replayed.contains(oldRun.rawValue))

        var camelCase = VCRNormalizer(mode: .record, sanitizer: VCRSanitizer(), modelAlias: "model")
        let normalizedCamelCase = try camelCase.normalizeResponseChunk(Data("{\"runID\":\"dynamic-run\",\"api_key\":\"foreign-secret\"}".utf8), contentType: "application/json")
        #expect(normalizedCamelCase.contains("run-1"))
        #expect(!normalizedCamelCase.contains("api_key"))
        #expect(!normalizedCamelCase.contains("foreign-secret"))
    }

    @Test func timedReplayUsesRecordedRelativeEventDelays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-timed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "timed", lingXiCommit: "test", createdAt: "2026-08-30T00:00:00Z")
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        let upstream = ScriptedProviderHTTPTransport(chunks: [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"A\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"B\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
        ], delayMilliseconds: 20)
        let request = ModelRequest(model: ModelID("actual"), executionID: AgentRunID(UUID().uuidString), messages: [ModelMessage(role: .user, content: "timed")], debugStep: 1)
        _ = try await collect(try await provider(transport: VCRProviderTransport(mode: .record, cassette: recordStore, upstream: upstream)).stream(request))

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        let clock = ContinuousClock()
        let start = clock.now
        let events = try await collect(try await provider(transport: VCRProviderTransport(mode: .replay, timing: .timed, cassette: replayStore)).stream(ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID(UUID().uuidString), messages: request.messages, debugStep: 1)))
        #expect(start.duration(to: clock.now) >= .milliseconds(15))
        #expect(events.contains(.textDelta("A")))
        #expect(events.contains(.textDelta("B")))
    }

    @Test func terminalWordsInsideTextDoNotTruncateTheCassette() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-terminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "terminal-text", lingXiCommit: "test")
        let request = ModelRequest(model: ModelID("actual"), executionID: AgentRunID(UUID().uuidString), messages: [ModelMessage(role: .user, content: "terminal text")], debugStep: 1)
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        let upstream = ScriptedProviderHTTPTransport(chunks: [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"response.completed is only text\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\" after\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
        ])
        _ = try await collect(try await provider(transport: VCRProviderTransport(mode: .record, cassette: recordStore, upstream: upstream)).stream(request))

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        let events = try await collect(try await provider(transport: VCRProviderTransport(mode: .replay, cassette: replayStore)).stream(ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID(UUID().uuidString), messages: request.messages, debugStep: 1)))
        #expect(events.contains(.textDelta("response.completed is only text")))
        #expect(events.contains(.textDelta(" after")))
        try await replayStore.assertFullyConsumed()
    }

    @Test func failedAndIncompleteStreamsRemainFailuresOnReplay() async throws {
        for failsAfterChunks in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-failure-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "failure", lingXiCommit: "test")
            let request = ModelRequest(model: ModelID("actual"), executionID: AgentRunID(UUID().uuidString), messages: [ModelMessage(role: .user, content: "fail")], debugStep: 1)
            let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
            let upstream = ScriptedProviderHTTPTransport(chunks: ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"], failsAfterChunks: failsAfterChunks)
            let recorded = try await collect(try await provider(transport: VCRProviderTransport(mode: .record, cassette: recordStore, upstream: upstream)).stream(request))
            #expect(recorded.contains { if case .failed = $0 { true } else { false } })

            let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
            let replayed = try await collect(try await provider(transport: VCRProviderTransport(mode: .replay, cassette: replayStore)).stream(ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID(UUID().uuidString), messages: request.messages, debugStep: 1)))
            #expect(replayed.contains { if case .failed = $0 { true } else { false } })
            try await replayStore.assertFullyConsumed()
        }
    }

    @Test func cancelledReplayDoesNotConsumeTheReservedExchange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "cancel", lingXiCommit: "test")
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        let request = providerRequest("cancel")
        let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("record-run"), step: 1)
        let prepared = try await recordStore.prepareRecording(request, context: context)
        try await recordStore.record(prepared: prepared, context: context, status: 200, responseHeaders: ["Content-Type": "text/event-stream"], chunks: [
            VCRWireChunk(index: 0, offsetMilliseconds: 0, data: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"first\"}\n\n"),
            VCRWireChunk(index: 1, offsetMilliseconds: 1_000, data: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"),
        ], terminalOffsetMilliseconds: 1_000, termination: .completed)

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        var abandoned: ProviderHTTPResponse? = try await VCRProviderTransport(mode: .replay, cassette: replayStore).send(request, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("fresh-run"), step: 1))
        #expect(abandoned != nil)
        abandoned = nil
        try await Task.sleep(for: .milliseconds(20))
        await #expect(throws: CassetteMismatch.self) { try await replayStore.assertFullyConsumed() }

        let transport = VCRProviderTransport(mode: .replay, timing: .timed, cassette: replayStore)
        let response = try await transport.send(request, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("fresh-run"), step: 1))
        let consumer = Task { for try await _ in response.body {} }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        _ = try? await consumer.value
        try await Task.sleep(for: .milliseconds(20))
        await #expect(throws: CassetteMismatch.self) { try await replayStore.assertFullyConsumed() }

        let retry = try await transport.send(request, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("fresh-run"), step: 1))
        for try await _ in retry.body {}
        try await replayStore.assertFullyConsumed()
    }

    @Test func repeatedQuestionsBindToTheCorrectRunAndSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-question-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "questions", lingXiCommit: "test")
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        let recordedRuns = [AgentRunID("record-a"), AgentRunID("record-b")]
        let recordedSessions = [SessionID("session-a"), SessionID("session-b")]
        for index in recordedRuns.indices {
            let request = providerRequest(String(UnicodeScalar(97 + index)!))
            let context = ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: recordedRuns[index], step: 1)
            let prepared = try await recordStore.prepareRecording(request, context: context)
            try await recordStore.record(prepared: prepared, context: context, status: 200, responseHeaders: [:], chunks: [], terminalOffsetMilliseconds: 0, termination: .completed)
        }
        let questionA = question(id: "record-question-a", session: recordedSessions[0], run: recordedRuns[0])
        _ = try await recordStore.answer(questionA, mode: .record, scripted: QuestionReply(questionID: questionA.questionID, text: "A1"))
        _ = try await recordStore.answer(questionA, mode: .record, scripted: QuestionReply(questionID: questionA.questionID, text: "A2"))
        let questionB = question(id: "record-question-b", session: recordedSessions[1], run: recordedRuns[1])
        _ = try await recordStore.answer(questionB, mode: .record, scripted: QuestionReply(questionID: questionB.questionID, text: "B"))

        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        let replayRuns = [AgentRunID("fresh-a"), AgentRunID("fresh-b")]
        let replaySessions = [SessionID("fresh-session-a"), SessionID("fresh-session-b")]
        for index in [1, 0] {
            let exchange = try await replayStore.replay(providerRequest(String(UnicodeScalar(97 + index)!)), context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: replayRuns[index], step: 1))
            await replayStore.finishReplay(sequence: exchange.sequence)
        }
        let replayB = question(id: "fresh-question-b", session: replaySessions[1], run: replayRuns[1])
        #expect(try await replayStore.answer(replayB, mode: .replay, scripted: nil).text == "B")
        let replayA = question(id: "fresh-question-a", session: replaySessions[0], run: replayRuns[0])
        #expect(try await replayStore.answer(replayA, mode: .replay, scripted: nil).text == "A1")
        #expect(try await replayStore.answer(replayA, mode: .replay, scripted: nil).text == "A2")
        try await replayStore.assertFullyConsumed()
    }

    @Test func requestHeadersParticipateInStrictMatching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-headers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "headers", lingXiCommit: "test")
        let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
        var request = providerRequest("headers")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let recordContext = ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("record-run"), step: 1)
        let prepared = try await recordStore.prepareRecording(request, context: recordContext)
        try await recordStore.record(prepared: prepared, context: recordContext, status: 200, responseHeaders: [:], chunks: [], terminalOffsetMilliseconds: 0, termination: .completed)

        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
        await #expect(throws: CassetteMismatch.self) {
            _ = try await replayStore.replay(request, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "fixture-model", executionID: AgentRunID("fresh-run"), step: 1))
        }
    }

    @Test func non2xxBodiesAreCommittedForChatAndAnthropicReplay() async throws {
        for wire in [ModelWireProtocol.chatCompletions, .anthropicMessages] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-http-error-\(wire.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manifest = VCRCassetteManifest(wire: wire, modelAlias: "fixture-model", scenario: "http-error", lingXiCommit: "test")
            let recordStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: true)
            let upstream = ScriptedProviderHTTPTransport(status: 401, headers: ["Content-Type": "application/json"], chunks: [#"{"error":"denied"}"#])
            let request = ModelRequest(model: ModelID("actual"), executionID: AgentRunID("record-run"), messages: [ModelMessage(role: .user, content: "fail")], debugStep: 1)
            await #expect(throws: CoreError.self) { _ = try await provider(wire: wire, transport: VCRProviderTransport(mode: .record, cassette: recordStore, upstream: upstream)).stream(request) }

            let replayStore = try VCRCassetteStore(directory: directory, manifest: manifest, create: false)
            let replayRequest = ModelRequest(model: ModelID("fixture-model"), executionID: AgentRunID("fresh-run"), messages: request.messages, debugStep: 1)
            await #expect(throws: CoreError.self) { _ = try await provider(wire: wire, transport: VCRProviderTransport(mode: .replay, cassette: replayStore)).stream(replayRequest) }
            try await replayStore.assertFullyConsumed()
        }
    }

    @Test func workspaceSkillIsDiscoveredAndLoadedByTheRealToolRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(".lingxi/skills/fixture-analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Skills/fixture-analysis/SKILL.md")
        try FileManager.default.copyItem(at: fixture, to: destination.appendingPathComponent("SKILL.md"))
        let workspace = try WorkspaceRoot(path: root.path)
        let runtime = ToolRuntime(registry: .builtin(workspace: workspace), permissions: PermissionEngine(defaultDecision: .allow))
        #expect(runtime.definitions.first(where: { $0.id == ToolID("skill") })?.description.contains("fixture-analysis") == true)
        let outcome = await runtime.executeWithMetrics(ToolCall(callID: ToolCallID("skill-call"), toolID: ToolID("skill"), arguments: #"{"name":"fixture-analysis"}"#), sessionID: SessionID("session")) { _ in }
        #expect(outcome.result.success)
        #expect(outcome.result.content.contains("FooAnchor-729"))
    }

    private func provider(transport: any ProviderHTTPTransport) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://offline.invalid/v1")!, apiKey: nil, model: "fixture-model", wireProtocol: .responses), transport: transport)
    }

    private func provider(wire: ModelWireProtocol, transport: any ProviderHTTPTransport) -> any ModelProvider {
        let config = ProviderConfig(baseURL: URL(string: "https://offline.invalid/v1")!, apiKey: nil, model: "fixture-model", wireProtocol: wire)
        switch wire {
        case .chatCompletions: return OpenAICompatibleProvider(config: config, transport: transport)
        case .responses: return OpenAIResponsesProvider(config: config, transport: transport)
        case .anthropicMessages: return AnthropicMessagesProvider(config: config, transport: transport)
        }
    }

    private func collect(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
        var result: [ModelEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }

    private func providerRequest(_ input: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"input\":\"\(input)\"}".utf8)
        return request
    }

    private func question(id: String, session: SessionID, run: AgentRunID) -> QuestionRequest {
        QuestionRequest(questionID: QuestionID(id), question: "Choose", options: ["one", "two"], allowsFreeText: false, originSessionID: session, originRunID: run)
    }
}
