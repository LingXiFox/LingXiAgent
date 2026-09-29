import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LingXiCore
@testable import LingXiProtocol

/// The provider list the settings window picks from, and what Core does with a
/// pick that comes from the published index rather than the curated registry.
@Suite("Provider catalog: registry merged with the published index", .serialized)
struct ProviderCatalogTests {

    private let indexURL = URL(string: "https://index.test/models.json")!

    /// An index client fed from a fixture payload instead of the network.
    private func indexClient(_ payload: String) async -> LingXiModelsCatalogClient {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-index-\(UUID().uuidString)", isDirectory: true)
        let client = LingXiModelsCatalogClient(catalogURL: indexURL, cacheDirectory: dir)
        let url = indexURL
        _ = await client.fetch(httpClient: { _ in
            (Data(payload.utf8), HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!)
        })
        try? FileManager.default.removeItem(at: dir)
        return client
    }

    private func fixture(client: LingXiModelsCatalogClient) async throws -> (URL, CoreHost, ConfigurationStore, FileCredentialStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let host = try CoreHost(configurationStore: store, credentialStore: credentials,
                                modelsCatalogClient: client)
        return (root, host, store, credentials)
    }

    private static let payload = """
    {
      "version": "test",
      "providers": {
        "index-relay": {
          "id": "index-relay", "name": "Index Relay", "baseURL": "https://api.index.test/v1",
          "swiftDriver": "openaiChat",
          "models": {"beta": {"id": "beta"}, "alpha": {"id": "alpha"}}
        },
        "index-local": {
          "id": "index-local", "name": "Index Local", "baseURL": "http://127.0.0.1:11434/v1",
          "swiftDriver": "ollamaNative", "models": {"llama": {"id": "llama"}}
        },
        "index-unknown-driver": {
          "id": "index-unknown-driver", "name": "Odd Driver", "baseURL": "https://odd.test/v1",
          "swiftDriver": "geminiNative", "models": {}
        },
        "index-no-endpoint": {
          "id": "index-no-endpoint", "name": "No Endpoint", "swiftDriver": "openaiChat", "models": {}
        }
      }
    }
    """

    @Test("The catalog merges both sources and marks what this runtime cannot drive")
    func mergedCatalog() async throws {
        let entries = await ProviderCatalog.entries(refresh: false, siteClient: indexClient(Self.payload))

        for product in BuiltinProviderCatalog.connectableProducts() {
            #expect(entries.contains { $0.source == .registry && $0.id == product.id },
                    "\(product.id) 应出现在目录中")
        }
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "同一提供商不得出现两次")

        let relay = try #require(entries.first { $0.id == "index-relay" })
        #expect(relay.source == .modelsIndex)
        #expect(relay.name == "Index Relay")
        #expect(relay.signInMode == .apiKey)
        #expect(relay.modelCount == 2)
        #expect(relay.connectable)

        // A loopback endpoint is a local runtime, not something to send a key to.
        #expect(entries.first { $0.id == "index-local" }?.signInMode == .localEndpoint)

        // Published but undrivable stays listed and unusable: the index states
        // the provider exists, its driver is what is missing here.
        let odd = try #require(entries.first { $0.id == "index-unknown-driver" })
        #expect(odd.source == .modelsIndex)
        #expect(!odd.connectable)
        let noEndpoint = try #require(entries.first { $0.id == "index-no-endpoint" })
        #expect(!noEndpoint.connectable)
    }

    @Test("A curated product wins over the same id published by the index")
    func registryWinsDuplicates() async throws {
        let curated = try #require(BuiltinProviderCatalog.connectableProducts().first)
        let payload = Self.payload.replacingOccurrences(
            of: "\"index-relay\": {",
            with: "\"\(curated.id)\": {\"id\": \"\(curated.id)\", \"name\": \"Shadow\", "
                + "\"baseURL\": \"https://shadow.test/v1\", \"swiftDriver\": \"openaiChat\", \"models\": {}}, "
                + "\"index-relay\": {")
        let entries = await ProviderCatalog.entries(refresh: false, siteClient: indexClient(payload))
        let matches = entries.filter { $0.id == curated.id }
        #expect(matches.count == 1)
        #expect(matches.first?.source == .registry)
        #expect(matches.first?.name == curated.displayName)
    }

    @Test("A curated product's roster is what the index publishes for it")
    func modelRosters() async throws {
        let client = await indexClient(Self.payload)
        #expect(await ProviderCatalog.modelIDs(entryID: "index-relay", siteClient: client) == ["alpha", "beta"])
        #expect(await ProviderCatalog.modelIDs(entryID: "not-published", siteClient: client) == [])

        // The curated product is `deepseek-api`, the index publishes it as
        // `deepseek`; the row has to find its models through that alias.
        let aliased = Self.payload.replacingOccurrences(
            of: "\"index-relay\": {",
            with: "\"deepseek\": {\"id\": \"deepseek\", \"name\": \"DeepSeek\", "
                + "\"baseURL\": \"https://api.deepseek.com/v1\", \"swiftDriver\": \"openaiChat\", "
                + "\"models\": {\"chat-latest\": {\"id\": \"chat-latest\"}}}, \"index-relay\": {")
        let aliasClient = await indexClient(aliased)
        #expect(await ProviderCatalog.modelIDs(entryID: "deepseek-api", siteClient: aliasClient) == ["chat-latest"])
        let row = try #require(await ProviderCatalog.entries(refresh: false, siteClient: aliasClient)
            .first { $0.id == "deepseek-api" })
        #expect(row.modelCount == 1)
    }

    @Test("A published index entry connects with only the key supplied by the user")
    func connectPublishedEntry() async throws {
        let (root, host, store, credentials) = try await fixture(client: indexClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try await host.storeCredential(
            envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-index-1")))
        let reference = try #require(staged.result?.reference)

        let receipt = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
            productID: "index-relay", credentialRef: reference, modelIDs: ["alpha", "beta"])))
        let account = try #require(receipt.result)
        #expect(account.productID == "index-relay")

        let saved = try await store.load().providers.providers["index-relay"]
        let detail = try #require(saved)
        // Endpoint and protocol are the index's, not the caller's; only the
        // model choice was made in the window.
        #expect(detail.options.baseURL == "https://api.index.test/v1")
        #expect(detail.adapter == "openai-compatible")
        #expect(detail.options.apiKey == "{vault:provider-index-relay-key}")
        #expect(Set(detail.models.keys) == ["alpha", "beta"])
        // Unset fields stay absent so a later index update still reaches them.
        #expect(detail.models["alpha"]?.limit == nil)
        #expect(try await credentials.secret(for: CredentialRef("provider-index-relay-key")) == "sk-index-1")
        let file = try String(contentsOf: root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!file.contains("sk-index-1"), "明文密钥不得写入 providers.json")
        // The staged copy is adopted, not left behind.
        #expect(try await credentials.secret(for: reference) == nil)
    }

    @Test("An undrivable or unlisted entry is refused before anything is stored")
    func connectRefused() async throws {
        let (root, host, store, _) = try await fixture(client: indexClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try await host.storeCredential(
            envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-x")))
        let reference = try #require(staged.result?.reference)

        for id in ["index-unknown-driver", "index-no-endpoint", "not-published"] {
            await #expect(throws: (any Error).self) {
                _ = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                    productID: id, credentialRef: reference, modelIDs: ["m"])))
            }
        }
        // No models chosen is not a provider the runtime can use.
        await #expect(throws: (any Error).self) {
            _ = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                productID: "index-relay", credentialRef: reference)))
        }
        #expect(try await store.load().providers.providers.isEmpty)
    }
}
