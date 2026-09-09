import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct MCPCLITests {
    private func makeTestStores() throws -> (URL, FileCredentialStore, ConfigurationStore) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase-1234")
        let configStore = try ConfigurationStore(dataRoot: tempDir)
        return (tempDir, credStore, configStore)
    }

    @Test func mcpListEmptyWhenNoServers() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await MCPCLI.run(
            arguments: ["mcp", "list"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(output.contains("No MCP servers configured"))
        #expect(output.contains("lingxiagent mcp add"))
    }

    @Test func mcpAddStdioServerSavesConfiguration() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await MCPCLI.run(
            arguments: ["mcp", "add", "my-fetch", "--command", "/usr/local/bin/fetch-server", "--alias", "FetchServer", "--timeout", "45"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(output.contains("✓ Added MCP server 'my-fetch' (stdio)"))

        let snapshot = try await configStore.load()
        let server = try #require(snapshot.mcp.servers.first(where: { $0.id == "my-fetch" }))
        #expect(server.alias == "FetchServer")
        #expect(server.transport == .stdio)
        #expect(server.command == "/usr/local/bin/fetch-server")
        #expect(server.enabled == true)
        #expect(server.timeoutSeconds == 45)
    }

    @Test func mcpAddHTTPServerSavesConfiguration() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await MCPCLI.run(
            arguments: ["mcp", "add", "remote-hub", "--transport", "http", "--endpoint", "https://mcp.example.com/api", "--alias", "Hub"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(output.contains("✓ Added MCP server 'remote-hub' (streamableHTTP)"))

        let snapshot = try await configStore.load()
        let server = try #require(snapshot.mcp.servers.first(where: { $0.id == "remote-hub" }))
        #expect(server.alias == "Hub")
        #expect(server.transport == .streamableHTTP)
        #expect(server.endpoint == "https://mcp.example.com/api")
        #expect(server.enabled == true)
    }

    @Test func mcpListRendersTableForConfiguredServers() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "fetch", "--command", "/bin/echo"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let listOutput = try await MCPCLI.run(
            arguments: ["mcp", "list"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(listOutput.contains("Configured MCP Servers (1)"))
        #expect(listOutput.contains("fetch"))
        #expect(listOutput.contains("stdio"))
        #expect(listOutput.contains("● Enabled"))
    }

    @Test func mcpEnableAndDisableTogglesState() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "tool-srv", "--command", "/bin/cat"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        // Disable
        let disableOutput = try await MCPCLI.run(
            arguments: ["mcp", "disable", "tool-srv"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(disableOutput.contains("✓ MCP server 'tool-srv' disabled"))

        var snapshot = try await configStore.load()
        #expect(snapshot.mcp.servers.first?.enabled == false)

        // Enable
        let enableOutput = try await MCPCLI.run(
            arguments: ["mcp", "enable", "tool-srv"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(enableOutput.contains("✓ MCP server 'tool-srv' enabled"))

        snapshot = try await configStore.load()
        #expect(snapshot.mcp.servers.first?.enabled == true)
    }

    @Test func mcpAuthWithBearerTokenStoresInVault() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "http-srv", "--transport", "http", "--endpoint", "https://api.mcp.com"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let authOutput = try await MCPCLI.run(
            arguments: ["mcp", "auth", "http-srv", "--token", "secret-token-abc-123"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(authOutput.contains("Successfully configured authentication for MCP server 'http-srv'"))
        #expect(authOutput.contains("bearer"))

        // Verify stored in credentialStore
        let stored = try await credStore.secret(for: CredentialRef("mcp-http-srv-secret"))
        #expect(stored == "secret-token-abc-123")

        let snapshot = try await configStore.load()
        let server = try #require(snapshot.mcp.servers.first)
        #expect(server.authentication.kind == .bearer)
        #expect(server.authentication.credential?.rawValue == "mcp-http-srv-secret")
    }

    @Test func mcpAuthWithCustomHeaderStoresInVault() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "custom-auth-srv", "--transport", "http", "--endpoint", "https://api.mcp.com"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let authOutput = try await MCPCLI.run(
            arguments: ["mcp", "auth", "custom-auth-srv", "--header", "X-Custom-Key", "--value", "custom-val-777"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(authOutput.contains("header"))
        #expect(authOutput.contains("X-Custom-Key"))

        let stored = try await credStore.secret(for: CredentialRef("mcp-custom-auth-srv-secret"))
        #expect(stored == "custom-val-777")

        let snapshot = try await configStore.load()
        let server = try #require(snapshot.mcp.servers.first)
        #expect(server.authentication.kind == .header)
        #expect(server.authentication.headerName == "X-Custom-Key")
    }

    @Test func mcpStatusForDisabledServerShowsDisabled() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "srv1", "--command", "/bin/echo"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        _ = try await MCPCLI.run(
            arguments: ["mcp", "disable", "srv1"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let statusOutput = try await MCPCLI.run(
            arguments: ["mcp", "status", "srv1"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(statusOutput.contains("MCP Server Status: srv1"))
        #expect(statusOutput.contains("Disabled"))
    }

    @Test func mcpStatusOverviewShowsSummaryTable() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "srvA", "--command", "/bin/echo"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let statusOutput = try await MCPCLI.run(
            arguments: ["mcp", "status"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(statusOutput.contains("MCP Servers Health & Discovery"))
        #expect(statusOutput.contains("srvA"))
    }

    @Test func mcpRemoveDeletesServer() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "to-remove", "--command", "/bin/echo"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let removeOutput = try await MCPCLI.run(
            arguments: ["mcp", "remove", "to-remove"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(removeOutput.contains("✓ Removed MCP server 'to-remove'"))

        let snapshot = try await configStore.load()
        #expect(snapshot.mcp.servers.isEmpty)
    }

    @Test func mcpHelpRendersUsage() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let help = try await MCPCLI.run(
            arguments: ["mcp", "help"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(help.contains("MCP Server Management Commands"))
        #expect(help.contains("lingxiagent mcp list"))
        #expect(help.contains("lingxiagent mcp status"))
        #expect(help.contains("lingxiagent mcp enable"))
        #expect(help.contains("lingxiagent mcp disable"))
        #expect(help.contains("lingxiagent mcp login"))
        #expect(help.contains("lingxiagent mcp auth"))
    }

    @Test func mcpLoginRejectsStdioTransport() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await MCPCLI.run(
            arguments: ["mcp", "add", "local-cli", "--command", "/bin/echo"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        let loginOutput = try await MCPCLI.run(
            arguments: ["mcp", "login", "local-cli"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(loginOutput.contains("Error: MCP OAuth login is only supported for streamableHTTP"))
    }

    @Test func loopbackOAuthServerBindsAndClosesCleanly() async throws {
        let server = try LoopbackOAuthServer(preferredPort: 54329)
        #expect(server.port > 0)
        server.closeServer()
    }
}
