import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite struct ProviderWorkloadAuditTests {
    @Test func defaultExposureContainsOnlyAlwaysOnCoreTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try WorkspaceRoot(path: root.path)
        let registry = ToolRegistry.builtin(workspace: workspace)
        let permissions = PermissionEngine()
        let subagentService = SubagentToolService()
        let toolRuntime = ToolRuntime(
            registry: registry,
            permissions: permissions,
            subagents: subagentService
        )

        let exposed = await toolRuntime.availableDefinitions()
        let exposedIDs = Set(exposed.map(\.id.rawValue))

        // Core tools must be present
        #expect(exposedIDs.contains("shell"))
        #expect(exposedIDs.contains("read_file"))
        #expect(exposedIDs.contains("write_file"))
        #expect(exposedIDs.contains("edit_file"))
        #expect(exposedIDs.contains("apply_patch"))
        #expect(exposedIDs.contains("list_directory"))
        #expect(exposedIDs.contains("grep"))
        #expect(exposedIDs.contains("glob"))
        #expect(exposedIDs.contains("web_search"))
        #expect(exposedIDs.contains("web_fetch"))
        #expect(exposedIDs.contains("search_tools"))
        #expect(exposedIDs.contains("load_tool"))

        // Specialized tools must NOT be present in always-on set
        #expect(!exposedIDs.contains("git"))
        #expect(!exposedIDs.contains("process"))
        #expect(!exposedIDs.contains("subagent"))
        #expect(!exposedIDs.contains("symbol_lookup"))
        #expect(!exposedIDs.contains("find_references"))
        #expect(!exposedIDs.contains("dependency_query"))

        #expect(exposed.count == 12)
    }

    @Test func specializedToolsCanBeDiscoveredViaSearchAndDynamicallyLeased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try WorkspaceRoot(path: root.path)
        let registry = ToolRegistry.builtin(workspace: workspace)
        let permissions = PermissionEngine()
        let subagentService = SubagentToolService()
        let toolRuntime = ToolRuntime(
            registry: registry,
            permissions: permissions,
            subagents: subagentService
        )

        let sessionID = SessionID("audit-session")

        // Before lease: git and subagent not in availableDefinitions
        let initialTools = await toolRuntime.availableDefinitions(sessionID: sessionID)
        #expect(!initialTools.map(\.id.rawValue).contains("git"))
        #expect(!initialTools.map(\.id.rawValue).contains("subagent"))

        // Search for git
        let searchCall = ToolCall(callID: ToolCallID("s1"), toolID: ToolID("search_tools"), arguments: #"{"query":"git"}"#)
        let searchOutcome = await toolRuntime.execute(searchCall, sessionID: sessionID)
        #expect(searchOutcome.success)
        #expect(searchOutcome.content.contains("builtin.git"))
        #expect(searchOutcome.content.contains("git"))

        // Load git
        let loadCall = ToolCall(callID: ToolCallID("l1"), toolID: ToolID("load_tool"), arguments: #"{"tool_id":"git"}"#)
        let loadOutcome = await toolRuntime.execute(loadCall, sessionID: sessionID)
        #expect(loadOutcome.success)
        #expect(loadOutcome.content.contains("leased"))

        // After lease: git is now in availableDefinitions for this session!
        let leasedTools = await toolRuntime.availableDefinitions(sessionID: sessionID)
        #expect(leasedTools.map(\.id.rawValue).contains("git"))
        #expect(!leasedTools.map(\.id.rawValue).contains("subagent"))

        // Another session does not have git (session isolation)
        let otherSessionTools = await toolRuntime.availableDefinitions(sessionID: SessionID("other-session"))
        #expect(!otherSessionTools.map(\.id.rawValue).contains("git"))

        // Search and load subagent
        let loadSubagentCall = ToolCall(callID: ToolCallID("l2"), toolID: ToolID("load_tool"), arguments: #"{"tool_id":"subagent"}"#)
        let loadSubagentOutcome = await toolRuntime.execute(loadSubagentCall, sessionID: sessionID)
        #expect(loadSubagentOutcome.success)
        #expect(loadSubagentOutcome.content.contains("leased"))

        let toolsWithSubagent = await toolRuntime.availableDefinitions(sessionID: sessionID)
        #expect(toolsWithSubagent.map(\.id.rawValue).contains("subagent"))
        #expect(toolsWithSubagent.map(\.id.rawValue).contains("git"))

        // Reset session clears dynamic leases
        await toolRuntime.resetSession(sessionID)
        let resetTools = await toolRuntime.availableDefinitions(sessionID: sessionID)
        #expect(!resetTools.map(\.id.rawValue).contains("git"))
        #expect(!resetTools.map(\.id.rawValue).contains("subagent"))
    }

    @Test func providerCallTraceCapturesAllRequiredFieldsAndAnswersKeyAudits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class AuditProvider: ModelProvider, @unchecked Sendable {
            var capturedRequests: [ModelRequest] = []
            func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
                capturedRequests.append(request)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.providerRequestID("provider-hello-1"))
                    continuation.yield(.started)
                    continuation.yield(.textDelta("你好！有什么我可以帮你的？"))
                    continuation.yield(.usage(ModelUsage(inputTokens: 742, outputTokens: 15)))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                }
            }
        }

        let provider = AuditProvider()
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(
                provider: provider,
                modelID: ModelID("deepseek-v4-flash"),
                contextProfile: ModelContextProfile(contextWindowTokens: 128_000)
            ),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

        // Send "你好"
        let stream = try await client.sendMessage(sessionID: sessionID, content: "你好")
        for try await _ in stream {}

        // 1. How many provider requests per user turn?
        #expect(provider.capturedRequests.count == 1)

        // 2. What were the tool schemas sent?
        let req = provider.capturedRequests[0]
        #expect(req.tools.count == 12) // Stable core tools only, no subagent or specialized bloat
        #expect(!req.tools.map(\.id.rawValue).contains("subagent"))
        let session = try await client.session(sessionID)

        // 3. ProviderCallTrace captured via performanceStore
        let calls = await host.performanceStoreRef.providerCalls(for: sessionID)
        #expect(calls.count == 1)

        let trace = calls[0]
        #expect(trace.sessionID == sessionID)
        #expect(trace.userTurnID == session.messages[0].id)
        #expect(trace.providerRequestID == "provider-hello-1")
        #expect(trace.sequence == 1)
        #expect(trace.reason == "initial_turn_prompt")
        #expect(trace.model == "deepseek-v4-flash")
        #expect(trace.actualUsage?.inputTokens == 742)
        #expect(trace.toolCount == 12)
        #expect(trace.toolSchemaTokens < 1200)
        #expect(trace.providerFramingTokens == 256)
        #expect(trace.retryAttempt == 0)
        #expect(trace.cacheTelemetry?.stablePrefixTokens == trace.systemPinnedTokens + trace.toolSchemaTokens)
        #expect(trace.cacheTelemetry?.epoch?.hash.isEmpty == false)
        #expect(trace.cacheTelemetry?.cacheReadTokens == nil)

        // 4. Trace can explain its triggering reason and correlation
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[1].role == .assistant)
    }

    @Test func simpleCodingPromptProducesSingleDirectInferenceAndZeroSubagents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class CodingProvider: ModelProvider, @unchecked Sendable {
            var capturedRequests: [ModelRequest] = []
            func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
                capturedRequests.append(request)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.started)
                    continuation.yield(.textDelta("这是快速排序的实现：\n```swift\nfunc quicksort...```"))
                    continuation.yield(.usage(ModelUsage(inputTokens: 810, outputTokens: 85)))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                }
            }
        }

        let provider = CodingProvider()
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(
                provider: provider,
                modelID: ModelID("deepseek-v4-flash"),
                contextProfile: ModelContextProfile(contextWindowTokens: 128_000)
            ),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

        // User asks for quicksort
        let stream = try await client.sendMessage(sessionID: sessionID, content: "帮我写一个快速排序算法")
        for try await _ in stream {}

        // 1. Exactly 1 request per turn
        #expect(provider.capturedRequests.count == 1)

        // 2. Tools exposed: only core tools, subagent NOT exposed
        let req = provider.capturedRequests[0]
        #expect(req.tools.count == 12)
        #expect(!req.tools.map(\.id.rawValue).contains("subagent"))

        // 3. 0 subagent sessions or runs spawned
        let childSessions = try await client.listChildSessions(sessionID)
        #expect(childSessions.isEmpty)
        let tree = try await client.getAgentTree(sessionID)
        #expect(tree.children.isEmpty)

        // 4. ProviderCallTrace recorded
        let traces = await host.performanceStoreRef.providerCalls(for: sessionID)
        #expect(traces.count == 1)
        #expect(traces[0].reason == "initial_turn_prompt")
        #expect(traces[0].actualUsage?.inputTokens == 810)
        #expect(traces[0].retryAttempt == 0)
    }

    @Test func toolSchemaCostIsAccuratelyEstimatedAndMatchesWireFraming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try WorkspaceRoot(path: root.path)
        let registry = ToolRegistry.builtin(workspace: workspace)
        let permissions = PermissionEngine()
        let toolRuntime = ToolRuntime(registry: registry, permissions: permissions)

        let coreTools = await toolRuntime.availableDefinitions()
        let estimator = ConservativeTokenEstimator()

        let estimatedTokens = estimator.estimate(tools: coreTools)

        // Generate actual wire payload
        let req = ModelRequest(
            model: ModelID("deepseek-v4-flash"),
            messages: [ModelMessage(role: .user, content: "test")],
            tools: coreTools
        )
        let wireBody = try OpenAICompatibleProvider.makeRequestBody(req)
        let wireBytes = wireBody.count

        // Real tokenizers average ~3.5 bytes/token for JSON.
        // The estimated tokens should be tightly within reasonable bounds of wire bytes / 3.5
        let wireTokenRange = (wireBytes / 5)...(wireBytes / 3)
        #expect(wireTokenRange.contains(estimatedTokens))
    }
}
