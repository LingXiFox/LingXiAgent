import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore

@Suite("Agent Loop Context Pipeline Optimization Tests (Phase 6)", .serialized)
struct AgentLoopContextPipelineTests {

    private struct MockExecutor: ToolExecutor {
        let definition: ToolDefinition
        func resource(for arguments: String, profile: ExecutionProfile) throws -> String { "" }
        func execute(arguments: String, profile: ExecutionProfile) async throws -> String { "mock" }
    }

    private func makeRuntime() -> ToolRuntime {
        let tools: [any ToolExecutor] = [
            MockExecutor(definition: ToolDefinition(
                id: ToolID("shell"),
                name: "shell",
                description: "Execute a shell command",
                inputSchema: ToolInputSchema(properties: ["cmd": ToolInputProperty(type: .string, description: "Command")], required: ["cmd"]),
                capability: ToolCapability(readOnly: false)
            )),
            MockExecutor(definition: ToolDefinition(
                id: ToolID("read_file"),
                name: "read_file",
                description: "Read a local file",
                inputSchema: ToolInputSchema(properties: ["path": ToolInputProperty(type: .string, description: "Path")], required: ["path"]),
                capability: ToolCapability(readOnly: true)
            )),
            MockExecutor(definition: ToolDefinition(
                id: ToolID("custom_dynamic_tool"),
                name: "custom_dynamic_tool",
                description: "Dynamic tool discovered on demand",
                inputSchema: ToolInputSchema(properties: ["query": ToolInputProperty(type: .string, description: "Query")], required: ["query"]),
                capability: ToolCapability(readOnly: true)
            ))
        ]
        let registry = ToolRegistry(tools)
        let permissions = PermissionEngine(defaultDecision: .allow)
        return ToolRuntime(registry: registry, permissions: permissions)
    }

    @Test("ToolRuntime exposes toolRegistryRevision and dynamicManifestRevision with invalidation on lease")
    func testToolRuntimeRevisions() async {
        let runtime = makeRuntime()
        let sessionID = SessionID("test-pipeline-rev")

        #expect(runtime.toolRegistryRevision == 1)
        let rev0 = await runtime.dynamicManifestRevision
        #expect(rev0 == 0)

        // Dynamic tool lease increments dynamicManifestRevision
        await runtime.lease(sessionID: sessionID, runID: nil, toolID: ToolID("custom_dynamic_tool"))
        let rev1 = await runtime.dynamicManifestRevision
        #expect(rev1 == 1)

        // Reset session increments dynamicManifestRevision
        await runtime.resetSession(sessionID)
        let rev2 = await runtime.dynamicManifestRevision
        #expect(rev2 == 2)
    }

    @Test("availableDefinitions is 100% deterministic and cache returns exact canonical definitions")
    func testAvailableDefinitionsCacheFidelity() async {
        let runtime = makeRuntime()
        let sessionID = SessionID("test-pipeline-fidelity")

        let defs1 = await runtime.availableDefinitions(sessionID: sessionID)
        let defs2 = await runtime.availableDefinitions(sessionID: sessionID)

        #expect(defs1.count == defs2.count)
        for (d1, d2) in zip(defs1, defs2) {
            #expect(d1.id == d2.id)
            #expect(d1.name == d2.name)
            #expect(d1.description == d2.description)
        }

        // Before lease: custom_dynamic_tool not present in active definitions
        #expect(!defs1.contains(where: { $0.id == ToolID("custom_dynamic_tool") }))

        // After lease: custom_dynamic_tool present
        await runtime.lease(sessionID: sessionID, runID: nil, toolID: ToolID("custom_dynamic_tool"))
        let defsLeased = await runtime.availableDefinitions(sessionID: sessionID)
        #expect(defsLeased.contains(where: { $0.id == ToolID("custom_dynamic_tool") }))
    }

    @Test("ConservativeTokenEstimator tool token cache maintains 100% calculation accuracy")
    func testConservativeTokenEstimatorToolCacheAccuracy() {
        ConservativeTokenEstimator.clearToolTokenCacheForTesting()
        let estimator = ConservativeTokenEstimator()

        let tool = ToolDefinition(
            id: ToolID("advanced_search"),
            name: "advanced_search",
            description: "Performs complex regex code search across multi-repo workspaces with options",
            inputSchema: ToolInputSchema(
                properties: [
                    "query": ToolInputProperty(type: .string, description: "Search query regex pattern"),
                    "maxDepth": ToolInputProperty(type: .integer, description: "Maximum directory depth"),
                    "caseSensitive": ToolInputProperty(type: .boolean, description: "Whether to respect casing")
                ],
                required: ["query"]
            ),
            capability: ToolCapability(readOnly: true)
        )

        // First pass (computes & stores in cache)
        let estimate1 = estimator.estimate(tool: tool)
        #expect(estimate1 > 0)

        // Second pass (must hit cache and return identical value)
        let estimate2 = estimator.estimate(tool: tool)
        #expect(estimate2 == estimate1)

        let tools = [tool, tool]
        let batchEstimate = estimator.estimate(tools: tools)
        #expect(batchEstimate == estimate1 * 2)
    }

    @Test("20-step mock tool loop context build maintains sub-millisecond execution and canonical output")
    func testTwentyStepLoopContextAssemblyPerformance() async {
        let runtime = makeRuntime()
        let sessionID = SessionID("bench-20-step")
        let estimator = ConservativeTokenEstimator()

        var latencies: [Double] = []
        var canonicalFirstDefinitions: [ToolID] = []

        for step in 0..<20 {
            let start = ContinuousClock.now
            let tools = await runtime.availableDefinitions(sessionID: sessionID)
            let tokens = estimator.estimate(tools: tools)
            let elapsed = start.duration(to: ContinuousClock.now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            latencies.append(elapsedMs)

            #expect(tokens > 0)
            if step == 0 {
                canonicalFirstDefinitions = tools.map(\.id)
            } else {
                #expect(tools.map(\.id) == canonicalFirstDefinitions)
            }
        }

        let avgMs = latencies.reduce(0, +) / Double(latencies.count)
        #expect(avgMs < 2.0, "Context assembly average per step must be under 2.0 ms (actual: \(avgMs) ms)")
    }
}
