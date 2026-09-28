import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient
@testable import LingXiApplication

@Suite(.serialized)
struct NonProviderLatencyRepairTests {
    @Test func deferredMCPDiscoveryDoesNotProbeBeforeHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = try FileCredentialStore(dataRoot: root, isMemoryOnly: true)
        let slowServer = PortableFixture.sleep(2)
        let configuration = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(id: "slow", alias: "slow", transport: .stdio, command: slowServer.command, arguments: slowServer.arguments, timeoutSeconds: 0.1)
        ])
        let start = ContinuousClock.now
        let resolution = try await RuntimeConfigurationResolver.resolveMCP(configuration, credentials: credentials, discoverTools: false, faultTolerant: true)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await resolution.pager.serverStatus(for: MCPServerID("slow")) == nil)
        try await resolution.discover()
        guard case .error = await resolution.pager.serverStatus(for: MCPServerID("slow")) else {
            Issue.record("Deferred discovery should record the actual timeout")
            return
        }
    }

    @Test func mcpStdioTimeoutAndCancellationDoNotWaitForServerExit() async throws {
        let sleepServer = PortableFixture.sleep(5)
        let transport = MCPStdioTransport(configuration: MCPServerConfiguration(serverID: MCPServerID("sleep"), alias: "sleep", transport: .stdio, command: sleepServer.command, arguments: sleepServer.arguments, timeoutSeconds: 0.1))
        let start = ContinuousClock.now
        do {
            _ = try await transport.listTools()
            Issue.record("Expected timeout")
        } catch let error as CoreError {
            #expect(error.code == .commandTimedOut)
        }
        #expect(ContinuousClock.now - start < .seconds(1))

        let task = Task { try await transport.listTools() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func strictMCPDiscoveryStillThrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = try FileCredentialStore(dataRoot: root, isMemoryOnly: true)
        let configuration = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(id: "missing", alias: "missing", transport: .stdio, command: "/nonexistent/lingxi-fixture")
        ])
        await #expect(throws: CoreError.self) {
            _ = try await RuntimeConfigurationResolver.resolveMCP(configuration, credentials: credentials)
        }
    }

    @Test func mcpStdioDrainsLargeDiagnosticsAndCompletesHandshake() async throws {
        let markerDirectory = ProcessInfo.processInfo.environment["CI"] == nil
            ? FileManager.default.temporaryDirectory
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test-results-artifact")
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let marker = markerDirectory.appendingPathComponent("lingxi-mcp-fixture-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: marker) }
        // Reviewed fixture: flood stderr past the pipe buffer, then answer initialize/tools/list.
        // awk was the original interpreter and only exists on a POSIX userland; python speaks the
        // same JSON as the transport instead of regex-scraping an id out of the request line.
        let script = """
        import json, sys
        def mark(phase):
            with open(sys.argv[1], "a", encoding="ascii") as trace:
                trace.write(phase + "\\n")
        mark("started")
        for i in range(20000):
            sys.stderr.write("fixture diagnostic output\\n")
            if i == 10000:
                mark("diagnostics_halfway")
        sys.stderr.flush()
        mark("diagnostics_flushed")
        # Iterating sys.stdin read-aheads in block sizes, which on a pipe of short requests
        # means the first line is never returned until the peer closes. readline() hands over
        # each line as it arrives, which is what a request/response fixture needs.
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            try:
                request = json.loads(line)
            except ValueError:
                continue
            if "id" not in request:
                continue
            mark("request_received")
            response = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"tools": []}})
            sys.stdout.buffer.write((response + "\\n").encode("utf-8"))
            sys.stdout.buffer.flush()
            mark("reply_flushed")
        """
        let server = PortableFixture.python(script)
        let transport = MCPStdioTransport(configuration: MCPServerConfiguration(serverID: MCPServerID("fixture"), alias: "fixture", transport: .stdio, command: server.command, arguments: server.arguments + [marker.path], timeoutSeconds: 15))
        do {
            #expect(try await transport.listTools().isEmpty)
        } catch {
            let phases = (try? String(contentsOf: marker, encoding: .utf8)) ?? "marker missing"
            Issue.record("MCP fixture phases: \(phases); transport: \(error)")
        }
    }

    @Test func sessionPaginationTraversesEverySessionWithoutRepeatingFirstPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(workspaceRoot: WorkspaceRoot(path: root.path))
        await host.start()
        let transport = InProcessTransport(service: host)
        let client = SessionDomainClient(transport: transport)
        for _ in 0..<7 { _ = try await client.create() }
        var cursor: String?
        var ids: [SessionID] = []
        for _ in 0..<4 {
            let page = try await client.list(page: PageRequest(cursor: cursor, limit: 2))
            ids += page.items.map(\.sessionID)
            cursor = page.nextCursor
            if !page.hasMore { break }
        }
        #expect(ids.count == 7)
        #expect(Set(ids).count == 7)
        #expect(try await client.listAll().map(\.sessionID) == ids)
        await host.shutdown()
    }
}
