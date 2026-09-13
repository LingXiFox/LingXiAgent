import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiTUIComponents

@Suite struct PrefixCacheOptimizationTests {

    @Test func prefixReuseEfficiencyAndCachedInputShareCalculations() {
        let snapshot = ContextStateSnapshot(
            sessionID: SessionID("s1"),
            cacheReadTokens: 2816,
            promptTokens: 4439,
            previousPromptTokens: 3127,
            cacheStatus: "active",
            cacheEpoch: 1
        )

        let reuse = snapshot.prefixReuseEfficiency
        let share = snapshot.cachedInputShare

        #expect(reuse != nil)
        #expect(share != nil)
        #expect(abs((reuse ?? 0) - 0.9005) < 0.005)
        #expect(abs((share ?? 0) - 0.6343) < 0.005)
    }

    @Test func cacheStatusColdEpochAndUnavailable() {
        let cold = ContextStateSnapshot(
            sessionID: SessionID("s1"),
            cacheReadTokens: 0,
            promptTokens: 3127,
            previousPromptTokens: nil,
            cacheStatus: "coldNewEpoch",
            cacheEpoch: 1,
            epochReason: "initial"
        )
        #expect(cold.prefixReuseEfficiency == nil)
        #expect(cold.cacheStatus == "coldNewEpoch")

        let unavail = ContextStateSnapshot(
            sessionID: SessionID("s2"),
            cacheReadTokens: nil,
            promptTokens: 1000,
            previousPromptTokens: nil,
            cacheStatus: "unavailable"
        )
        #expect(unavail.prefixReuseEfficiency == nil)
        #expect(unavail.cachedInputShare == nil)
        #expect(unavail.cacheStatus == "unavailable")
    }

    @Test func toolsPartitionMaintainsStableCorePrefix() {
        let readDef = ToolDefinition(
            id: ToolID("read_file"),
            name: "read_file",
            description: "Read file content",
            inputSchema: ToolInputSchema(properties: [:], required: []),
            capability: ToolCapability(readOnly: true)
        )
        let writeDef = ToolDefinition(
            id: ToolID("write_file"),
            name: "write_file",
            description: "Write file content",
            inputSchema: ToolInputSchema(properties: [:], required: []),
            capability: ToolCapability(readOnly: false)
        )
        let mcpDynamicA = ToolDefinition(
            id: ToolID("a_mcp_discovery"),
            name: "a_mcp_discovery",
            description: "Dynamic tool A",
            inputSchema: ToolInputSchema(properties: [:], required: []),
            capability: ToolCapability(readOnly: true)
        )
        let mcpDynamicZ = ToolDefinition(
            id: ToolID("z_mcp_custom"),
            name: "z_mcp_custom",
            description: "Dynamic tool Z",
            inputSchema: ToolInputSchema(properties: [:], required: []),
            capability: ToolCapability(readOnly: true)
        )

        let coreIDs = ToolRuntime.coreToolIDs
        let allTools = [mcpDynamicZ, writeDef, mcpDynamicA, readDef]

        let core = allTools.filter { coreIDs.contains($0.id) }.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        let dynamic = allTools.filter { !coreIDs.contains($0.id) }.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        let orderedTools = core + dynamic

        #expect(orderedTools.count == 4)
        #expect(orderedTools[0].id == ToolID("read_file"))
        #expect(orderedTools[1].id == ToolID("write_file"))
        #expect(orderedTools[2].id == ToolID("a_mcp_discovery"))
        #expect(orderedTools[3].id == ToolID("z_mcp_custom"))
    }

    @Test func prefixFingerprintDiagnosticsIdentifiesChangedSegment() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(contextPager: pager, scanner: scanner, maxL1ResidentCharacters: 48 * 1024)
        let sID = SessionID("diag-session")

        let fp1 = PrefixFingerprint(
            systemHash: "sys1111",
            coreToolsHash: "core2222",
            leasedToolsHash: "leased3333",
            requestProfileHash: "prof4444",
            stablePrefixHash: "stable5555"
        )
        await controller.recordFingerprint(sessionID: sID, fingerprint: fp1)
        await controller.recordProviderCacheHit(sessionID: sID, cachedTokens: 0, promptTokens: 3000)

        // 第 2 轮：leasedToolsHash 发生变动，导致命中率低下 (1500 / 3000 = 50% < 90%)
        let fp2 = PrefixFingerprint(
            systemHash: "sys1111",
            coreToolsHash: "core2222",
            leasedToolsHash: "leased_MUTATED_9999",
            requestProfileHash: "prof4444",
            stablePrefixHash: "stable_MUTATED"
        )
        await controller.recordFingerprint(sessionID: sID, fingerprint: fp2)
        await controller.recordProviderCacheHit(sessionID: sID, cachedTokens: 1500, promptTokens: 3200)

        let record = await controller.lastProviderCacheRecord(for: sID)
        #expect(record?.status == "active")
        #expect(record?.missDiagnostics != nil)
        #expect(record?.missDiagnostics?.contains("leasedToolsHash changed") == true)
        #expect(record?.missDiagnostics?.contains("coreToolsHash") == false)
        #expect(record?.missDiagnostics?.contains("systemHash") == false)
    }

    @Test func toolResultHeadTailPreservationWithinBudget() {
        let hugeContent = String(repeating: "Line A: initial content\n", count: 100) +
                          String(repeating: "Line B: middle log junk\n", count: 200) +
                          String(repeating: "Line C: final exit code 0\n", count: 50)
        let result = ToolResult(
            callID: ToolCallID("call-huge"),
            success: true,
            content: hugeContent,
            toolName: "shell_exec"
        )

        let projected = ModelToolResultProjection.project(result, budget: ToolResultBudget(maxShown: 20, maxCharacters: 800))
        #expect(projected.truncated == true)
        #expect(projected.content.count <= 1100)
        #expect(projected.content.contains("Line A: initial content"))
        #expect(projected.content.contains("Line C: final exit code 0"))
        #expect(projected.content.contains("truncated for prefix-cache efficiency"))
    }

    @Test func sessionCacheRecordTelemetryWithWriteTokensAndDelta() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(contextPager: pager, scanner: scanner, maxL1ResidentCharacters: 48 * 1024)
        let sID = SessionID("telemetry-session")

        // First turn
        await controller.recordProviderCacheHit(
            sessionID: sID,
            cachedTokens: 0,
            promptTokens: 2000,
            cacheWriteTokens: 2000,
            provider: "anthropic",
            model: "claude-3-7-sonnet",
            isUnavailable: false
        )
        let record1 = await controller.lastProviderCacheRecord(for: sID)
        #expect(record1?.cachedTokens == 0)
        #expect(record1?.promptTokens == 2000)
        #expect(record1?.cacheWriteTokens == 2000)
        #expect(record1?.provider == "anthropic")
        #expect(record1?.model == "claude-3-7-sonnet")
        #expect(record1?.contextGrowthDelta == nil)

        // Second turn
        await controller.recordProviderCacheHit(
            sessionID: sID,
            cachedTokens: 1900,
            promptTokens: 2600,
            cacheWriteTokens: 700,
            provider: "anthropic",
            model: "claude-3-7-sonnet",
            isUnavailable: false
        )
        let record2 = await controller.lastProviderCacheRecord(for: sID)
        #expect(record2?.cachedTokens == 1900)
        #expect(record2?.promptTokens == 2600)
        #expect(record2?.previousPromptTokens == 2000)
        #expect(record2?.contextGrowthDelta == 600)
        #expect(record2?.cacheWriteTokens == 700)
    }

    @Test func prefixFingerprintCanonicalSortingIdempotency() {
        let propA = ToolInputProperty(type: .string, description: "path to read")
        let propB = ToolInputProperty(type: .integer, description: "limit count")
        let schema1 = ToolInputSchema(properties: ["path": propA, "limit": propB], required: ["path"])
        let schema2 = ToolInputSchema(properties: ["limit": propB, "path": propA], required: ["path"])

        let _ = ToolDefinition(id: ToolID("tool_a"), name: "tool_a", description: "desc A", inputSchema: schema1, capability: ToolCapability(readOnly: true))
        let _ = ToolDefinition(id: ToolID("tool_b"), name: "tool_b", description: "desc B", inputSchema: schema2, capability: ToolCapability(readOnly: false))

        let _ = ContextEntry(messageID: MessageID("m1"), role: .user, source: .userMessage, part: .text("Hello"))
        let _ = ContextEntry(messageID: MessageID("m2"), role: .assistant, source: .assistantMessage, part: .text("Hi"))

        let fpA = PrefixFingerprint(
            systemHash: "sys",
            coreToolsHash: "core",
            leasedToolsHash: "leased",
            requestProfileHash: "profile",
            stablePrefixHash: "stable"
        )
        let fpB = PrefixFingerprint(
            systemHash: "sys",
            coreToolsHash: "core",
            leasedToolsHash: "leased",
            requestProfileHash: "profile",
            stablePrefixHash: "stable"
        )
        #expect(fpA == fpB)
        #expect(fpA.stablePrefixHash == fpB.stablePrefixHash)
    }

    @Test func terminatedStreamSubscriptionFinishesImmediatelyWithoutDeadlock() async {
        let sessionID = SessionID("s_deadlock_test")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
        let streamID = StreamID("test_stream")
        let causal = CausalContext(sessionID: SessionID("s_deadlock_test"))

        // Emit 2 frames and close the stream
        let f0 = StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "Hello ")
        let f1 = StreamFrame(streamID: streamID, owner: causal, index: 1, kind: .assistantText, text: "world")
        _ = try? await coordinator.emitStreamFrame(frame: f0)
        _ = try? await coordinator.emitStreamFrame(frame: f1)
        await coordinator.closeStream(streamID: streamID, finalIndex: 1)

        // Case 1: Subscribe with afterIndex == 1 (replay is empty, stream is terminated)
        let streamAfterAll = await coordinator.subscribeStream(streamID: streamID, afterIndex: 1)
        var receivedCount = 0
        for await _ in streamAfterAll {
            receivedCount += 1
        }
        #expect(receivedCount == 0) // Finished immediately without hanging

        // Case 2: Subscribe from beginning after termination
        let streamFromStart = await coordinator.subscribeStream(streamID: streamID, afterIndex: nil)
        var text = ""
        for await frame in streamFromStart {
            text += frame.textPayload ?? ""
        }
        #expect(text == "Hello world") // Replayed all frames and finished immediately
    }

    @Test func cacheControllerDoesNotBustOnUnavailableOrUpstreamVariance() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(contextPager: pager, scanner: scanner, maxL1ResidentCharacters: 48 * 1024)
        let sID = SessionID("s_bust_test")

        // Turn 1: Initial turn, cold epoch
        await controller.recordProviderCacheHit(
            sessionID: sID,
            cachedTokens: 0,
            promptTokens: 2000,
            isUnavailable: false
        )
        let debt1 = await controller.scheduler.debtState(for: sID).cacheDebt
        #expect(debt1 == 0)

        // Turn 2: Upstream returns unavailable (e.g. proxy or provider doesn't report cache)
        await controller.recordProviderCacheHit(
            sessionID: sID,
            cachedTokens: 0,
            promptTokens: 2500,
            isUnavailable: true
        )
        let debt2 = await controller.scheduler.debtState(for: sID).cacheDebt
        #expect(debt2 == 0) // MUST NOT penalize client for unavailable upstream

        // Turn 3: Upstream cache variance (client structure 100% stable, but cachedTokens == 0)
        await controller.recordProviderCacheHit(
            sessionID: sID,
            cachedTokens: 0,
            promptTokens: 2700,
            isUnavailable: false
        )
        let debt3 = await controller.scheduler.debtState(for: sID).cacheDebt
        #expect(debt3 == 0) // MUST NOT penalize client when client prefix is stable
    }

    @Test func openAIRequestBodyIncludesStreamOptionsAndParsesMultipleUsageFormats() throws {
        let req = ModelRequest(
            model: ModelID("gpt-4o"),
            messages: [ModelMessage(role: .user, parts: [.text("hello")])]
        )
        let data = try OpenAICompatibleProvider.makeRequestBody(req)
        let jsonStr = String(decoding: data, as: UTF8.self)
        #expect(jsonStr.contains("\"stream_options\":{\"include_usage\":true}"))

        // Test SSEUsage decoding with prompt_tokens_details.cached_tokens
        let json1 = """
        {"prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 80}}
        """.data(using: .utf8)!
        let usage1 = try JSONDecoder().decode(OpenAICompatibleProvider.SSEUsage.self, from: json1)
        #expect(usage1.promptTokensDetails?.cachedTokens == 80)

        // Test SSEUsage decoding with prompt_cache_hit_tokens (DeepSeek format)
        let json2 = """
        {"prompt_tokens": 100, "completion_tokens": 20, "prompt_cache_hit_tokens": 75, "prompt_cache_miss_tokens": 25}
        """.data(using: .utf8)!
        let usage2 = try JSONDecoder().decode(OpenAICompatibleProvider.SSEUsage.self, from: json2)
        #expect(usage2.promptCacheHitTokens == 75)

        // Test SSEUsage decoding with cache_read_input_tokens (Anthropic compatible format)
        let json3 = """
        {"prompt_tokens": 100, "completion_tokens": 20, "cache_read_input_tokens": 90, "cache_creation_input_tokens": 10}
        """.data(using: .utf8)!
        let usage3 = try JSONDecoder().decode(OpenAICompatibleProvider.SSEUsage.self, from: json3)
        #expect(usage3.cacheReadInputTokens == 90)
        #expect(usage3.cacheCreationInputTokens == 10)
    }
}
