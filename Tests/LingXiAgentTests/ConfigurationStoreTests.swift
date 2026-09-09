import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ConfigurationStoreTests {
    @Test func bootstrapCreatesFourTypedOfflineConfigurations() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ConfigurationStore(dataRoot: root)
        let snapshot = try await store.load()

        #expect(snapshot.core == CoreConfiguration())
        #expect(snapshot.providers.customProviders.isEmpty)
        #expect(snapshot.mcp.servers.isEmpty)
        #expect(snapshot.plugins == PluginsConfiguration())
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set([
            "config.json", "providers.json", "mcp.json", "plugins.json",
        ]))
        #expect(ConfigurationSchemaURI.core.contains(".invalid/"))
    }

    @Test func bundledTemplatesAndSchemasUseTheCanonicalURIs() throws {
        for document in ConfigurationDocument.allCases {
            let template = try #require(JSONSerialization.jsonObject(with: ConfigurationResources.defaultData(for: document)) as? [String: Any])
            let schema = try #require(JSONSerialization.jsonObject(with: ConfigurationResources.schemaData(for: document)) as? [String: Any])
            #expect(template["$schema"] as? String == document.schemaURI)
            #expect(schema["$id"] as? String == document.schemaURI)
            #expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
            try JSONSchemaValidator.validate(
                documentData: ConfigurationResources.defaultData(for: document),
                schemaData: ConfigurationResources.schemaData(for: document)
            )
        }
    }

    @Test func legacyProviderConfigurationLoadsThroughPublicProjection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let legacy = #"""
        {
          "$schema": "https://schemas.example.invalid/lingxiagent/providers.schema.json",
          "version": 1,
          "customProviders": [{"id":"legacy","displayName":"Legacy","baseURL":"https://legacy.example.com/v1"}],
          "accounts": [{"id":"legacy-account","providerID":"legacy","displayName":"Legacy","enabled":true,"authentication":"none","configOverrides":{},"accountType":"apiKey","createdAt":0,"updatedAt":0}],
          "modelProfiles": [{"id":"legacy-profile","providerID":"legacy","modelID":"legacy-model","displayName":"Legacy Model","wireProtocol":"chatCompletions","contextWindow":32768,"capabilities":{"toolCalling":true,"parallelToolCalling":false,"reasoning":false,"vision":false,"structuredOutput":false},"remoteStateEnabled":false}],
          "defaultSelection": {"accountID":"legacy-account","profileID":"legacy-profile"}
        }
        """#
        try Data(legacy.utf8).write(to: root.appendingPathComponent("providers.json"), options: .atomic)

        let snapshot = try await store.load()
        #expect(snapshot.providers.model == "legacy/legacy-model")
        #expect(snapshot.providers.providers["legacy"]?.models["legacy-model"]?.name == "Legacy Model")
    }

    @Test func strictValidationReportsUnknownTypeAndVersionPaths() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let url = root.appendingPathComponent("config.json")

        var object = try jsonObject(at: url)
        var core = try #require(object["core"] as? [String: Any])
        core["unexpected"] = true
        object["core"] = core
        try write(object, to: url)
        await expectValidationError(store, path: "$.core.unexpected", containing: "unknown property")

        try await store.saveCore(CoreConfiguration())
        object = try jsonObject(at: url)
        var agent = try #require(object["agent"] as? [String: Any])
        agent["maxSubagentDepth"] = "three"
        object["agent"] = agent
        try write(object, to: url)
        await expectValidationError(store, path: "$.agent.maxSubagentDepth", containing: "expected integer")

        try await store.saveCore(CoreConfiguration())
        object = try jsonObject(at: url)
        object["version"] = 2
        try write(object, to: url)
        await expectValidationError(store, path: "$.version", containing: "allowed enum")
    }

    @Test func stableRoundTripAndAtomicOverwriteReplaceTheWholeFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        var snapshot = try await store.load()
        snapshot.core.core.logLevel = .debug
        let url = root.appendingPathComponent("config.json")

        try Data(repeating: 0x78, count: 128_000).write(to: url)
        try await store.saveCore(snapshot.core)
        let first = try Data(contentsOf: url)
        try await store.saveCore(snapshot.core)
        let second = try Data(contentsOf: url)

        #expect(first == second)
        #expect(first.count < 128_000)
        #expect(try await store.load().core.core.logLevel == .debug)
    }

    @Test func credentialsStayInStrictDedicatedVault() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurations = try ConfigurationStore(dataRoot: root)
        var snapshot = try await configurations.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        let reference = CredentialRef("provider-main")
        let sentinel = "secret-sentinel-729"

        try await credentials.setSecret(sentinel, for: reference)
        snapshot.providers.customProviders = [
            CustomProviderConfiguration(
                id: "custom",
                displayName: "Custom",
                baseURL: "https://api.example.invalid/v1"
            ),
        ]
        snapshot.providers.accounts = [
            ProviderAccountConfiguration(
                id: "main",
                providerID: "custom",
                displayName: "Main",
                authentication: .bearer,
                credential: reference,
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
        ]
        snapshot.providers.modelProfiles = [
            ModelProfileConfiguration(
                id: "custom-model",
                providerID: "custom",
                modelID: "model-1",
                displayName: "Model 1",
                wireProtocol: .responses,
                contextWindow: 32_768,
                remoteStateEnabled: true
            ),
        ]
        snapshot.providers.defaultSelection = StoredModelSelection(accountID: "main", profileID: "custom-model")
        snapshot.mcp.servers = [
            StoredMCPServerConfiguration(
                id: "fixture",
                alias: "Fixture",
                transport: .streamableHTTP,
                endpoint: "https://mcp.example.invalid",
                authentication: MCPAuthenticationConfiguration(kind: .bearer, credential: reference)
            ),
        ]
        try await configurations.save(snapshot)

        #expect(try await credentials.secret(for: reference) == sentinel)
        #expect(try await configurations.load().providers == snapshot.providers)
        for filename in ["config.json", "providers.json", "mcp.json", "plugins.json"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8)
            #expect(!text.contains(sentinel))
        }
        let vaultText = try String(contentsOf: root.appendingPathComponent("credentials.vault"), encoding: .utf8)
        #expect(!vaultText.contains(sentinel))
        #expect(vaultText.contains(#""name" : "AES-256-GCM""#))

        let invalidVault: [String: Any] = ["version": 1, "credentials": [:], "extra": true]
        try write(invalidVault, to: root.appendingPathComponent("credentials.vault"))
        do {
            _ = try await credentials.secret(for: reference)
            Issue.record("credentials.vault should reject unknown fields")
        } catch let error as ConfigurationValidationError {
            #expect(error.path == "$.extra")
            #expect(error.reason.contains("unknown property"))
        }
    }

    @Test func legacyVaultMigratesToEncryptedAtRestWithoutPlaintextBackup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = "secret-sentinel-729"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(["version": 1, "credentials": ["provider-main": sentinel]], to: root.appendingPathComponent("credentials.vault"))

        let store = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        #expect(try await store.secret(for: CredentialRef("provider-main")) == sentinel)
        for filename in ["credentials.vault", "credentials.vault.v1-migration-backup"] {
            let contents = try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8)
            #expect(!contents.contains(sentinel))
            #expect(contents.contains(#""version" : 2"#))
        }

        let reopened = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        #expect(try await reopened.secret(for: CredentialRef("provider-main")) == sentinel)

        let unavailable = try FileCredentialStore(dataRoot: root)
        await #expect(throws: ConfigurationValidationError.self) {
            _ = try await unavailable.secret(for: CredentialRef("provider-main"))
        }
    }

    @Test func legacyVaultDoesNotOverwriteAnExistingMigrationBackup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = root.appendingPathComponent("credentials.vault")
        try write(["version": 1, "credentials": ["provider-main": "secret-sentinel-729"]], to: vault)
        try Data("existing encrypted backup".utf8).write(to: root.appendingPathComponent("credentials.vault.v1-migration-backup"))

        let store = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        await #expect(throws: ConfigurationValidationError.self) {
            _ = try await store.secret(for: CredentialRef("provider-main"))
        }
        #expect(try String(contentsOf: vault, encoding: .utf8).contains("secret-sentinel-729"))
    }

    #if !os(Windows)
    @Test func unixPermissionsAreRestricted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        try await credentials.setSecret("permission-sentinel", for: CredentialRef("test"))

        #expect(try permissions(at: root) == 0o700)
        for filename in ["config.json", "providers.json", "mcp.json", "plugins.json", "credentials.vault"] {
            #expect(try permissions(at: root.appendingPathComponent(filename)) == 0o600)
        }
    }

    @Test func vaultRefusesInsecurePersistenceWithoutPassphraseAndNeverWritesMasterKey() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileCredentialStore(dataRoot: root, passphrase: nil)

        // Attempting to persist without passphrase must fail-closed
        await #expect(throws: ConfigurationValidationError.self) {
            try await store.setSecret("super-secret", for: CredentialRef("test-ref"))
        }

        // Must never create a plaintext .master_key in dataRoot
        let masterKeyPath = root.appendingPathComponent(".master_key")
        #expect(!FileManager.default.fileExists(atPath: masterKeyPath.path))

        // Must not leave an unencrypted vault
        let vaultPath = root.appendingPathComponent("credentials.vault")
        #expect(!FileManager.default.fileExists(atPath: vaultPath.path))
    }

    @Test func platformSecureCredentialStoreRejectsInsecurePersistenceWithoutPassphrase() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try PlatformSecureCredentialStore(dataRoot: root, passphrase: nil, allowMemoryOnlyFallback: false)

        // Must never create a plaintext .master_key in dataRoot
        let masterKeyPath = root.appendingPathComponent(".master_key")
        #expect(!FileManager.default.fileExists(atPath: masterKeyPath.path))
    }

    @Test func universalCredentialStorePersistsAndDecryptsWithAutonomousProtectedKey() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try UniversalCredentialStore(dataRoot: root, passphrase: nil)
        try await store.setSecret("autonomous-secret-123", for: CredentialRef("api-key"))

        // Must create .vault_key with 0o600 permissions
        let vaultKeyPath = root.appendingPathComponent(".vault_key")
        #expect(FileManager.default.fileExists(atPath: vaultKeyPath.path))
        #if !os(Windows)
        let perms = try permissions(at: vaultKeyPath)
        #expect(perms == 0o600)
        #endif

        // Must create credentials.vault with 0o600 permissions
        let vaultPath = root.appendingPathComponent("credentials.vault")
        #expect(FileManager.default.fileExists(atPath: vaultPath.path))

        // Read through existing instance
        let readSecret = try await store.secret(for: CredentialRef("api-key"))
        #expect(readSecret == "autonomous-secret-123")

        // Re-open in a fresh instance using autonomous key
        let freshStore = try UniversalCredentialStore(dataRoot: root, passphrase: nil)
        let freshRead = try await freshStore.secret(for: CredentialRef("api-key"))
        #expect(freshRead == "autonomous-secret-123")

        // Removal test
        try await freshStore.removeSecret(for: CredentialRef("api-key"))
        let removed = try await freshStore.secret(for: CredentialRef("api-key"))
        #expect(removed == nil)
    }

    @Test func universalCredentialStoreRejectsIncorrectPassphraseVerification() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try UniversalCredentialStore(dataRoot: root, passphrase: "correct-passphrase")
        try await store.setSecret("top-secret-payload", for: CredentialRef("secure-ref"))

        let integrityOk = try await store.verifyStoreIntegrity()
        #expect(integrityOk)

        // Opening with incorrect passphrase must fail key verification during read
        let badStore = try UniversalCredentialStore(dataRoot: root, passphrase: "wrong-passphrase")
        await #expect(throws: ConfigurationValidationError.self) {
            _ = try await badStore.secret(for: CredentialRef("secure-ref"))
        }
    }

    @Test func platformSecureCredentialStoreDecoupledFromSystemKeychain() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try PlatformSecureCredentialStore(dataRoot: root, passphrase: nil)
        try await store.setSecret("decoupled-secret-xyz", for: CredentialRef("provider-key"))

        let fetched = try await store.secret(for: CredentialRef("provider-key"))
        #expect(fetched == "decoupled-secret-xyz")

        let integrity = try await store.verifyStoreIntegrity()
        #expect(integrity)
    }

    @Test func memoryOnlyStorePreservesSecretsWithoutTouchingDisk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try FileCredentialStore(dataRoot: root, isMemoryOnly: true)
        try await store.setSecret("transient-secret", for: CredentialRef("temp-token"))

        let read = try await store.secret(for: CredentialRef("temp-token"))
        #expect(read == "transient-secret")

        // No files written to disk
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(files.isEmpty)
    }
    #endif

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-configuration-\(UUID().uuidString)", isDirectory: true)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func expectValidationError(_ store: ConfigurationStore, path: String, containing text: String) async {
        do {
            _ = try await store.load()
            Issue.record("configuration should fail validation")
        } catch let error as ConfigurationValidationError {
            #expect(error.path == path)
            #expect(error.reason.contains(text))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    #if !os(Windows)
    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
    #endif
}
