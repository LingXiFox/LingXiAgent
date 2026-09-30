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

    @Test("A model override is stored field by field and reset drops only that key")
    func modelOverrideSemantics() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The user states one limit, one capability and one retry field; nothing else.
        let draft = ProviderModelConfigurationDetail(
            modelID: "fast-1", name: "Fast", contextWindow: 200_000, reasoning: true, maxRetries: 7)
        var request = providerRequest(apiKey: .replace("sk-test-123"))
        request.models = [draft]
        let saved = try await f.host.saveProviderConfiguration(
            envelope: CommandEnvelope(payload: request)).result
        #expect(saved?.models.first?.catalogDefaults.tokensPerMinute == nil)
        #expect(saved?.models.first?.effective.maxRetries == 7)
        #expect(saved?.models.first?.effective.contextWindow == 200_000)

        let stored = try #require(
            try await f.store.load().providers.providers["relay"]?.models["fast-1"])
        #expect(stored.limit?.context == 200_000)
        #expect(stored.limit?.output == nil)
        #expect(stored.reasoning == true)
        #expect(stored.toolCalling == nil)
        #expect(stored.rateLimits?.retryPolicy?.maxRetries == 7)
        #expect(stored.rateLimits?.retryPolicy?.initialDelayMilliseconds == nil)

        // The untouched fields are absent from the file, so a catalog update
        // can still reach them; no default was baked in.
        let file = try String(contentsOf: f.root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!file.contains("\"output\""))
        #expect(!file.contains("toolCalling"))
        #expect(!file.contains("parallelToolCalling"))
        #expect(!file.contains("initialDelayMilliseconds"))

        // Resetting the context window deletes that override and keeps the others.
        var resetOne = request
        resetOne.models = [ProviderModelConfigurationDetail(
            modelID: "fast-1", name: "Fast", reasoning: true, maxRetries: 7)]
        _ = try await f.host.saveProviderConfiguration(envelope: CommandEnvelope(payload: resetOne))
        let afterOne = try #require(
            try await f.store.load().providers.providers["relay"]?.models["fast-1"])
        #expect(afterOne.limit?.context == nil)
        #expect(afterOne.reasoning == true)
        #expect(afterOne.rateLimits?.retryPolicy?.maxRetries == 7)

        // 恢复全部默认 removes every override, leaving the entry itself in place.
        var resetAll = request
        resetAll.models = [ProviderModelConfigurationDetail(modelID: "fast-1", name: "Fast")]
        _ = try await f.host.saveProviderConfiguration(envelope: CommandEnvelope(payload: resetAll))
        let afterAll = try #require(
            try await f.store.load().providers.providers["relay"]?.models["fast-1"])
        #expect(afterAll.limit == nil)
        #expect(afterAll.reasoning == nil)
        #expect(afterAll.rateLimits == nil)
        #expect(afterAll.name == "Fast")
    }

    @Test("A staged key is adopted on save and a draft test reports what actually happened")
    func stagedCredentialAndDraftTest() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        // The key reaches Core once, through the credential API.
        let staged = try await f.host.storeCredential(
            envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-draft-1")))
        let reference = try #require(staged.result?.reference)

        // Nothing is listening on that port, so the honest answer is unreachable.
        var draft = TestProviderDraftRequest(adapter: "openai-compatible",
                                             baseURL: "https://127.0.0.1:9/v1", credentialRef: reference)
        let tested = try await f.host.testProviderDraft(envelope: CommandEnvelope(payload: draft)).result
        #expect(tested?.reachable == false)
        #expect(tested?.latencyMs == nil)
        #expect(tested?.message?.contains("sk-draft-1") == false)

        // An invalid adapter is refused before anything is probed.
        draft.adapter = "grpc"
        await #expect(throws: (any Error).self) {
            _ = try await f.host.testProviderDraft(envelope: CommandEnvelope(payload: draft))
        }

        // Saving adopts the staged secret instead of resending the plaintext.
        let saved = try await f.host.saveProviderConfiguration(
            envelope: CommandEnvelope(payload: providerRequest(apiKey: .staged(reference: reference)))).result
        #expect(saved?.apiKey == .vault)
        let file = try String(contentsOf: f.root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!file.contains("sk-draft-1"))
        #expect(try await f.credentials.secret(for: CredentialRef("provider-relay-key")) == "sk-draft-1")
        #expect(try await f.credentials.secret(for: reference) == nil, "暂存凭据不应残留")

        // A stale reference cannot be adopted.
        await #expect(throws: (any Error).self) {
            _ = try await f.host.saveProviderConfiguration(
                envelope: CommandEnvelope(payload: providerRequest(apiKey: .staged(reference: reference))))
        }
    }

    @Test("A registry product connects through its own contract, not a hand-written form")
    func connectProductByContract() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let products = BuiltinProviderCatalog.connectableProducts().filter { $0.connectable }
        #expect(!products.isEmpty)

        // An API Key product: the key arrives as a staged vault reference and the
        // endpoint comes from the catalog, so the request carries no URL at all.
        if let keyed = products.first(where: { $0.requiresCredential && $0.requestAuthentication != .oauthAccessToken }) {
            let staged = try await f.host.storeCredential(
                envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-product-1")))
            let reference = try #require(staged.result?.reference)
            let fields = Dictionary(uniqueKeysWithValues: keyed.requiredAccountFields.map { ($0, "cn") })
            let account = try await f.host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                productID: keyed.id, credentialRef: reference, fields: fields))).result
            let info = try #require(account)
            #expect(info.productID == keyed.id)
            #expect(info.credentialRef == reference)
            let file = try String(contentsOf: f.root.appendingPathComponent("providers.json"), encoding: .utf8)
            #expect(!file.contains("sk-product-1"), "明文密钥不得写入 providers.json")
            #expect(try await f.credentials.secret(for: reference) == "sk-product-1")

            // Declared account fields are mandatory.
            await #expect(throws: (any Error).self) {
                _ = try await f.host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                    productID: keyed.id, credentialRef: reference)))
            }

            // Same product without a key is refused with a readable reason.
            await #expect(throws: (any Error).self) {
                _ = try await f.host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(productID: keyed.id)))
            }
        }

        // An OAuth product is never satisfied by a typed key.
        if let oauth = products.first(where: { $0.requestAuthentication == .oauthAccessToken || $0.accountTypes.contains(.oauthUser) }) {
            await #expect(throws: (any Error).self) {
                _ = try await f.host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(productID: oauth.id)))
            }
        }

        // A product outside the catalog cannot be connected.
        await #expect(throws: (any Error).self) {
            _ = try await f.host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(productID: "not-a-product")))
        }
    }

    @Test("A provider test reports the real answer, not a stored one")
    func providerTestIsNotHardcoded() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await f.host.testProvider(
            envelope: CommandEnvelope(payload: TestProviderRequest(providerID: "does-not-exist"))).result
        #expect(result?.reachable == false)
        #expect(result?.latencyMs == nil)
        #expect(result?.message?.contains("未找到") == true)
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
