import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor FixtureMCP: MCPToolInvoker {
    func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String {
        guard serverID == MCPServerID("fixture-server") else { throw CoreError(code: .mcpServerUnavailable, message: "unknown fixture") }
        switch toolName {
        case "lookup_anchor": return arguments.contains("phase12") ? "MCPAnchor-729" : "missing"
        case "echo": return arguments
        case "large_result": return String(repeating: "x", count: 32_000)
        case "error_tool": throw CoreError(code: .toolExecutionFailed, message: "fixture error")
        default: throw CoreError(code: .toolNotFound, message: toolName)
        }
    }
}

struct MCPRuntimeTests {
    private let serverID = MCPServerID("fixture-server")
    private let toolID = ToolID("fixture-server::lookup_anchor")
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["key": .object(["type": .string("string")])]),
        "required": .array([.string("key")]),
        "additionalProperties": .bool(false),
    ])

    private func pager() async throws -> MCPToolPager {
        let pager = MCPToolPager(invoker: FixtureMCP())
        let entry = MCPToolCatalogEntry(toolID: toolID, serverID: serverID, serverAlias: "fixture", upstreamName: "lookup_anchor", title: "Lookup anchor", shortDescription: "Retrieve a test anchor by key.", tags: ["fixture", "lookup"], annotations: MCPToolAnnotations(readOnlyHint: true), schemaHash: "h1", era: .modern, available: true, stale: false, cacheScope: .public, authContextID: nil, lastSeen: .now)
        try await pager.replaceCatalog(serverID: serverID, tools: [MCPDiscoveredTool(entry: entry, inputSchema: schema)])
        return pager
    }

    private func httpTransport(_ server: FixtureMCPHTTPServer, timeout: Double = 10) -> MCPStreamableHTTPTransport {
        MCPStreamableHTTPTransport(configuration: MCPServerConfiguration(serverID: serverID, alias: "fixture", transport: .streamableHTTP, endpoint: server.endpoint, timeoutSeconds: timeout))
    }

    @Test func catalogSearchHasNoSchemaAndLeaseIsEphemeral() async throws {
        let pager = try await pager()
        let session = SessionID("s")
        let project = ProjectID("p")
        #expect(await pager.fullSchemaResidencyCount() == 0)
        let candidates = await pager.search(sessionID: session, projectID: project, query: "fixture lookup")
        #expect(candidates.map(\.toolID) == [toolID])
        let lease = try await pager.load(sessionID: session, toolID: toolID, schemaTokenBudget: 1_000)
        #expect(await pager.providerDefinitions(sessionID: session).count == 1)
        _ = try await pager.markUsed(sessionID: session, providerToolID: ToolID(lease.providerName), projectID: project)
        await pager.finishProviderStep(sessionID: session)
        #expect(await pager.providerDefinitions(sessionID: session).isEmpty)
        #expect(await pager.fullSchemaResidencyCount() == 0)
    }

    @Test func schemaBudgetAndLeaseGuardRejectUnsafeCalls() async throws {
        let pager = try await pager()
        await #expect(throws: MCPToolPagerError.schemaBudgetExceeded) { try await pager.load(sessionID: SessionID("s"), toolID: toolID, schemaTokenBudget: 1) }
        await #expect(throws: MCPToolPagerError.leaseMissing) { try await pager.resolve(sessionID: SessionID("s"), providerToolID: ToolID("not-leased")) }
    }

    @Test func sameSessionHotnessBeatsProjectWarmnessWithoutOverridingLexicalMatch() async throws {
        let pager = try await pager()
        let session = SessionID("s")
        let project = ProjectID("p")
        let lease = try await pager.load(sessionID: session, toolID: toolID, schemaTokenBudget: 1_000)
        _ = try await pager.markUsed(sessionID: session, providerToolID: ToolID(lease.providerName), projectID: project)
        await pager.finishProviderStep(sessionID: session)
        #expect(await pager.search(sessionID: session, projectID: project, query: "lookup").first?.temperature == "hot")
        #expect(await pager.search(sessionID: SessionID("other"), projectID: project, query: "lookup").first?.temperature == "warm")
    }

    @Test func offlineToolLoopPagesExactlyOneSchemaThenRevokesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pager = try await pager()
        let alias = ProviderToolNameCodec().encode(serverAlias: "fixture", upstreamName: "lookup_anchor", toolID: toolID)
        let search = ToolCall(callID: ToolCallID("search"), toolID: ToolID("search_tools"), arguments: #"{"query":"fixture lookup"}"#)
        let load = ToolCall(callID: ToolCallID("load"), toolID: ToolID("load_tool"), arguments: #"{"tool_id":"fixture-server::lookup_anchor"}"#)
        let lookup = ToolCall(callID: ToolCallID("lookup"), toolID: ToolID(alias), arguments: #"{"key":"phase12"}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(search), .completed(.toolCalls)],
            [.toolCallCompleted(load), .completed(.toolCalls)],
            [.toolCallCompleted(lookup), .completed(.toolCalls)],
            [.textDelta("MCPAnchor-729"), .completed(.stop)],
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, mcpPager: pager)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let session = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: session, content: "find marker") {}
        let requests = provider.recorder.requests
        #expect(requests.count == 4)
        #expect(requests.map { $0.tools.filter { $0.rawInputSchema != nil }.count } == [0, 0, 1, 0])
        #expect(requests[2].tools.first(where: { $0.rawInputSchema != nil })?.id == ToolID(alias))
        #expect((try await client.session(session)).messages.last?.content == "MCPAnchor-729")
    }

    @Test func httpFixtureDiscoversPaginatedCatalogSupportsSSEAndGet() async throws {
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        let transport = httpTransport(server)
        let tools = try await transport.listTools()
        #expect(tools.map(\.entry.upstreamName) == ["lookup_anchor", "echo", "large_result", "slow_tool", "error_tool"])
        #expect(try await transport.call(serverID: serverID, toolName: "lookup_anchor", arguments: #"{"key":"phase12"}"#) == "MCPAnchor-729")
        #expect(try await transport.call(serverID: serverID, toolName: "echo", arguments: #"{"value":"streamed"}"#) == "streamed")
        #expect(try await transport.get() == 204)
    }

    @Test func httpOfflineToolLoopUsesConnectionManagerAndRevokesLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        let transport = httpTransport(server)
        let connections = MCPConnectionManager()
        await connections.register(transport, for: serverID)
        let pager = MCPToolPager(invoker: connections)
        try await pager.replaceCatalog(serverID: serverID, tools: try await transport.listTools())
        let alias = ProviderToolNameCodec().encode(serverAlias: "fixture", upstreamName: "lookup_anchor", toolID: toolID)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(ToolCall(callID: ToolCallID("search"), toolID: ToolID("search_tools"), arguments: #"{"query":"phase12 anchor"}"#)), .completed(.toolCalls)],
            [.toolCallCompleted(ToolCall(callID: ToolCallID("load"), toolID: ToolID("load_tool"), arguments: #"{"tool_id":"fixture-server::lookup_anchor"}"#)), .completed(.toolCalls)],
            [.toolCallCompleted(ToolCall(callID: ToolCallID("lookup"), toolID: ToolID(alias), arguments: #"{"key":"phase12"}"#)), .completed(.toolCalls)],
            [.textDelta("MCPAnchor-729"), .completed(.stop)],
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, mcpPager: pager)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let session = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: session, content: "find phase12 marker") {}
        let requests = provider.recorder.requests
        #expect(requests.map { $0.tools.filter { $0.rawInputSchema != nil }.count } == [0, 0, 1, 0])
        #expect((try await client.session(session)).messages.last?.content == "MCPAnchor-729")
    }

    @Test func httpFixtureRejectsOriginAndSlowCallTimesOut() async throws {
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        var request = URLRequest(url: server.endpoint)
        request.httpMethod = "POST"
        request.setValue("https://invalid.example", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        let transport = httpTransport(server, timeout: 0.05)
        await #expect(throws: CoreError.self) { try await transport.call(serverID: serverID, toolName: "slow_tool", arguments: "{}") }
    }
}
