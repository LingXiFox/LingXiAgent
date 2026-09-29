import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("Settings editing: providers.json, mcp.json, worktrees", .serialized)
struct ConfigurationEditingAndWorktreeTests {
    private struct Fixture {
        let root: URL
        let host: CoreHost
        let store: ConfigurationStore
        let credentials: FileCredentialStore
    }

    private func fixture(workspace: URL? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let host = try CoreHost(workspaceRoot: try workspace.map { try WorkspaceRoot(path: $0.path) },
                                configurationStore: store, credentialStore: credentials)
        return Fixture(root: root, host: host, store: store, credentials: credentials)
    }

    private func providerRequest(apiKey: SecretUpdate) -> SaveProviderConfigurationRequest {
        SaveProviderConfigurationRequest(
            providerID: "relay", name: "公司中转", adapter: "openai-compatible",
            baseURL: "https://relay.example.com/v1", apiKeyHeader: "Authorization",
            headers: ["x-team": "lingxi"], apiKey: apiKey,
            models: [ProviderModelConfigurationDetail(modelID: "fast-1", name: "Fast", contextWindow: 128_000,
                                                      maxOutputTokens: 8_000, reasoning: true, maxRetries: 3)])
    }

    @Test("A provider saves with its key in the vault, never in the file")
    func providerRoundTrip() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let saved = try await f.host.saveProviderConfiguration(
            envelope: CommandEnvelope(payload: providerRequest(apiKey: .replace("sk-test-123")))).result
        #expect(saved?.apiKey == .vault)
        #expect(saved?.models.first?.maxRetries == 3)

        let file = try String(contentsOf: f.root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!file.contains("sk-test-123"))
        #expect(file.contains("{vault:provider-relay-key}"))
        #expect(try await f.credentials.secret(for: CredentialRef("provider-relay-key")) == "sk-test-123")

        // `keep` and `models: nil` leave the stored key and models alone.
        var rename = providerRequest(apiKey: .keep)
        rename.name = "中转 2"
        rename.models = nil
        let renamed = try await f.host.saveProviderConfiguration(envelope: CommandEnvelope(payload: rename)).result
        #expect(renamed?.name == "中转 2")
        #expect(renamed?.apiKey == .vault)
        #expect(renamed?.models.map(\.modelID) == ["fast-1"])

        _ = try await f.host.deleteProviderConfiguration(
            envelope: CommandEnvelope(payload: DeleteProviderConfigurationRequest(providerID: "relay")))
        #expect(try await f.store.load().providers.providers["relay"] == nil)
        #expect(try await f.credentials.secret(for: CredentialRef("provider-relay-key")) == nil)
    }

    @Test("Invalid provider input is rejected before anything is written")
    func providerValidation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var insecure = providerRequest(apiKey: .keep)
        insecure.baseURL = "http://relay.example.com/v1"
        await #expect(throws: (any Error).self) {
            _ = try await f.host.saveProviderConfiguration(envelope: CommandEnvelope(payload: insecure))
        }
        var empty = providerRequest(apiKey: .keep)
        empty.models = []
        await #expect(throws: (any Error).self) {
            _ = try await f.host.saveProviderConfiguration(envelope: CommandEnvelope(payload: empty))
        }
        #expect(try await f.store.load().providers.providers["relay"] == nil)
    }

    @Test("An MCP server resolves its command and keeps env values in the vault")
    func mcpRoundTrip() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let request = SaveMCPServerRequest(
            id: "gitmcp", alias: "Git", transport: .stdio, command: "git", arguments: ["--version", ""],
            environment: [MCPEnvironmentVariableUpdate(name: "GITHUB_TOKEN", value: .replace("ghp-secret"))])
        let saved = try await f.host.saveMCPServerConfiguration(envelope: CommandEnvelope(payload: request)).result
        #expect(saved?.command?.hasPrefix("/") == true)
        #expect(saved?.arguments == ["--version"])
        #expect(saved?.environment == [MCPEnvironmentVariableDetail(name: "GITHUB_TOKEN", value: .vault)])
        let file = try String(contentsOf: f.root.appendingPathComponent("mcp.json"), encoding: .utf8)
        #expect(!file.contains("ghp-secret"))

        // Dropping a variable removes its secret.
        var trimmed = request
        trimmed.environment = []
        _ = try await f.host.saveMCPServerConfiguration(envelope: CommandEnvelope(payload: trimmed))
        #expect(try await f.credentials.secret(for: CredentialRef("mcp-gitmcp-env-GITHUB_TOKEN")) == nil)

        let listed = try await f.host.listMCPServerConfigurations(envelope: QueryEnvelope(payload: VoidResult())).payload
        #expect(listed.map(\.id) == ["gitmcp"])
        _ = try await f.host.deleteMCPServerConfiguration(envelope: CommandEnvelope(payload: DeleteMCPServerRequest(id: "gitmcp")))
        #expect(try await f.store.load().mcp.servers.isEmpty)
    }

    @Test("A worktree isolates changes and applies them to the main checkout as staged edits")
    func worktreeLifecycle() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("lx-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q", "-b", "main")
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")

        let f = try await fixture(workspace: repo)
        defer { try? FileManager.default.removeItem(at: f.root) }

        let created = try await f.host.createWorktree(
            envelope: CommandEnvelope(payload: CreateWorktreeRequest(name: "task-1"))).result
        let worktree = try #require(created)
        #expect(worktree.branch == "lingxi/task-1")
        #expect(worktree.path.hasPrefix(f.root.standardizedFileURL.path) || worktree.path.contains("/worktrees/"))
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("NOTES.md").path))

        try "from worktree\n".write(to: URL(fileURLWithPath: worktree.path).appendingPathComponent("NOTES.md"),
                                    atomically: true, encoding: .utf8)
        let listed = try await f.host.listWorktrees(envelope: QueryEnvelope(payload: VoidResult())).payload
        #expect(listed.map(\.id) == ["task-1"])

        _ = try await f.host.applyWorktree(envelope: CommandEnvelope(payload: ApplyWorktreeRequest(worktreeID: "task-1")))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("NOTES.md").path))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await f.host.listWorktrees(envelope: QueryEnvelope(payload: VoidResult())).payload.isEmpty)
    }

    @Test("Porcelain listing parses branches and prunable entries")
    func porcelainParsing() {
        let entries = CoreHost.parseWorktreeListing("""
        worktree /repo
        HEAD abc
        branch refs/heads/main

        worktree /data/worktrees/repo-1/x
        HEAD def
        branch refs/heads/lingxi/x
        prunable gitdir file points to non-existent location
        """)
        #expect(entries.map(\.path) == ["/repo", "/data/worktrees/repo-1/x"])
        #expect(entries.last?.branch == "lingxi/x")
        #expect(entries.last?.prunable == true)
        #expect(CoreHost.stableHash("/repo") == CoreHost.stableHash("/repo"))
    }
}
