import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

/// The Secret Source / Credential Resolution layer: one grammar, one precedence, and the startup
/// repair that moves a hand-written `{env:…}` account onto the durable store.
@Suite("Provider credential resolution", .serialized)
struct ProviderCredentialResolutionTests {

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stores(_ dir: URL) throws -> (FileCredentialStore, ConfigurationStore) {
        (try FileCredentialStore(dataRoot: dir, passphrase: "test-passphrase", iterations: 100_000),
         try ConfigurationStore(dataRoot: dir))
    }

    /// A provider entry in exactly the shape a hand-edited providers.json carries.
    private func account(_ id: String, apiKey: String?) -> PublicProviderConfiguration {
        PublicProviderConfiguration(
            name: id.uppercased(), adapter: "openai-compatible",
            options: PublicProviderOptions(baseURL: "https://relay.test/v1", apiKey: apiKey),
            models: ["m": PublicModelConfiguration(name: "M")])
    }

    // MARK: - Grammar

    @Test("every source form a file can name reads as its own case")
    func sourceGrammar() {
        #expect(ProviderCredentialSource("{vault:provider-bai-key}") == .vault(CredentialRef("provider-bai-key")))
        #expect(ProviderCredentialSource("{oauth:provider-gemini-oauth}") == .oauth(CredentialRef("provider-gemini-oauth")))
        #expect(ProviderCredentialSource("{env:SENSENOVA_API_KEY}") == .environment("SENSENOVA_API_KEY"))
        #expect(ProviderCredentialSource(nil) == .absent)
        #expect(ProviderCredentialSource("") == .absent)
        // The decoder gate refuses a bare value on disk; the resolver still reads one an in-memory
        // configuration happens to hold, rather than dropping the account mid-session.
        #expect(ProviderCredentialSource("sk-direct") == .literal("sk-direct"))
        // A near-miss is a literal, not a silently-empty reference.
        #expect(ProviderCredentialSource("{env:UNCLOSED") == .literal("{env:UNCLOSED"))
    }

    @Test("the override variable name is one deterministic spelling per provider")
    func overrideVariableName() {
        #expect(ProviderCredentialOverride.variableName(providerID: "bai") == "LINGXI_BAI_API_KEY")
        #expect(ProviderCredentialOverride.variableName(providerID: "openai-codex") == "LINGXI_OPENAI_CODEX_API_KEY")
        // Anything that cannot appear in a variable name becomes a separator, so two spellings of one
        // id can never resolve to two different override keys.
        #expect(ProviderCredentialOverride.variableName(providerID: "Open AI") == "LINGXI_OPEN_AI_API_KEY")
        #expect(ProviderCredentialOverride.secret(providerID: "bai", environment: ["LINGXI_BAI_API_KEY": " v "]) == "v")
        #expect(ProviderCredentialOverride.secret(providerID: "bai", environment: ["LINGXI_BAI_API_KEY": "  "]) == nil)
        #expect(ProviderCredentialOverride.secret(providerID: "bai", environment: [:]) == nil)
    }

    @Test("an explicit override replaces what the file names, including a vault entry")
    func overrideBeatsTheFile() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)
        try await credentials.setSecret("the-stored-key", for: CredentialRef("provider-lxov-key"))
        let host = try CoreHost(configurationStore: store, credentialStore: credentials)
        setenv("LINGXI_LXOV_API_KEY", "the-override-key", 1)
        defer { unsetenv("LINGXI_LXOV_API_KEY") }

        #expect(await host.resolveProviderSecret("{vault:provider-lxov-key}", providerID: "lxov") == "the-override-key")
        #expect(await host.resolveProviderSecret(nil, providerID: "lxov") == "the-override-key")
        // A different provider must not pick up this one's override.
        #expect(await host.resolveProviderSecret("{vault:provider-lxov-key}", providerID: "other") == "the-stored-key")
    }

    // MARK: - Self-healing migration

    @Test("a resolvable {env:…} account moves into the vault and stops needing the variable")
    func migrationMovesResolvablePointerIntoVault() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)
        var providers = try await store.load().providers
        providers.providers["bai"] = account("bai", apiKey: "{env:LX_MIG_TEST_KEY}")
        try await store.saveProviders(providers)
        setenv("LX_MIG_TEST_KEY", "sk-migrated-value", 1)

        let migrated = await ProviderCredentialMigration.apply(
            configurationStore: store, credentialStore: credentials)
        unsetenv("LX_MIG_TEST_KEY")

        #expect(migrated == ["bai: {env:LX_MIG_TEST_KEY} → {vault:provider-bai-key}"])
        let after = try await store.load().providers
        #expect(after.providers["bai"]?.options.apiKey == "{vault:provider-bai-key}")
        #expect(try await credentials.secret(for: CredentialRef("provider-bai-key")) == "sk-migrated-value")
        // The point of the whole exercise: with the variable gone — a Dock launch — the key is still there.
        let host = try CoreHost(configurationStore: store, credentialStore: credentials)
        #expect(await host.resolveProviderSecret(after.providers["bai"]?.options.apiKey, providerID: "bai")
                == "sk-migrated-value")
        // And the pre-change file survives, still in the shape it was written in.
        let backup = dir.appendingPathComponent(ProviderCredentialMigration.backupFilename)
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("{env:LX_MIG_TEST_KEY}"))
    }

    @Test("an {env:…} pointer whose variable is absent is left exactly as it was")
    func migrationNeverDestroysAnUnresolvablePointer() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)
        var providers = try await store.load().providers
        providers.providers["bai"] = account("bai", apiKey: "{env:LX_MIG_ABSENT_KEY}")
        try await store.saveProviders(providers)
        unsetenv("LX_MIG_ABSENT_KEY")

        await ProviderCredentialMigration.apply(configurationStore: store, credentialStore: credentials)

        // Rewriting the pointer here would destroy the only place the key is written down.
        #expect(try await store.load().providers.providers["bai"]?.options.apiKey == "{env:LX_MIG_ABSENT_KEY}")
        #expect(!FileManager.default.fileExists(atPath: dir
            .appendingPathComponent(ProviderCredentialMigration.backupFilename).path))
    }

    @Test("a vault account is never rewritten by the migration")
    func migrationIgnoresDurableAccounts() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)
        var providers = try await store.load().providers
        providers.providers["xiaomi"] = account("xiaomi", apiKey: "{vault:provider-xiaomi-key}")
        try await store.saveProviders(providers)
        let file = dir.appendingPathComponent("providers.json")
        let before = try Data(contentsOf: file)

        await ProviderCredentialMigration.apply(configurationStore: store, credentialStore: credentials)

        #expect(try await store.load().providers.providers["xiaomi"]?.options.apiKey == "{vault:provider-xiaomi-key}")
        #expect(try Data(contentsOf: file) == before, "无事可迁时不该碰文件")
    }

    @Test("the migration is reachable only from product entry points, never from start()")
    func migrationIsNotWiredIntoHostStartup() throws {
        // `CoreHost.start()` runs inside the test binary for hundreds of hosts, and
        // `VNextProductionIntegrationTests` deliberately points one at the developer's own data root.
        // A startup write there silently rewrites a live profile, which is exactly what this guard
        // caught once already.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["Sources/LingXiCore/App/CoreHost.swift",
                     "Sources/LingXiCore/Modules/Session/SessionRuntime.swift",
                     "Sources/LingXiCore/Configuration/RuntimeConfigurationResolver.swift"] {
            #expect(try !source(path).contains("ProviderCredentialMigration.apply"),
                    "\(path) 不得在启动路径上改写用户配置")
        }
        for path in ["Sources/LingXiCoreHost/main.swift", "Sources/lingxiagent-ops/main.swift"] {
            #expect(try source(path).contains("ProviderCredentialMigration.apply"),
                    "\(path) 是真正的产品入口，应当执行凭据迁移")
        }
    }

    // MARK: - The dead-value bug

    @Test("`auth set env:NAME` is refused, because the vault can never serve that reference")
    func authSetRefusesEnvironmentReference() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)

        let output = try await AuthCLI.run(arguments: ["auth", "set", "env:LX_DEAD_KEY", "sk-nope"],
                                          dataRoot: dir, credentialStore: credentials, configurationStore: store)
        #expect(output.contains("Error"))
        #expect(try await credentials.secret(for: CredentialRef("env:LX_DEAD_KEY")) == nil)
    }

    @Test("`auth import-env` stores one entry that the resolver can actually read")
    func importEnvStoresOneReadableEntry() async throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (credentials, store) = try stores(dir)
        setenv("LX_IMPORT_KEY", "sk-imported", 1)
        defer { unsetenv("LX_IMPORT_KEY") }

        _ = try await AuthCLI.run(arguments: ["auth", "import-env", "LX_IMPORT_KEY", "provider-demo-key"],
                                 dataRoot: dir, credentialStore: credentials, configurationStore: store)

        #expect(try await credentials.secret(for: CredentialRef("provider-demo-key")) == "sk-imported")
        // It used to also write `env:LX_IMPORT_KEY`. `credentialValue` treats an `env:`-prefixed
        // reference as a pointer into the environment, so that second copy was stored where nothing
        // would ever look for it.
        #expect(try await credentials.secret(for: CredentialRef("env:LX_IMPORT_KEY")) == nil)
    }
}
