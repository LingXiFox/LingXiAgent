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
