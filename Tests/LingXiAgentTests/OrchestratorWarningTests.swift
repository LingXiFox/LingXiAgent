import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private struct EmptyObservationTool: ToolExecutor {
    let definition = ToolDefinition(id: ToolID("empty_observation"), description: "Return an empty list for regression replay.",
        inputSchema: ToolInputSchema(properties: [:], required: []), capability: ToolCapability(readOnly: true))
    func resource(for arguments: String, profile: ExecutionProfile) throws -> String { "empty" }
    func execute(arguments: String, profile: ExecutionProfile) async throws -> String { "[]" }
}

@Suite("Orchestrator warning regression", .serialized)
struct OrchestratorWarningTests {
    private func call(_ id: String, _ tool: String, _ arguments: [String: String]) throws -> [ModelEvent] {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let call = ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: String(decoding: data, as: UTF8.self))
        return [.toolCallCompleted(call), .completed(.toolCalls)]
    }

    @Test func decliningRealTestFailuresMustReachThePassingRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-warning-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = """
        remaining=$(cat remaining.txt)
        failed=0
        i=0
        while [ "$i" -lt 21 ]; do
            if [ "$i" -ge "$remaining" ]; then
                echo "test_$i PASS"
            else
                echo "test_$i FAIL" >&2
                failed=$((failed + 1))
            fi
            i=$((i + 1))
        done
        if [ "$failed" -gt 0 ]; then
            echo "FAILED (failures=$failed)" >&2
            exit 1
        fi
        echo "OK (21 tests)"
        """
        try fixture.write(to: root.appendingPathComponent("test_suite.sh"), atomically: true, encoding: .utf8)
        try "21".write(to: root.appendingPathComponent("remaining.txt"), atomically: true, encoding: .utf8)
        var script: [[ModelEvent]] = []
        for (index, remaining) in [21, 8, 6, 0].enumerated() {
            if index > 0 {
                script.append(try call("fix-\(index)", "shell", ["command": "printf '\(remaining)' > remaining.txt"]))
            }
            script.append(try call("test-\(index)", "shell", ["command": "sh test_suite.sh"]))
        }
        script.append([.textDelta("All 21 tests passed."), .completed(.stop)])
        let repairRequests = script.count
        script.append([.textDelta("Ready for the next task."), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let host = try CoreHost(
            startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow,
            interactive: false)
        await host.start()
        defer { await host.shutdown() }
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        do {
            for try await _ in try await client.sendMessage(sessionID: sid, content: "Fix the project tests and run the complete suite until it passes.") {}
        } catch {
            Issue.record("The model must be allowed to finish its repair: \(error)")
        }
        let requests = provider.recorder.requests
        #expect(requests.count == repairRequests)
        let warned = try #require(requests.first { $0.cachePlan?.volatileTail.ephemeralNotes != nil })
        #expect(warned.messages.last?.segment == .orchestratorWarning)
        #expect(warned.cachePlan?.appendOnlyContext.messages.contains { $0.segment == .orchestratorWarning } == false)
        let baseline = try #require(requests.first?.cachePlan)
        for request in requests {
            let plan = try #require(request.cachePlan)
            #expect(plan.epochIdentity.epoch == baseline.epochIdentity.epoch)
            #expect(plan.immutableBase == baseline.immutableBase)
            #expect(plan.appendOnlyContext.dynamicTools == baseline.appendOnlyContext.dynamicTools)
            #expect(plan.structuralHealth.stablePrefixHash == baseline.structuralHealth.stablePrefixHash)
            #expect(plan.structuralHealth.clientCausedBusts == 0)
            #expect(plan.structuralHealth.appendOnlyViolations == 0)
        }
        #expect(requests.last?.cachePlan?.volatileTail.ephemeralNotes == nil, "The passing retry clears the warning")
        let results = requests.last?.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result }; return nil
        } ?? []
        let tests = results.filter { $0.callID.rawValue.hasPrefix("test-") }
        #expect(tests.map(\.exitCode) == [1, 1, 1, 0])
        for (result, count) in zip(tests.prefix(3), [21, 8, 6]) {
            #expect(result.content.contains("failures=\(count)"))
        }
        #expect(tests.last?.content.contains("OK") == true)
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) })

        // A following turn must not inherit the warning, even with the same durable logical history.
        _ = try await host.sessionStore.appendMessage(sid, role: .assistant,
            content: String(repeating: "Historical context used to exercise real page-out. ", count: 200))
        for try await _ in try await client.sendMessage(sessionID: sid, content: "What is your current status?") {}
        #expect(provider.recorder.requests.count == script.count)
        #expect(provider.recorder.requests.last?.messages.contains { $0.segment == .orchestratorWarning } == false)
        let durable = try await host.sessionStore.session(sid)
        #expect(durable.messages.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) })

        // Force the existing compactor over real durable Session entries, without projecting warnings.
        let engine = PCoreContextEngine()
        let entries = await engine.entries(for: durable)
        let budget = ContextBudget(hardInputLimit: 65_536, preferredActiveTokens: 512, highWaterTokens: 512,
            lowWaterTokens: 256, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)
        let compacted = try await host.compactor.compact(sessionID: sid, entries: entries, budget: budget, trigger: .manual)
        #expect(compacted.pagedOut > 0)
        let references = await host.ecoreStoreRef.references(sessionID: sid)
        #expect(!references.isEmpty)
        for reference in references {
            let payload = try #require(try await host.ecoreStoreRef.restore(sessionID: sid, referenceID: reference.referenceID))
            #expect(!payload.contains(ToolLoopProgressTracker.heading))
        }
    }

    @Test func previouslyMissingFileCanBeRetriedAfterRealCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [
            try call("missing", "read_file", ["path": "later.txt"]),
            try call("create", "shell", ["command": "printf 'now exists' > later.txt"]),
            try call("retry", "read_file", ["path": "later.txt"]),
            [.textDelta("The file now exists and was read."), .completed(.stop)],
        ])
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: false)
        await host.start()
        defer { await host.shutdown() }
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Read later.txt; run the setup command if it is missing, then retry the read") {}
        let result = try #require(provider.recorder.requests.last?.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part, result.callID == ToolCallID("retry") { return result }; return nil
        }.first)
        #expect(result.success && result.content.contains("now exists"))
        #expect(result.metadata["repeatBlocked"] == nil)
    }

    @Test func warningEncodesOnceAtTheUncachedTailAcrossProviders() throws {
        let call = ToolCall(callID: ToolCallID("failed"), toolID: ToolID("shell"), arguments: "{}")
        let result = ToolResult(callID: call.callID, success: false, content: "Actual failure output", toolName: "shell", exitCode: 1)
        let history: [ModelMessage] = [.init(role: .user, content: "Run the tests"),
            .init(role: .assistant, parts: [.toolCall(call)]), .init(role: .tool, parts: [.toolResult(result)])]
        let text = ToolLoopProgressTracker.heading + "\nA tool operation has failed repeatedly."
        let plan = CanonicalCachePlan(epochIdentity: .init(epoch: 7),
            immutableBase: .init(systemPrompt: "Stable instructions"), appendOnlyContext: .init(messages: history),
            volatileTail: .init(ephemeralNotes: text), structuralHealth: .init(stablePrefixHash: "fixed"))
        let request = ModelRequest(model: ModelID("any-model"), messages: history + [.init(role: .user, content: text, segment: .orchestratorWarning)], cachePlan: plan)
        #expect(request.providerContextMessages.last?.segment == .orchestratorWarning)
        for body in try [OpenAICompatibleProvider.makeRequestBody(request), OpenAIResponsesProvider.makeRequestBody(request), AnthropicMessagesProvider.makeRequestBody(request)] {
            let wire = String(decoding: body, as: UTF8.self)
            #expect(wire.components(separatedBy: ToolLoopProgressTracker.heading).count == 2)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let items = try #require((json["messages"] ?? json["input"]) as? [[String: Any]])
            #expect(items.last?["role"] as? String == "user")
            #expect((json["instructions"] as? String ?? json["system"] as? String ?? "").contains(text) == false)
            #expect(wire.contains("Actual failure output"))
        }
        let remote = OpenAIResponsesProvider(config: .init(baseURL: URL(string: "https://example.invalid/v1")!,
            apiKey: nil, model: "any-model", wireProtocol: .responses, remoteStateEnabled: true))
        let body = try #require(remote.makeURLRequest(request, previousResponseID: "previous").httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["previous_response_id"] as? String == "previous")
        #expect(!String(decoding: body, as: UTF8.self).contains(text))
        #expect((json["input"] as? [[String: Any]])?.count == 1)
    }

    @Test func repeatedEmptyToolResultsRemainUnmodifiedAndDoNotStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var script = try (1...10).map { try call("empty-\($0)", "empty_observation", [:]) }
        script.append([.textDelta("The queries returned no entries."), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow,
            toolRegistry: ToolRegistry([EmptyObservationTool()]), interactive: false)
        await host.start()
        defer { await host.shutdown() }
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Inspect the available entries") {}
        #expect(provider.recorder.requests.count == script.count)
        #expect(provider.recorder.requests[2].cachePlan?.volatileTail.ephemeralNotes?.contains("empty results") == true)
        let results = try await host.sessionStore.session(sid).messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result }; return nil
        }
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0.content == "[]" && $0.success })
    }
}
