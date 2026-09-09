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

    private func httpTransport(_ server: FixtureMCPHTTPServer, timeout: Double = 30) -> MCPStreamableHTTPTransport {
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
        _ = await pager.search(sessionID: SessionID("s"), projectID: ProjectID("p"), query: "lookup")
        await #expect(throws: MCPToolPagerError.schemaBudgetExceeded) { try await pager.load(sessionID: SessionID("s"), toolID: toolID, schemaTokenBudget: 1) }
        await #expect(throws: MCPToolPagerError.leaseMissing) { try await pager.resolve(sessionID: SessionID("s"), providerToolID: ToolID("not-leased")) }
    }

    @Test func sameSessionHotnessBeatsProjectWarmnessWithoutOverridingLexicalMatch() async throws {
        let pager = try await pager()
        let session = SessionID("s")
        let project = ProjectID("p")
        _ = await pager.search(sessionID: session, projectID: project, query: "lookup")
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
        #expect(requests.map { $0.tools.filter { $0.rawInputSchema != nil }.count } == [0, 0, 1, 1])
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
        #expect(requests.map { $0.tools.filter { $0.rawInputSchema != nil }.count } == [0, 0, 1, 1])
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

    @Test func thousandToolCatalogStaysColdAndLeasesOnlyOneCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemas = MCPToolSchemaStore(directory: directory)
        let pager = MCPToolPager(schemaStore: schemas)
        let server = MCPServerID("bulk")
        let tools = (0..<1_000).map { index in
            let id = ToolID("bulk::tool-\(index)")
            return MCPDiscoveredTool(
                entry: MCPToolCatalogEntry(toolID: id, serverID: server, serverAlias: "bulk", upstreamName: "tool_\(index)", title: "Tool \(index)", shortDescription: "Bulk fixture \(index)", tags: ["bulk"], annotations: MCPToolAnnotations(readOnlyHint: true), schemaHash: "h\(index)", era: .modern, available: true, stale: false, cacheScope: .public, authContextID: nil, lastSeen: .now),
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            )
        }
        try await pager.replaceCatalog(serverID: server, tools: tools)
        #expect(await pager.catalogCount() == 1_000)
        #expect(await schemas.count() == 1_000)
        #expect(await pager.fullSchemaResidencyCount() == 0)

        let session = SessionID("bulk-session")
        let candidates = await pager.search(sessionID: session, projectID: ProjectID("bulk-project"), query: "bulk", maxResults: 8)
        #expect(candidates.count == 8)
        _ = try await pager.load(sessionID: session, toolID: candidates[0].toolID, schemaTokenBudget: 1_000)
        await #expect(throws: MCPToolPagerError.taskUnsupported) {
            try await pager.load(sessionID: session, toolID: candidates[1].toolID, schemaTokenBudget: 1_000)
        }
        #expect(await pager.providerDefinitions(sessionID: session).count == 1)
        await pager.finishProviderStep(sessionID: session)
        #expect(await pager.leaseCount(sessionID: session) == 0)
        #expect(await pager.fullSchemaResidencyCount() == 0)
    }

    @Test func searchByServerAliasAndFuzzyLoadResolvesProperly() async throws {
        let pager = MCPToolPager(invoker: FixtureMCP())
        let notionServer = MCPServerID("notion-server")
        let notionToolID = ToolID("notion-server::search")
        let entry = MCPToolCatalogEntry(
            toolID: notionToolID,
            serverID: notionServer,
            serverAlias: "notion",
            upstreamName: "search",
            title: "Search Workspace",
            shortDescription: "Find documents and pages",
            tags: [],
            annotations: MCPToolAnnotations(readOnlyHint: true),
            schemaHash: "notion-hash",
            era: .modern,
            available: true,
            stale: false,
            cacheScope: .public,
            authContextID: nil,
            lastSeen: .now
        )
        try await pager.replaceCatalog(serverID: notionServer, tools: [
            MCPDiscoveredTool(entry: entry, inputSchema: .object(["type": .string("object"), "properties": .object([:])]))
        ])

        let session = SessionID("s-notion")
        let project = ProjectID("p-notion")

        // 1. 仅传 query: "notion"，通过 serverAlias 命中！
        let candidates1 = await pager.search(sessionID: session, projectID: project, query: "notion")
        #expect(candidates1.map(\.toolID) == [notionToolID])

        // 2. 仅传 server: "notion"，query 为空，命中！
        let candidates2 = await pager.search(sessionID: session, projectID: project, query: "", server: "notion")
        #expect(candidates2.map(\.toolID) == [notionToolID])

        // 3. searchToolResult 支持 {"server":"notion"} 且 query 缺省
        let resultJSON = try await pager.searchToolResult(sessionID: session, projectID: project, arguments: #"{"server":"notion"}"#)
        #expect(resultJSON.contains("notion-server::search"))

        // 4. load 支持 "notion.search" 别名格式
        let lease = try await pager.load(sessionID: session, toolID: ToolID("notion.search"), schemaTokenBudget: 1000)
        #expect(lease.toolID == notionToolID)
        await pager.finishProviderStep(sessionID: session)
    }

    @Test
    func faultTolerantMCPResolutionSkipsFailingServerAndPreservesHealthyTools() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let credentials = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase")
        try await credentials.setSecret("valid-token", for: CredentialRef("valid-secret"))

        // 一个配置正常、一个凭据缺失
        let configuration = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(
                id: "healthy-stdio",
                alias: "healthy",
                transport: .stdio,
                command: "/usr/bin/true",
                environment: [MCPEnvironmentCredential(name: "TOKEN", credential: CredentialRef("valid-secret"))]
            ),
            StoredMCPServerConfiguration(
                id: "broken-http",
                alias: "broken",
                transport: .streamableHTTP,
                endpoint: "https://mcp.example.com",
                authentication: MCPAuthenticationConfiguration(kind: .bearer, credential: CredentialRef("missing-secret"))
            )
        ])

        let res = try await RuntimeConfigurationResolver.resolveMCP(
            configuration,
            credentials: credentials,
            discoverTools: false,
            faultTolerant: true
        )
        #expect(res.configurations.count == 2)
        #expect(res.configurations.first(where: { $0.serverID.rawValue == "healthy-stdio" })?.enabled == true)
        #expect(res.configurations.first(where: { $0.serverID.rawValue == "broken-http" })?.enabled == false)
    }
}

