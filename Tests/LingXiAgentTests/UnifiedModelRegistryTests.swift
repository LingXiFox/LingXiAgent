import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiClient

/// Tests for the unified model registry: dynamic discovery, overlay semantics,
/// the registry/account split, and the guarantees the previous design broke.
///
/// The lettered names correspond to the acceptance list this refactor was
/// specified against.
struct UnifiedModelRegistryTests {

    // MARK: - Fixtures

    static func product(
        id: String = "test-api",
        vendor: String = "testvendor",
        discovery: ModelDiscoveryStrategy = .endpoint,
        runtime: RuntimeSupport = .implemented,
        authMethods: [String] = ["apiKey"]
    ) -> RegistryProduct {
        RegistryProduct(
            id: id,
            vendorID: vendor,
            displayName: "Test API",
            type: "cloudAPI",
            authStrategy: "apiKey",
            authMethods: authMethods,
            protocolFamily: "openai_chat",
            discoveryStrategy: discovery == .endpoint ? "apiModels" : "\(discovery)",
            endpoint: "https://api.example.com/v1",
            runtimeSupport: runtime.rawValue,
            modelIDs: []
        )
    }

    static func record(
        _ id: String,
        product: String = "test-api",
        status: RegistryModelStatus = .active,
        incomplete: Bool = false,
        contextWindow: Int? = nil
    ) -> RegistryModelRecord {
        RegistryModelRecord(
            id: id,
            productID: product,
            displayName: id.uppercased(),
            status: status.rawValue,
            capabilities: RegistryCapabilities(contextWindow: contextWindow),
            metadataIncomplete: incomplete,
            source: RegistryModelRecord.sourceUpstreamDiscovery
        )
    }

    static func discovered(_ id: String, contextWindow: Int? = nil) -> DiscoveredRemoteModel {
        DiscoveredRemoteModel(id: id, displayName: id, contextWindow: contextWindow)
    }

    // MARK: - A. Upstream listing normalizes into registry models

    @Test func testA_upstreamListingNormalizes() throws {
        let body = Data("""
        {"object":"list","data":[
            {"id":"model-a"},{"id":"model-b"},{"id":"model-c"}
        ]}
        """.utf8)

        let parsed = try ModelListAdapters.parse(kind: ModelListAdapters.openAIModels, data: body, source: "test")

        #expect(parsed.count == 3)
        #expect(parsed.map(\.id) == ["model-a", "model-b", "model-c"])
        // Every discovered model carries a display name even when the upstream
        // states none, so the UI never shows a blank row.
        #expect(parsed.allSatisfy { !$0.displayName.isEmpty })
    }

    // MARK: - B. An overlay never filters a model it does not know

    @Test func testB_unknownUpstreamModelIsKeptAndFlagged() {
        // The overlay describes A and B only; the upstream listing adds C.
        let registryModels = [
            Self.record("model-a"),
            Self.record("model-b"),
            Self.record("model-c", incomplete: true)
        ]

        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: registryModels,
            accountModels: [Self.discovered("model-a"), Self.discovered("model-b"), Self.discovered("model-c")],
            isConfigured: true
        )

        let ids = outcome.models.map(\.modelID)
        #expect(ids.contains("model-c"), "a model absent from the overlay must still be offered")

        let unknown = outcome.models.first { $0.modelID == "model-c" }
        #expect(unknown?.metadataIncomplete == true, "an undescribed model must be flagged incomplete")
        #expect(outcome.withheldByStatus.isEmpty, "nothing should be withheld merely for being unknown")
    }

    @Test func testB2_newlyDiscoveredModelNeedsNoClientChange() {
        // Nothing in this path is keyed to a known model ID: a model invented
        // here appears purely because the upstream listing returned it.
        let novelID = "brand-new-model-\(UUID().uuidString.prefix(8))"

        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [],
            accountModels: [Self.discovered(novelID)],
            isConfigured: true
        )

        #expect(outcome.models.map(\.modelID) == [novelID])
        #expect(outcome.models.first?.metadataIncomplete == true)
    }

    // MARK: - C. Account discovery is the authority on availability

    @Test func testC_accountAvailabilityNarrowsTheRegistry() {
        // Registry knows A B C D; this account can reach only A and C.
        let registryModels = [
            Self.record("model-a"), Self.record("model-b"),
            Self.record("model-c"), Self.record("model-d")
        ]
        let accountModels = [Self.discovered("model-a"), Self.discovered("model-c")]

        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: registryModels,
            accountModels: accountModels,
            isConfigured: true
        )

        #expect(outcome.models.map(\.modelID) == ["model-a", "model-c"])
        let offered = Set(outcome.models.map(\.modelID))
        #expect(!offered.contains("model-b"), "a model the account cannot reach must not be offered")
        #expect(!offered.contains("model-d"), "a model the account cannot reach must not be offered")
    }

    @Test func testC2_accountReachableModelAbsentFromRegistryIsStillOffered() {
        // The account can reach something the registry has never catalogued.
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [Self.record("model-a")],
            accountModels: [Self.discovered("model-a"), Self.discovered("unlisted-model")],
            isConfigured: true
        )

        let ids = outcome.models.map(\.modelID)
        #expect(ids.contains("unlisted-model"))
        #expect(outcome.models.first { $0.modelID == "unlisted-model" }?.metadataIncomplete == true)
    }

    @Test func testC3_withoutAccountViewTheRegistrySuppliesTheList() {
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [Self.record("model-a"), Self.record("model-b")],
            accountModels: [],
            isConfigured: false
        )

        #expect(outcome.models.count == 2)
        #expect(outcome.models.allSatisfy { !$0.configured })
    }

    // MARK: - D. API and OAuth products stay isolated

    @Test func testD_oauthAndAPIProductsDoNotShareAvailability() {
        let apiProduct = Self.product(id: "vendor-api", discovery: .endpoint)
        let oauthProduct = Self.product(id: "vendor-codex", discovery: .authenticatedRemote)

        let apiOutcome = ModelAvailabilityResolver.resolve(
            product: apiProduct,
            registryModels: [Self.record("api-model", product: "vendor-api")],
            accountModels: [Self.discovered("api-model")],
            isConfigured: true
        )
        let oauthOutcome = ModelAvailabilityResolver.resolve(
            product: oauthProduct,
            registryModels: [Self.record("codex-model", product: "vendor-codex")],
            accountModels: [],
            isConfigured: true
        )

        // The API product's discovery result must never appear under the OAuth
        // product, and vice versa.
        #expect(apiOutcome.models.allSatisfy { $0.providerID == "vendor-api" })
        #expect(oauthOutcome.models.allSatisfy { $0.providerID == "vendor-codex" })
        #expect(!apiOutcome.models.contains { $0.modelID == "codex-model" })
        #expect(!oauthOutcome.models.contains { $0.modelID == "api-model" })
    }

    // MARK: - E. Deprecated models stay out of default selection

    @Test func testE_deprecatedModelsAreWithheldByDefault() {
        let registryModels = [
            Self.record("model-old", status: .deprecated),
            Self.record("model-retired", status: .retired),
            Self.record("model-new", status: .active)
        ]
        let accountModels = [
            Self.discovered("model-old"), Self.discovered("model-retired"), Self.discovered("model-new")
        ]

        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: registryModels,
            accountModels: accountModels,
            isConfigured: true
        )

        #expect(outcome.models.map(\.modelID) == ["model-new"])
        #expect(Set(outcome.withheldByStatus) == ["model-old", "model-retired"])
    }

    @Test func testE2_compatibilityModeRestoresDeprecatedModels() {
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [Self.record("model-old", status: .deprecated), Self.record("model-new")],
            accountModels: [Self.discovered("model-old"), Self.discovered("model-new")],
            isConfigured: true,
            compatibilityMode: true
        )

        #expect(Set(outcome.models.map(\.modelID)) == ["model-old", "model-new"])
        #expect(outcome.withheldByStatus.isEmpty)
    }

    @Test func testE3_legacyOnlyAccountStillSeesItsModels() {
        // The account can only reach superseded models. Hiding them all would
        // leave the user with nothing to select.
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [Self.record("model-old", status: .deprecated)],
            accountModels: [Self.discovered("model-old")],
            isConfigured: true
        )

        #expect(outcome.models.map(\.modelID) == ["model-old"])
        #expect(outcome.fellBackToLegacyOnly)
    }

    @Test func testE4_previewModelsRemainSelectable() {
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(),
            registryModels: [Self.record("model-preview", status: .preview)],
            accountModels: [Self.discovered("model-preview")],
            isConfigured: true
        )
        #expect(outcome.models.count == 1)
    }

    // MARK: - F. A failed refresh keeps the last known good list

    @Test func testF_failedRefreshPreservesLastKnownGood() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: cacheDir)
        let good = [Self.discovered("model-a"), Self.discovered("model-b")]
        _ = try await cache.save(productID: "test-api", accountRef: "acct", models: good)

        // A refresh against an unreachable upstream.
        let product = Self.product()
        let failing = RegistryProduct(
            id: product.id, vendorID: product.vendorID, displayName: product.displayName,
            type: product.type, authStrategy: product.authStrategy, authMethods: product.authMethods,
            protocolFamily: product.protocolFamily, discoveryStrategy: product.discoveryStrategy,
            endpoint: product.endpoint, runtimeSupport: product.runtimeSupport,
            modelIDs: [],
            discoveryProfile: RegistryDiscoveryProfile(
                id: "unreachable", kind: ModelListAdapters.openAIModels,
                url: "https://127.0.0.1:1/models", auth: "none", isPublic: false
            )
        )

        let result = await AccountModelDiscovery.refresh(
            product: failing, accountRef: "acct", credential: "test-key", cache: cache
        )
        if case .success = result {
            Issue.record("expected the refresh to fail")
        }

        // The cached list must survive the failure.
        let reloaded = await cache.load(productID: "test-api", accountRef: "acct")
        #expect(reloaded?.models.count == 2)
        #expect(reloaded?.models.map(\.id) == ["model-a", "model-b"])
    }

    // MARK: - G. ETag revalidation avoids re-downloading the catalog

    @Test func testG_matchingETagSkipsDownload() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let client = ModelRegistryClient(
            baseURL: URL(string: "https://registry.invalid")!,
            cacheDirectory: cacheDir
        )

        let catalog = RegistryCatalog(
            metadata: RegistryCatalogMetadata(
                schemaVersion: 1, catalogRevision: "rev-1", generatedAt: "2026-09-11T00:00:00Z",
                sourceRevision: "src-1", sha256: String(repeating: "a", count: 64)
            ),
            vendors: [], products: [Self.product()], models: [Self.record("model-a")]
        )
        let encoded = try JSONEncoder().encode(catalog)

        // First fetch: 200 with an ETag.
        let first = await client.fetch(maxAge: 0) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": "\"rev-1\""]
            )!
            return (encoded, response)
        }
        guard case .updated = first else {
            Issue.record("expected the first fetch to update the cache")
            return
        }

        // Second fetch: the server reports 304, and no body is transferred.
        let second = await client.fetch(maxAge: 0) { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"rev-1\"")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        guard case let .notModified(revalidated) = second else {
            Issue.record("expected a 304 to be reported as notModified")
            return
        }
        #expect(revalidated.models.count == 1)
    }

    @Test func testG2_unreachableRegistryFallsBackToCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let client = ModelRegistryClient(
            baseURL: URL(string: "https://registry.invalid")!,
            cacheDirectory: cacheDir
        )
        let catalog = RegistryCatalog(
            metadata: RegistryCatalogMetadata(
                schemaVersion: 1, catalogRevision: "rev-1", generatedAt: "2026-09-11T00:00:00Z",
                sourceRevision: "src-1", sha256: String(repeating: "b", count: 64)
            ),
            vendors: [], products: [], models: [Self.record("model-a")]
        )
        let encoded = try JSONEncoder().encode(catalog)
        _ = await client.fetch(maxAge: 0) { _ in
            let response = HTTPURLResponse(url: URL(string: "https://registry.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (encoded, response)
        }

        // Now the registry is unreachable and the cache is stale.
        let outcome = await client.fetch(maxAge: 0) { _ in
            throw URLError(.cannotConnectToHost)
        }
        guard case let .stale(fallback, _) = outcome else {
            Issue.record("expected a stale fallback when the registry is unreachable")
            return
        }
        #expect(fallback.models.count == 1)
    }

    // MARK: - H. Every wire format is absorbed in the adapter layer

    @Test func testH_differingWireFormatsNormalizeToTheSameShape() throws {
        let cases: [(kind: String, body: String, expected: [String])] = [
            (ModelListAdapters.openAIModels, #"{"data":[{"id":"a"}]}"#, ["a"]),
            (ModelListAdapters.anthropicModels, #"{"data":[{"id":"b","display_name":"B"}]}"#, ["b"]),
            (ModelListAdapters.geminiModels, #"{"models":[{"name":"models/c"}]}"#, ["c"]),
            (ModelListAdapters.ollamaTags, #"{"models":[{"name":"d:latest"}]}"#, ["d:latest"]),
            (ModelListAdapters.openRouterModels, #"{"data":[{"id":"e","supported_parameters":["tools"]}]}"#, ["e"]),
            (ModelListAdapters.plainArray, #"["f"]"#, ["f"]),
        ]

        for testCase in cases {
            let parsed = try ModelListAdapters.parse(
                kind: testCase.kind,
                data: Data(testCase.body.utf8),
                source: testCase.kind
            )
            #expect(parsed.map(\.id) == testCase.expected, "kind \(testCase.kind) normalized incorrectly")
        }
    }

    @Test func testH2_unknownAdapterKindStillYieldsModels() throws {
        // A registry that introduces a new kind must not make models vanish for
        // clients that have not shipped an adapter for it yet.
        let body = Data(#"{"models":[{"slug":"m1"},{"slug":"m2"}]}"#.utf8)
        let parsed = try ModelListAdapters.parse(kind: "kind-from-the-future", data: body, source: "test")
        #expect(parsed.map(\.id) == ["m1", "m2"])
    }

    @Test func testH3_geminiCollectionPrefixIsStripped() throws {
        let parsed = try ModelListAdapters.parse(
            kind: ModelListAdapters.geminiModels,
            data: Data(#"{"models":[{"name":"models/gemini-x","displayName":"Gemini X"}]}"#.utf8),
            source: "test"
        )
        #expect(parsed.first?.id == "gemini-x")
        #expect(parsed.first?.upstreamModelID == "models/gemini-x", "upstreamModelID must be preserved verbatim")
        #expect(parsed.first?.displayName == "Gemini X", "displayName must not mix reasoning/profile info")
    }

    // MARK: - I. Runtime support gates executability

    @Test func testI_runtimeUnsupportedProductOffersNothing() {
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(runtime: .unsupported),
            registryModels: [Self.record("model-a")],
            accountModels: [Self.discovered("model-a")],
            isConfigured: true
        )

        #expect(outcome.runtimeUnsupported)
        #expect(outcome.models.isEmpty, "a product the runtime cannot execute must not be offered")
    }

    @Test func testI2_partialRuntimeSupportIsStillRunnable() {
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(runtime: .partial),
            registryModels: [Self.record("model-a")],
            accountModels: [Self.discovered("model-a")],
            isConfigured: true
        )
        #expect(!outcome.runtimeUnsupported)
        #expect(outcome.models.count == 1)
    }

    // MARK: - The watermark filter lives in exactly one place

    @Test func testWatermarkVariantsAreNotUserSelectable() {
        #expect(!AccountModelDiscovery.isUserSelectable(modelID: "gpt-x-wm"))
        #expect(!AccountModelDiscovery.isUserSelectable(modelID: "gpt-wm-x"))
        #expect(AccountModelDiscovery.isUserSelectable(modelID: "gpt-x"))
    }

    // MARK: - Request construction carries the credential only to the vendor

    @Test func testDiscoveryRequestAppliesCredentialPerAuthShape() throws {
        let bearer = RegistryDiscoveryProfile(
            id: "p1", kind: ModelListAdapters.openAIModels,
            url: "https://api.example.com/v1/models", auth: "bearer"
        )
        let bearerRequest = try #require(DiscoveryRequestBuilder.build(profile: bearer, credential: "sk-test"))
        #expect(bearerRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let header = RegistryDiscoveryProfile(
            id: "p2", kind: ModelListAdapters.anthropicModels,
            url: "https://api.example.com/v1/models", auth: "apiKeyHeader"
        )
        let headerRequest = try #require(DiscoveryRequestBuilder.build(profile: header, credential: "key-1"))
        #expect(headerRequest.value(forHTTPHeaderField: "x-api-key") == "key-1")
        #expect(headerRequest.value(forHTTPHeaderField: "Authorization") == nil)

        let query = RegistryDiscoveryProfile(
            id: "p3", kind: ModelListAdapters.geminiModels,
            url: "https://api.example.com/v1beta/models", auth: "apiKeyQuery", authKeyParam: "key"
        )
        let queryRequest = try #require(DiscoveryRequestBuilder.build(profile: query, credential: "g-key"))
        let url = try #require(queryRequest.url)
        #expect(url.query?.contains("key=g-key") == true)
    }

    @Test func testPublicProfileNeedsNoCredential() throws {
        let profile = RegistryDiscoveryProfile(
            id: "public", kind: ModelListAdapters.openRouterModels,
            url: "https://openrouter.ai/api/v1/models", auth: "none", isPublic: true
        )
        let request = try #require(DiscoveryRequestBuilder.build(profile: profile, credential: nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Status semantics

    @Test func testStatusSelectabilityMatchesSpec() {
        #expect(RegistryModelStatus.active.isSelectable)
        #expect(RegistryModelStatus.preview.isSelectable)
        #expect(!RegistryModelStatus.deprecated.isSelectable)
        #expect(!RegistryModelStatus.retired.isSelectable)
        #expect(!RegistryModelStatus.unknown.isSelectable)
    }

    @Test func testUnknownStatusDecodesLeniently() {
        // A server that adds a status must not break older clients.
        #expect(RegistryModelStatus(lenient: "experimental") == .unknown)
        #expect(RegistryModelStatus(lenient: "active") == .active)
    }

    @Test func testCatalogDecodesPartialDocuments() throws {
        // A catalog with no discoveryCache section must still decode.
        let json = """
        {
          "metadata": {"schemaVersion":1,"catalogRevision":"r","generatedAt":"t","sourceRevision":"s","sha256":"x"},
          "vendors": [{"id":"v","displayName":"V"}],
          "products": [{
            "id":"p","vendorID":"v","displayName":"P","authStrategy":"apiKey",
            "protocolFamily":"openai_chat","discoveryStrategy":"apiModels",
            "runtimeSupport":"implemented","modelIDs":["m"]
          }],
          "models": [{
            "id":"m","productID":"p","displayName":"M","status":"active",
            "capabilities":{},"metadataIncomplete":false,"source":"upstream-discovery"
          }]
        }
        """
        let catalog = try JSONDecoder().decode(RegistryCatalog.self, from: Data(json.utf8))
        #expect(catalog.products.count == 1)
        #expect(catalog.models.count == 1)
        #expect(catalog.product(id: "p")?.runtime == .implemented)
        #expect(catalog.models(productID: "p").map(\.id) == ["m"])
    }

    // MARK: - ChatGPT subscription backend

    @Test func testChatGPTBackendAdapterParsesSubscriptionListing() throws {
        let body = Data("""
        {"models":[
          {"slug":"gpt-x","title":"GPT X","context_window":200000,"max_output_tokens":100000,
           "supported_reasoning_levels":["low","medium","high"],
           "capabilities":{"tools":true,"vision":true}},
          {"slug":"gpt-x-wm","title":"Internal mirror"}
        ]}
        """.utf8)

        let parsed = try ModelListAdapters.parse(kind: ModelListAdapters.chatGPTBackend, data: body, source: "test")
        #expect(parsed.count == 2)

        let model = try #require(parsed.first { $0.id == "gpt-x" })
        #expect(model.displayName == "GPT X")
        #expect(model.contextWindow == 200_000)
        #expect(model.vision)
        #expect(model.supportedReasoningEfforts == [.low, .medium, .high])

        // The adapter normalizes; selection policy is applied uniformly after.
        #expect(!AccountModelDiscovery.isUserSelectable(modelID: "gpt-x-wm"))
    }

    // MARK: - Account isolation

    @Test func testAccountScopedCachesDoNotLeakAcrossAccounts() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: cacheDir)
        _ = try await cache.save(productID: "shared-product", accountRef: "account-a", models: [Self.discovered("a-only")])
        _ = try await cache.save(productID: "shared-product", accountRef: "account-b", models: [Self.discovered("b-only")])

        let a = await cache.load(productID: "shared-product", accountRef: "account-a")
        let b = await cache.load(productID: "shared-product", accountRef: "account-b")

        #expect(a?.models.map(\.id) == ["a-only"])
        #expect(b?.models.map(\.id) == ["b-only"])
    }

    @Test func testAccountIdentityHashesAreStableAndDistinct() {
        let first = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: "token-a")
        let second = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: "token-a")
        let other = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: "token-b")

        #expect(first == second, "the same credential must map to the same cache slot")
        #expect(first != other, "different credentials must not share a cache slot")
    }

    @Test func testGlobalBaselineNeverFallsBackToSelectableModelResolution() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let cache = AccountScopedCatalogCache(baseCacheDirectory: cacheDir)

        // Seed a static global baseline with historical models
        let baselineModels = [
            Self.discovered("gpt-4o"),
            Self.discovered("o1"),
            Self.discovered("o3-mini")
        ]
        _ = try await cache.save(
            productID: "openai-api",
            accountRef: "global",
            models: baselineModels,
            source: "LingXiFox Verified Official Baseline"
        )

        // 1. Explicitly requesting "global" returns the baseline (for migration/history only)
        let globalLoaded = await cache.load(productID: "openai-api", accountRef: "global")
        #expect(globalLoaded?.models.count == 3)
        #expect(globalLoaded?.source == "LingXiFox Verified Official Baseline")

        // 2. An account without an LKG cache must NEVER fall back to global baseline
        let userAccountLoaded = await cache.load(productID: "openai-api", accountRef: "user-acct-without-cache")
        #expect(userAccountLoaded == nil, "account without cache must never fall back to global baseline")

        // 3. Resolving selectable models with empty account view & no LKG returns empty/unavailable
        let outcome = ModelAvailabilityResolver.resolve(
            product: Self.product(id: "openai-api", discovery: .authenticatedRemote),
            registryModels: [],
            accountModels: userAccountLoaded?.models ?? [],
            isConfigured: true
        )
        #expect(outcome.models.isEmpty, "selectable model resolution must be empty when no account LKG exists")
    }

    // MARK: - Verification semantics & Product-level verification

    @Test func testListingVerifiedSemanticsAndCleanDisplayName() {
        // Discovered record: listingVerified must be true, upstreamModelID preserved verbatim.
        let discoveredRecord = RegistryModelRecord(
            id: "gemini-2.5-pro",
            productID: "google-gemini-api",
            displayName: "Gemini 2.5 Pro",
            status: "active",
            capabilities: RegistryCapabilities(contextWindow: 1_000_000),
            metadataIncomplete: false,
            source: RegistryModelRecord.sourceUpstreamDiscovery,
            upstreamModelID: "models/gemini-2.5-pro",
            sourceAuthority: "generativelanguage.googleapis.com",
            sourceAuthorityKind: "vendorFirstParty",
            discoveredFrom: "https://generativelanguage.googleapis.com/v1beta/models",
            listingVerified: true,
            namingVerification: "verified",
            displayNameSource: "displayName"
        )
        #expect(discoveredRecord.listingVerified, "a model returned by a real listing must have listingVerified=true")
        #expect(discoveredRecord.upstreamModelID == "models/gemini-2.5-pro", "upstreamModelID must be preserved verbatim")
        #expect(discoveredRecord.displayName == "Gemini 2.5 Pro", "displayName must not contain reasoning or profile metadata")
        #expect(discoveredRecord.sourceAuthorityKind == "vendorFirstParty")

        // Static metadata: listingVerified must be false.
        let staticRecord = RegistryModelRecord(
            id: "gemini-static",
            productID: "google-gemini-api",
            displayName: "Gemini Static",
            status: "active",
            source: RegistryModelRecord.sourceStaticMetadata,
            upstreamModelID: "gemini-static",
            listingVerified: false,
            namingVerification: "unverified",
            displayNameSource: "overlay"
        )
        #expect(!staticRecord.listingVerified, "static metadata must have listingVerified=false")
    }

    @Test func testOAuthProductWithoutDiscoveryHasNoModelRecords() {
        // An OAuth product lacking discovery implementation has no ModelRecords,
        // but its RegistryProduct holds discoveryImplementation and product-level namingVerification.
        let oauthProduct = RegistryProduct(
            id: "anthropic-claude-subscription",
            vendorID: "anthropic",
            displayName: "Claude Subscription",
            type: "subscription",
            authStrategy: "oauth",
            protocolFamily: "anthropic_messages",
            discoveryStrategy: "authenticatedRemote",
            runtimeSupport: "partial",
            discoveryImplementation: DiscoveryImplementation(status: "missing", backend: "none"),
            namingVerification: "unverified",
            modelIDs: []
        )

        #expect(oauthProduct.discoveryImplementation?.status == "missing")
        #expect(oauthProduct.namingVerification == "unverified")
        #expect(oauthProduct.modelIDs.isEmpty, "OAuth product lacking discovery must have no modelIDs")

        let catalog = RegistryCatalog(
            metadata: RegistryCatalogMetadata(
                schemaVersion: 1,
                catalogRevision: "rev-1",
                generatedAt: "2026-09-11T00:00:00Z",
                sourceRevision: "src-1",
                sha256: "abc"
            ),
            vendors: [RegistryVendor(id: "anthropic", displayName: "Anthropic")],
            products: [oauthProduct],
            models: [] // No ModelRecords for missing discovery OAuth product
        )

        #expect(catalog.models(productID: "anthropic-claude-subscription").isEmpty)
        #expect(catalog.product(id: "anthropic-claude-subscription")?.discoveryImplementation?.status == "missing")
        #expect(catalog.product(id: "anthropic-claude-subscription")?.namingVerification == "unverified")
    }

    @Test func testCoreHostDiscoversOAuthModelsWithoutRemoteCatalog() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configStore = try ConfigurationStore(dataRoot: tempDir)
        _ = try await configStore.load()
        let providersConfig = ProvidersConfiguration(
            schema: "https://lingxiagent.lingxifox.cn/schema/providers.json",
            version: 1,
            model: "openai-codex/gpt-6-astra",
            providers: [
                "openai-codex": PublicProviderConfiguration(
                    name: "OpenAI Codex",
                    adapter: "openai-compatible",
                    options: PublicProviderOptions(baseURL: "https://api.openai.com/v1"),
                    models: [:]
                ),
                "bai": PublicProviderConfiguration(
                    name: "BAI",
                    adapter: "openai-compatible",
                    options: PublicProviderOptions(baseURL: "https://token.sensenova.cn/v1"),
                    models: [
                        "deepseek-v4-flash": PublicModelConfiguration(
                            name: "Deepseek v4 Flash",
                            limit: PublicModelLimit(context: 1000000, output: 100000)
                        )
                    ]
                )
            ]
        )
        try await configStore.saveProviders(providersConfig)
        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase")
        
        // Seed OAuth token into credential store
        let oauthSecret = "mock-oauth-token-with-sub"
        let tokenRef = CredentialRef("provider-openai-codex-oauth")
        try await credStore.setSecret(oauthSecret, for: tokenRef)

        // Seed account discovery cache
        let accountRef = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: oauthSecret)
        let discoveredModels = [
            DiscoveredRemoteModel(id: "gpt-6-astra", displayName: "GPT-6-Astra", visibility: "list"),
            DiscoveredRemoteModel(id: "gpt-reserve", displayName: "GPT-Reserve", visibility: "hide"),
            DiscoveredRemoteModel(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", visibility: "list")
        ]
        try await AccountScopedCatalogCache.shared.save(
            productID: "openai-codex",
            accountRef: accountRef,
            models: discoveredModels
        )

        let host = try CoreHost(
            configurationStore: configStore,
            credentialStore: credStore
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let models = try await client.listProviderModels()

        // Must include configured bai custom model
        #expect(models.contains(where: { $0.id == "bai/deepseek-v4-flash" && $0.configured }))

        // Must include discovered openai-codex models with visibility: "list"
        #expect(models.contains(where: { $0.id == "openai-codex/gpt-6-astra" && $0.configured }))
        #expect(models.contains(where: { $0.id == "openai-codex/gpt-5.6-sol" && $0.configured }))

        // Must filter out hidden model
        #expect(!models.contains(where: { $0.id == "openai-codex/gpt-reserve" }))
    }

    @Test func testOpenAICodexAccountIDExtraction() {
        // Mock JWT with chatgpt_account_id in auth payload: {"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123456"}}
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjM0NTYifX0"
        let token = "\(header).\(payload).signature"
        let extracted = CodexRemoteModelDiscovery.extractChatGPTAccountID(from: token)
        #expect(extracted == "acct-123456")
    }
}
