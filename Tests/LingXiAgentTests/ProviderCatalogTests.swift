import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiModelSDK
@testable import LingXiCore
@testable import LingXiProtocol

/// Serves a fixture document as if it were the published catalog, so nothing in
/// these tests touches the network.
private struct FixtureTransport: ModelCatalogTransport {
    let body: String

    func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                         httpVersion: nil, headerFields: ["ETag": "\"test\""])!)
    }
}

/// The provider list the settings window picks from, and what Core does with a
/// pick that comes from the published catalog rather than the curated contract.
///
/// The rule under test is the split itself: the catalog states that a provider
/// exists and what its models are; only LingXi's own runtime contract decides
/// whether this runtime can drive it.
@Suite("Provider catalog: runtime contract merged with the published catalog", .serialized)
struct ProviderCatalogTests {

    private let indexURL = URL(string: "https://index.test/models.json")!

    private func catalogClient(_ payload: String) async -> PublicModelCatalogClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-catalog-\(UUID().uuidString)", isDirectory: true)
        let client = PublicModelCatalogClient(endpoint: indexURL, cacheDirectory: directory,
                                              transport: FixtureTransport(body: payload))
        _ = await client.refresh(force: true)
        try? FileManager.default.removeItem(at: directory)
        return client
    }

    private func fixture(client: PublicModelCatalogClient) async throws -> (URL, CoreHost, ConfigurationStore, FileCredentialStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let host = try CoreHost(configurationStore: store, credentialStore: credentials,
                                modelsCatalogClient: client)
        return (root, host, store, credentials)
    }

    /// `deepseek` is published here and has a curated product (`deepseek-api`),
    /// so it is drivable. `index-relay` exists in no runtime contract, so listing
    /// it is all this catalog can honestly do.
    private static let payload = """
    {
      "schemaVersion": "2.0", "catalogRevision": "test-rev", "source": "models.dev",
      "generatedAt": "2026-09-30T00:00:00Z", "totalProviders": 4, "totalModels": 5,
      "providers": {
        "index-relay": {
          "id": "index-relay", "name": "Index Relay", "api": "https://api.index.test/v1", "baseURL": "https://api.index.test/v1",
          "env": ["INDEX_API_KEY"],
          "models": {
            "beta": { "id": "beta", "name": "Beta", "limit": { "context": 8000, "output": 512 } },
            "alpha": { "id": "alpha", "name": "Alpha", "release_date": "2026-02-02",
                       "limit": { "context": 16000, "output": 1024 } }
          }
        },
        "index-local": {
          "id": "index-local", "name": "Index Local", "api": "http://127.0.0.1:11434/v1", "baseURL": "http://127.0.0.1:11434/v1",
          "models": { "llama": { "id": "llama", "name": "Llama" } }
        },
        "deepseek": {
          "id": "deepseek", "name": "DeepSeek", "api": "https://api.deepseek.com/v1", "baseURL": "https://api.deepseek.com/v1",
          "env": ["DEEPSEEK_API_KEY"],
          "models": { "chat-latest": { "id": "chat-latest", "name": "Chat Latest",
                                       "limit": { "context": 64000, "output": 8000 } } }
        },
        "index-no-endpoint": {
          "id": "index-no-endpoint", "name": "No Endpoint",
          "models": { "orphan": { "id": "orphan", "name": "Orphan" } }
        }
      }
    }
    """

    @Test("the catalog merges both sources and marks what this runtime cannot drive")
    func mergedCatalog() async throws {
        let entries = await ProviderCatalog.entries(refresh: false, catalogClient: catalogClient(Self.payload))

        for product in BuiltinProviderCatalog.connectableProducts() {
            #expect(entries.contains { $0.source == .registry && $0.id == product.id },
                    "\(product.id) 应出现在目录中")
        }
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "同一提供商不得出现两次")

        // Published, described, and no runtime contract behind it: listed, not
        // connectable. The catalog never decides how a provider is addressed.
        let relay = try #require(entries.first { $0.id == "index-relay" })
        #expect(relay.source == .modelsIndex)
        #expect(relay.name == "Index Relay")
        #expect(relay.modelCount == 2)
        #expect(!relay.connectable)
        #expect(ProviderCatalog.adapter(forPublishedProvider: "index-relay") == nil)

        // A published vendor whose curated product the runtime does implement.
        let deepseek = try #require(entries.first { $0.id == "deepseek" })
        #expect(deepseek.connectable)
        #expect(ProviderCatalog.adapter(forPublishedProvider: "deepseek") == "openai-compatible")

        // A loopback endpoint is a local runtime, not something to send a key to.
        #expect(entries.first { $0.id == "index-local" }?.signInMode == .localEndpoint)
        // No stated endpoint is nothing to connect to.
        #expect(entries.first { $0.id == "index-no-endpoint" }?.connectable == false)
    }

    @Test("the protocol family comes from the runtime contract, never from the catalog")
    func protocolIsRuntimeSide() {
        // The published document carries no driver field at all; these answers
        // are produced by LingXi's own product definitions.
        #expect(ProviderCatalog.protocolFamily(forPublishedProvider: "openai") == "openai_responses")
        #expect(ProviderCatalog.protocolFamily(forPublishedProvider: "anthropic") == "anthropic_messages")
        #expect(ProviderCatalog.protocolFamily(forPublishedProvider: "nonexistent-vendor") == nil)
        #expect(ProviderCatalog.candidateProductIDs(forPublishedProvider: "deepseek").contains("deepseek-api"))
    }

    @Test("a curated product wins over the same id published by the catalog")
    func registryWinsDuplicates() async throws {
        let curated = try #require(BuiltinProviderCatalog.connectableProducts().first)
        let payload = Self.payload.replacingOccurrences(
            of: "\"index-relay\": {",
            with: "\"\(curated.id)\": {\"id\": \"\(curated.id)\", \"name\": \"Shadow\", "
                + "\"api\": \"https://shadow.test/v1\", \"models\": {}}, \"index-relay\": {")
        let entries = await ProviderCatalog.entries(refresh: false, catalogClient: catalogClient(payload))
        let matches = entries.filter { $0.id == curated.id }
        #expect(matches.count == 1)
        #expect(matches.first?.source == .registry)
        #expect(matches.first?.name == curated.displayName)
    }

    @Test("a roster is the catalog's own order, and a product finds it through its alias")
    func modelRosters() async throws {
        let client = await catalogClient(Self.payload)
        // Newest stated release first, undated entries after it — never source
        // iteration order.
        #expect(await ProviderCatalog.modelIDs(entryID: "index-relay", catalogClient: client) == ["alpha", "beta"])
        #expect(await ProviderCatalog.modelIDs(entryID: "not-published", catalogClient: client) == [])

        // The curated product is `deepseek-api`; the catalog publishes `deepseek`.
        #expect(await ProviderCatalog.modelIDs(entryID: "deepseek-api", catalogClient: client) == ["chat-latest"])
        let row = try #require(await ProviderCatalog.entries(refresh: false, catalogClient: client)
            .first { $0.id == "deepseek-api" })
        #expect(row.modelCount == 1)
    }

    @Test("a published provider connects with only the key supplied by the user")
    func connectPublishedEntry() async throws {
        let (root, host, store, credentials) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try await host.storeCredential(
            envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-index-1")))
        let reference = try #require(staged.result?.reference)

        let receipt = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
            productID: "deepseek", credentialRef: reference, modelIDs: ["chat-latest"])))
        let account = try #require(receipt.result)
        #expect(account.productID == "deepseek")

        let saved = try await store.load().providers.providers["deepseek"]
        let detail = try #require(saved)
        // Endpoint and protocol are the catalog's and the runtime's, not the
        // caller's; only the model choice was made in the window.
        #expect(detail.options.baseURL == "https://api.deepseek.com/v1")
        #expect(detail.adapter == "openai-compatible")
        #expect(detail.options.apiKey == "{vault:provider-deepseek-key}")
        #expect(Set(detail.models.keys) == ["chat-latest"])
        // Unset fields stay absent so a later catalog update still reaches them:
        // the stored account records the choice, the catalog keeps the metadata.
        #expect(detail.models["chat-latest"]?.limit == nil)
        #expect(try await credentials.secret(for: CredentialRef("provider-deepseek-key")) == "sk-index-1")
        let file = try String(contentsOf: root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!file.contains("sk-index-1"), "明文密钥不得写入 providers.json")
        // The staged copy is adopted, not left behind.
        #expect(try await credentials.secret(for: reference) == nil)
    }

    @Test("an undrivable or unlisted entry is refused before anything is stored")
    func connectRefused() async throws {
        let (root, host, store, _) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try await host.storeCredential(
            envelope: CommandEnvelope(payload: StoreCredentialRequest(secret: "sk-x")))
        let reference = try #require(staged.result?.reference)

        for id in ["index-relay", "index-no-endpoint", "not-published"] {
            await #expect(throws: (any Error).self) {
                _ = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                    productID: id, credentialRef: reference, modelIDs: ["m"])))
            }
        }
        // No models chosen is not a provider the runtime can use.
        await #expect(throws: (any Error).self) {
            _ = try await host.connectProvider(envelope: CommandEnvelope(payload: ConnectProviderRequest(
                productID: "deepseek", credentialRef: reference)))
        }
        #expect(try await store.load().providers.providers.isEmpty)
    }
}
