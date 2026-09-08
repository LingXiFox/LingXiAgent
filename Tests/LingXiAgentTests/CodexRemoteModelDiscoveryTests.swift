import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiClient

struct CodexRemoteModelDiscoveryTests {

    // MARK: - Test A: models.dev = [A,B,C,D], remote OAuth = [B,D] -> result = [B,D]
    @Test func testMatrixA_RemoteOAuthCatalogRestrictsStaticMetadata() throws {
        let manifest = CatalogManifest(
            upstreamSource: "https://models.dev",
            upstreamRevision: "2026.09",
            snapshotDate: "2026-09-08",
            sha256: "dummy-hash",
            importerSchemaVersion: 2,
            generatedTimestamp: "2026-09-08T00:00:00Z"
        )
        let staticModels = ["A", "B", "C", "D"].map { id in
            GeneratedModel(
                id: id,
                displayName: "Model \(id)",
                upstreamID: id,
                contextWindow: 128_000,
                maxOutputTokens: 4_096,
                toolCalling: true,
                parallelToolCalling: true,
                vision: false,
                cache: false,
                reasoningCapability: nil,
                structuredOutput: true,
                pricing: nil
            )
        }
        let staticProduct = GeneratedProduct(
            id: "openai-codex",
            vendor: "openai",
            displayName: "OpenAI Codex",
            type: "subscription",
            protocolFamily: "openai_responses",
            endpoint: "https://api.openai.com/v1",
            authMethods: ["oauth"],
            concurrencyLimit: 10,
            quirks: [],
            verificationStatus: "verified",
            requiredAccountFields: [],
            oauth: nil,
            requestProfiles: [:],
            modelDiscovery: .authenticatedRemote,
            models: staticModels
        )
        let catalog = GeneratedProviderCatalog(
            schemaVersion: 2,
            generatedAt: "2026-09-08T00:00:00Z",
            manifest: manifest,
            products: [staticProduct]
        )

        let remoteModels = [
            DiscoveredRemoteModel(id: "B", displayName: "Remote Model B", priority: 10, isDefault: true),
            DiscoveredRemoteModel(id: "D", displayName: "Remote Model D", priority: 20, isDefault: false)
        ]

        let resolved = ResolvedModelCatalogResolver.resolve(
            productID: "openai-codex",
            authenticatedModels: remoteModels,
            staticCatalog: catalog
        )

        let resultIDs = resolved.map(\.modelID)
        #expect(resultIDs == ["B", "D"])
        #expect(!resultIDs.contains("A"))
        #expect(!resultIDs.contains("C"))
    }

    // MARK: - Test B: models.dev = [A], remote = [A, new-model] -> result = [A, new-model], new-model.metadataIncomplete=true
    @Test func testMatrixB_NewRemoteModelPreservedWithMetadataIncomplete() throws {
        let manifest = CatalogManifest(
            upstreamSource: "https://models.dev",
            upstreamRevision: "2026.09",
            snapshotDate: "2026-09-08",
            sha256: "dummy-hash",
            importerSchemaVersion: 2,
            generatedTimestamp: "2026-09-08T00:00:00Z"
        )
        let staticModels = [
            GeneratedModel(
                id: "A",
                displayName: "Model A",
                upstreamID: "A",
                contextWindow: 128_000,
                maxOutputTokens: 4_096,
                toolCalling: true,
                parallelToolCalling: true,
                vision: true,
                cache: false,
                reasoningCapability: nil,
                structuredOutput: true,
                pricing: nil
            )
        ]
        let staticProduct = GeneratedProduct(
            id: "openai-codex",
            vendor: "openai",
            displayName: "OpenAI Codex",
            type: "subscription",
            protocolFamily: "openai_responses",
            endpoint: "https://api.openai.com/v1",
            authMethods: ["oauth"],
            concurrencyLimit: 10,
            quirks: [],
            verificationStatus: "verified",
            requiredAccountFields: [],
            oauth: nil,
            requestProfiles: [:],
            modelDiscovery: .authenticatedRemote,
            models: staticModels
        )
        let catalog = GeneratedProviderCatalog(
            schemaVersion: 2,
            generatedAt: "2026-09-08T00:00:00Z",
            manifest: manifest,
            products: [staticProduct]
        )

        let remoteModels = [
            DiscoveredRemoteModel(id: "A", displayName: "Remote Model A", priority: 10),
            DiscoveredRemoteModel(id: "new-model", displayName: "Cutting Edge New Model", priority: 5, supportedReasoningEfforts: [.high])
        ]

        let resolved = ResolvedModelCatalogResolver.resolve(
            productID: "openai-codex",
            authenticatedModels: remoteModels,
            staticCatalog: catalog
        )

        #expect(resolved.count == 2)

        let resolvedA = resolved.first(where: { $0.modelID == "A" })
        let resolvedNew = resolved.first(where: { $0.modelID == "new-model" })

        #expect(resolvedA != nil)
        #expect(resolvedA?.metadataIncomplete == false)

        #expect(resolvedNew != nil)
        #expect(resolvedNew?.metadataIncomplete == true)
        #expect(resolvedNew?.displayName == "Cutting Edge New Model")
        #expect(resolvedNew?.reasoning == true)
    }

    // MARK: - Test C: Live refresh without restarting TUI
    @Test func testMatrixC_LiveRefreshWithoutRestart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: tempDir)
        let accountRef = "test-account-refresh"

        // Initial state: [A, B]
        try await cache.save(
            productID: "openai-codex",
            accountRef: accountRef,
            models: [
                DiscoveredRemoteModel(id: "A", displayName: "Model A"),
                DiscoveredRemoteModel(id: "B", displayName: "Model B")
            ]
        )

        let record1 = await cache.load(productID: "openai-codex", accountRef: accountRef)
        #expect(record1?.models.map(\.id) == ["A", "B"])

        // Remote discovery occurs live after login: [A, B] -> [A, B, C]
        try await cache.save(
            productID: "openai-codex",
            accountRef: accountRef,
            models: [
                DiscoveredRemoteModel(id: "A", displayName: "Model A"),
                DiscoveredRemoteModel(id: "B", displayName: "Model B"),
                DiscoveredRemoteModel(id: "C", displayName: "Model C")
            ]
        )

        let record2 = await cache.load(productID: "openai-codex", accountRef: accountRef)
        let resolved = ResolvedModelCatalogResolver.resolve(
            productID: "openai-codex",
            authenticatedModels: record2!.models,
            staticCatalog: nil
        )

        #expect(resolved.map(\.modelID) == ["A", "B", "C"])
        #expect(resolved.contains(where: { $0.modelID == "C" }))
    }

    // MARK: - Test D: Remote refresh failure preserves last known good and marks stale
    @Test func testMatrixD_RefreshFailurePreservesLastKnownGoodWithStale() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: tempDir)
        let accountRef = "test-account-failure"

        // Step 1: initial successful fetch
        try await cache.save(
            productID: "openai-codex",
            accountRef: accountRef,
            models: [
                DiscoveredRemoteModel(id: "gpt-4o", displayName: "GPT-4o"),
                DiscoveredRemoteModel(id: "o3-mini", displayName: "o3-mini")
            ]
        )

        // Step 2: refresh fails with HTTP 500
        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }

        let tokens = OAuthTokens(accessToken: "mock-token")
        do {
            _ = try await CodexRemoteModelDiscovery.discoverModels(
                tokens: tokens,
                httpClient: mockClient
            )
            Issue.record("Expected discovery to fail")
        } catch {
            // Failure should mark existing cache as stale without clearing models
            await cache.markStale(productID: "openai-codex", accountRef: accountRef)
        }

        let record = await cache.load(productID: "openai-codex", accountRef: accountRef)
        #expect(record != nil)
        #expect(record?.isStale == true)
        #expect(record?.models.count == 2)
        #expect(record?.models.map(\.id) == ["gpt-4o", "o3-mini"])
    }

    // MARK: - Test E: Multi-account isolation (Account A = [A, B], Account B = [B, C])
    @Test func testMatrixE_MultiAccountIsolation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: tempDir)

        let accountA = "user-alice-plus"
        let accountB = "user-bob-team"

        try await cache.save(
            productID: "openai-codex",
            accountRef: accountA,
            models: [
                DiscoveredRemoteModel(id: "model-A", displayName: "Model A"),
                DiscoveredRemoteModel(id: "model-B", displayName: "Model B")
            ]
        )

        try await cache.save(
            productID: "openai-codex",
            accountRef: accountB,
            models: [
                DiscoveredRemoteModel(id: "model-B", displayName: "Model B"),
                DiscoveredRemoteModel(id: "model-C", displayName: "Model C")
            ]
        )

        let recordA = await cache.load(productID: "openai-codex", accountRef: accountA)
        let recordB = await cache.load(productID: "openai-codex", accountRef: accountB)

        #expect(recordA?.models.map(\.id) == ["model-A", "model-B"])
        #expect(recordB?.models.map(\.id) == ["model-B", "model-C"])

        // Strict isolation: Account A must not leak model-C, Account B must not leak model-A
        #expect(recordA?.models.contains(where: { $0.id == "model-C" }) == false)
        #expect(recordB?.models.contains(where: { $0.id == "model-A" }) == false)
    }

    // MARK: - Test F: Strict separation between openai-api and openai-codex
    @Test func testMatrixF_OpenAIAPIAndOpenAICodexStrictSeparation() throws {
        let codexProfile = BuiltinProviderCatalog.profile(for: "openai-codex")
        let apiProfile = BuiltinProviderCatalog.profile(for: "openai-api")

        #expect(codexProfile != nil)
        #expect(apiProfile != nil)

        // openai-codex must use authenticatedRemote discovery strategy
        #expect(codexProfile?.modelDiscovery == .authenticatedRemote)

        // openai-codex static catalog models in overlay must be empty (preventing hardcoded fake models)
        #expect(codexProfile?.models.isEmpty == true)

        // openai-api has its own static catalog / models definition
        #expect(apiProfile?.models.isEmpty == false)
        #expect(apiProfile?.models.contains(where: { $0.id == "gpt-4o" }) == true)
    }
}
