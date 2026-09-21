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
        // Reviewed fixture: flood stderr past the pipe buffer, then answer initialize/tools/list.
        // awk was the original interpreter and only exists on a POSIX userland; python speaks the
        // same JSON as the transport instead of regex-scraping an id out of the request line.
        let script = """
        import json, sys
        for _ in range(20000):
            sys.stderr.write("fixture diagnostic output\\n")
        sys.stderr.flush()
        for line in sys.stdin:
            try:
                request = json.loads(line)
            except ValueError:
                continue
            if "id" not in request:
                continue
            response = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"tools": []}})
            sys.stdout.buffer.write((response + "\\n").encode("utf-8"))
            sys.stdout.buffer.flush()
        """
        let server = PortableFixture.python(script)
        let transport = MCPStdioTransport(configuration: MCPServerConfiguration(serverID: MCPServerID("fixture"), alias: "fixture", transport: .stdio, command: server.command, arguments: server.arguments, timeoutSeconds: 2))
        #expect(try await transport.listTools().isEmpty)
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
