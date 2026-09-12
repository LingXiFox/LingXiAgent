import XCTest
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

final class ModularProviderRegistryTests: XCTestCase {
    func test27BuiltinProductsLoaded() {
        let all = ProviderRegistry.shared.allProducts()
        XCTAssertEqual(all.count, 27, "Must load exactly 27 modular provider products")

        let byKind = Dictionary(grouping: all, by: { $0.credentialKind })
        let oauthCount = byKind["oauth"]?.count ?? 0
        let subscriptionKeyCount = byKind["subscriptionKey"]?.count ?? 0
        let apiCount = (byKind["apiKey"]?.count ?? 0) + (byKind["none"]?.count ?? 0) + (byKind["gatewayToken"]?.count ?? 0) + (byKind["gateway"]?.count ?? 0) + (byKind["optionalKey"]?.count ?? 0)

        XCTAssertEqual(oauthCount, 5, "Must have exactly 5 OAuth products")
        XCTAssertEqual(subscriptionKeyCount, 5, "Must have exactly 5 Subscription-Key products")
        XCTAssertEqual(apiCount, 17, "Must have exactly 17 API/Gateway/Local products")
    }

    func testNoDiscoveryEndpointHandling() async {
        let noDiscoveryIDs: Set<String> = [
            "zai-api",
            "cloudflare-ai-gateway",
            "zhipu-coding-plan",
            "qwen-coding-plan",
            "gemini-code-assist",
            "anthropic-claude-subscription",
            "xai-grok-subscription"
        ]

        for id in noDiscoveryIDs {
            guard let product = ProviderRegistry.shared.product(id: id) else {
                XCTFail("Product '\(id)' missing from registry")
                continue
            }
            XCTAssertTrue(product.hasNoPublicDiscoveryEndpoint, "\(id) must be recognized as having no public discovery endpoint")

            // Test ModelDiscoveryEngine behavior: must not send network request, must return empty when no LKG exists
            final class AtomicFlag: @unchecked Sendable {
                private let lock = NSLock()
                private var _value = false
                var value: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return _value
                }
                func set() {
                    lock.lock()
                    defer { lock.unlock() }
                    _value = true
                }
            }
            let networkAttempted = AtomicFlag()
            let result = await ModelDiscoveryEngine.shared.discoverModels(
                product: product,
                credential: "test-token-without-lkg",
                httpClient: { _ in
                    networkAttempted.set()
                    throw URLError(.badServerResponse)
                }
            )

            XCTAssertFalse(networkAttempted.value, "ModelDiscoveryEngine must never send network requests for \(id)")
            switch result {
            case .success(let models):
                XCTAssertTrue(models.isEmpty, "Without LKG cache, discovery for \(id) must return empty without error")
            case .failure(let error):
                XCTFail("Unexpected error for \(id): \(error)")
            }
        }
    }

    func testAccountIsolatedCache() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ModelCacheStore(baseDirectory: tempDir)

        let account1 = "user-credential-1"
        let account2 = "user-credential-2"
        let hash1 = ModelCacheStore.computeAccountHash(account1)
        let hash2 = ModelCacheStore.computeAccountHash(account2)
        XCTAssertNotEqual(hash1, hash2, "Account hashes must be unique per credential")

        let endpoint1 = URL(string: "https://api.openai.com/v1")!
        let endpoint2 = URL(string: "https://custom.gateway.com/v1")!
        let epHash1 = ModelCacheStore.computeEndpointHash(endpoint1)
        let epHash2 = ModelCacheStore.computeEndpointHash(endpoint2)
        XCTAssertNotEqual(epHash1, epHash2, "Endpoint hashes must be unique per endpoint")

        let model = DiscoveredRemoteModel(id: "gpt-5-test", displayName: "GPT 5 Test")
        try await store.save(
            productID: "openai-api",
            accountHash: hash1,
            endpointHash: epHash1,
            endpointURL: endpoint1,
            models: [model],
            source: "Test"
        )

        // Account 1 at Endpoint 1 must hit cache
        let hit = await store.load(productID: "openai-api", accountHash: hash1, endpointHash: epHash1)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.models.first?.id, "gpt-5-test")

        // Account 2 at Endpoint 1 must miss cache (Strict isolation)
        let missAccount = await store.load(productID: "openai-api", accountHash: hash2, endpointHash: epHash1)
        XCTAssertNil(missAccount, "Cache must never leak across accounts")

        // Account 1 at Endpoint 2 must miss cache (Strict endpoint isolation)
        let missEndpoint = await store.load(productID: "openai-api", accountHash: hash1, endpointHash: epHash2)
        XCTAssertNil(missEndpoint, "Cache must never leak across different endpoints")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testProtocolDriverRegistry() {
        let registry = ProtocolDriverRegistry.shared
        XCTAssertNotNil(registry.driver(for: "openaiChat"))
        XCTAssertNotNil(registry.driver(for: "openaiResponses"))
        XCTAssertNotNil(registry.driver(for: "anthropicMessages"))
        XCTAssertNotNil(registry.driver(for: "geminiNative"))
        XCTAssertNotNil(registry.driver(for: "ollamaNative"))

        if let openai = ProviderRegistry.shared.product(id: "openai-api") {
            let driver = registry.resolveDriver(for: openai)
            XCTAssertEqual(driver.protocolIdentifier, "openaiResponses")
        }
        if let anthropic = ProviderRegistry.shared.product(id: "anthropic-api") {
            let driver = registry.resolveDriver(for: anthropic)
            XCTAssertEqual(driver.protocolIdentifier, "anthropicMessages")
        }
    }

    func testBuiltinCatalogBackwardCompatibility() {
        let defs = BuiltinProviderCatalog.definitions
        XCTAssertEqual(defs.count, 27)

        let connectable = BuiltinProviderCatalog.connectableProducts()
        XCTAssertFalse(connectable.isEmpty)

        let anthropicProfile = BuiltinProviderCatalog.profile(for: "anthropic-api")
        XCTAssertNotNil(anthropicProfile)
        XCTAssertEqual(anthropicProfile?.vendor, "anthropic")

        let hasQuirk = BuiltinProviderCatalog.hasQuirk(providerID: "anthropic-api", quirk: "requiresAnthropicVersionHeader")
        XCTAssertTrue(hasQuirk)
    }
}
