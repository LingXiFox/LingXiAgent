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
}
