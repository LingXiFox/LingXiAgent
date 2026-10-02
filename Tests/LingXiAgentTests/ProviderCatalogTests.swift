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
        "index-compat": {
          "id": "index-compat", "name": "Index Compat", "npm": "@ai-sdk/openai-compatible",
          "api": "https://compat.index.test/v1", "baseURL": "https://compat.index.test/v1",
          "models": { "gamma": { "id": "gamma", "name": "Gamma" } }
        },
        "index-vendor-sdk": {
          "id": "index-vendor-sdk", "name": "Index Vendor SDK", "npm": "@ai-sdk/google",
          "api": "https://vendor.index.test/v1", "baseURL": "https://vendor.index.test/v1",
          "models": { "delta": { "id": "delta", "name": "Delta" } }
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

        // An entry that declares the OpenAI-compatible wire dialect is driven by the adapter
        // that already implements it; a vendor client library is not a wire dialect.
        #expect(entries.first { $0.id == "index-compat" }?.connectable == true)
        #expect(entries.first { $0.id == "index-vendor-sdk" }?.connectable == false)

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

    @Test("Vault-backed Codex login appears in the same account list as saved providers")
    func oauthAccountIsListed() async throws {
        let (root, host, _, credentials) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        try await credentials.setSecret("test-oauth", for: CredentialRef("provider-openai-codex-oauth"))
        let accounts = try await host.listProviders(envelope: QueryEnvelope(payload: VoidResult())).payload
        let codex = try #require(accounts.first { $0.productID == "openai-codex" })
        #expect(codex.accountType == .oauthUser)
        #expect(!accounts.contains { $0.productID == "xai-api" || $0.productID == "opencode-zen" })
    }

    @Test("Saved endpoints list models with the Core-held key and the shared probe URL rules")
    func savedEndpointRoster() async throws {
        let (root, host, _, _) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await host.saveProviderConfiguration(envelope: CommandEnvelope(payload: SaveProviderConfigurationRequest(
            providerID: "relay", name: "Relay", adapter: "openai-compatible",
            baseURL: "https://relay.test/v1/chat/completions", apiKeyHeader: "Authorization",
            apiKey: .replace("test-roster-key"), models: [ProviderModelConfigurationDetail(modelID: "first", name: "First")])))
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.test/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-roster-key")
            return StubURLProtocol.StubResponse(status: 200, body: Data(#"{"data":[{"id":"second"},{"id":"first"},{"id":"second"},{"id":""}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(await host.remoteModelIDs(providerID: "relay", session: session).ids == ["first", "second"])
    }

    @Test("The roster reader takes the envelope the relay answered with, and a failed read says why")
    func remoteRosterShapesAndNotes() async throws {
        let (root, host, _, _) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await host.saveProviderConfiguration(envelope: CommandEnvelope(payload: SaveProviderConfigurationRequest(
            providerID: "relay", name: "Relay", adapter: "openai-compatible",
            baseURL: "https://relay.test/v1", apiKeyHeader: "Authorization",
            apiKey: .replace("test-roster-key"),
            models: [ProviderModelConfigurationDetail(modelID: "first", name: "First")])))
        StubURLProtocol.queuedResponses = [
            // The connection test counted this body; the add-model picker called the same endpoint
            // empty, because only one of the two readers knew `models` was a model list.
            StubURLProtocol.StubResponse(status: 200, body: Data(#"{"models":[{"id":"beta"},{"id":"alpha"}]}"#.utf8)),
            StubURLProtocol.StubResponse(status: 401, body: Data(#"{"error":"denied"}"#.utf8)),
        ]
        let session = StubURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.queuedResponses = []
        }

        let listed = await host.remoteModelIDs(providerID: "relay", session: session)
        #expect(listed.ids == ["alpha", "beta"])
        #expect(listed.note == nil)

        let denied = await host.remoteModelIDs(providerID: "relay", session: session)
        #expect(denied.ids.isEmpty)
        #expect(denied.note?.contains("401") == true, "空列表必须带上端点说过的原因：\(String(describing: denied.note))")
        #expect(denied.note?.contains("test-roster-key") == false, "诊断文字里不得出现凭据")
    }

    @Test("A credential reference that resolves to nothing names the reference instead of blaming the key")
    func unresolvedCredentialReferenceIsNotReportedAsRejection() async throws {
        let (root, host, store, _) = try await fixture(client: catalogClient(Self.payload))
        defer { try? FileManager.default.removeItem(at: root) }
        // `{env:…}` is what a hand-written providers.json carries: saving a key through the RPC cannot
        // produce it, because `updateSecret` puts the plaintext in the vault and stores `{vault:…}`.
        // So the entry is written the way the file on disk actually looks.
        var providers = try await store.load().providers
        providers.providers["relay"] = PublicProviderConfiguration(
            name: "Relay", adapter: "openai-compatible",
            options: PublicProviderOptions(baseURL: "https://relay.test/v1", apiKey: "{env:LX_UNSET_ROSTER_KEY}"),
            models: ["first": PublicModelConfiguration(name: "First")])
        try await store.saveProviders(providers)
        // Nothing queued: a request that actually went out would fail as `无法连接`, not as this note.
        StubURLProtocol.handler = nil
        StubURLProtocol.queuedResponses = []
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }

        let read = await host.remoteModelIDs(providerID: "relay", session: session)
        #expect(read.ids.isEmpty)
        #expect(read.note?.contains("LX_UNSET_ROSTER_KEY") == true,
                "要指名解析不到的变量：\(String(describing: read.note))")
        #expect(read.note?.contains("无法连接") == false, "凭据没解析出来时不该发出这个注定被拒的请求")
    }
}
