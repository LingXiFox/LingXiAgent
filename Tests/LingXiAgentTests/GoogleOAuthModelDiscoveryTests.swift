import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct GoogleOAuthModelDiscoveryTests {

    // MARK: - 1. Data-Driven Discovery Registry (No Product Name Switch)

    @Test func backendRegistryDispatchesWithoutProductNameKnowledge() async throws {
        let registry = AuthenticatedDiscoveryBackendRegistry.shared

        // 1. Check registered backends
        let codexBackend = registry.backend(for: "codexAuthenticatedCatalog")
        #expect(codexBackend != nil)
        #expect(codexBackend?.backendID == "codexAuthenticatedCatalog")

        let agyBackend = registry.backend(for: "antigravityAuthenticatedCatalog")
        #expect(agyBackend != nil)
        #expect(agyBackend?.backendID == "antigravityAuthenticatedCatalog")

        // 2. Gemini Code Assist backend is strictly unregistered until empirical evidence is gathered
        let gcaBackend = registry.backend(for: "googleCodeAssistCatalog")
        #expect(gcaBackend == nil)

        // 3. Product resolution through discoveryImplementation
        let agyProduct = BuiltinProviderCatalog.registryProduct(id: "antigravity")
        #expect(agyProduct?.discoveryImplementation?.status == "implemented")
        #expect(agyProduct?.discoveryImplementation?.backend == "antigravityAuthenticatedCatalog")

        let gcaProduct = BuiltinProviderCatalog.registryProduct(id: "gemini-code-assist")
        #expect(gcaProduct?.discoveryImplementation?.status == "missing")
        #expect(gcaProduct?.discoveryImplementation?.backend == "googleCodeAssistCatalog")

        // 4. Calling discoverAuthenticatedRemote on missing implementation throws implementationMissing
        if let gca = gcaProduct {
            await #expect(throws: AccountModelDiscovery.DiscoveryFailure.implementationMissing(productID: "gemini-code-assist")) {
                try await AccountModelDiscovery.discoverAuthenticatedRemote(
                    product: gca,
                    accessToken: "mock-token"
                )
            }
        }
    }

    // MARK: - 2. Layered Project & Account Bootstrap

    @Test func bootstrapPrefersExplicitProjectConfiguration() async throws {
        let context = AuthenticatedDiscoveryContext(
            accountIdentity: "user@example.com",
            project: "projects/my-explicit-proj-123",
            tier: "FREE_TIER"
        )
        let result = try await GoogleAccountProjectBootstrap.bootstrap(
            tokens: OAuthTokens(accessToken: "mock-token"),
            context: context
        )

        #expect(result.project == "projects/my-explicit-proj-123")
        #expect(result.projectSource == .explicitConfig)
        #expect(result.accountIdentity == "user@example.com")
        #expect(result.tier == "FREE_TIER")
    }

    @Test func bootstrapDiscoversUpstreamCompanionProjectAndTier() async throws {
        let mockBootstrapJSON = """
        {
            "cloudaicompanion_project": "projects/companion-proj-789",
            "current_tier": "AGY_BUSINESS_PAYGO_TIER"
        }
        """

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            #expect(req.url?.path.contains("loadCodeAssist") == true)
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
            let data = mockBootstrapJSON.data(using: .utf8)!
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let result = try await GoogleAccountProjectBootstrap.bootstrap(
            tokens: OAuthTokens(accessToken: "test-access-token"),
            httpClient: mockClient
        )

        #expect(result.project == "projects/companion-proj-789")
        #expect(result.projectSource == .upstreamBootstrap)
        #expect(result.tier == "AGY_BUSINESS_PAYGO_TIER")
        #expect(result.rawMetadata["cloudaicompanion_project"] == "projects/companion-proj-789")
    }

    @Test func bootstrapNeverFabricatesSyntheticProjectWhenUpstreamFails() async throws {
        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let data = "{}".data(using: .utf8)!
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let result = try await GoogleAccountProjectBootstrap.bootstrap(
            tokens: OAuthTokens(accessToken: "test-access-token"),
            httpClient: mockClient
        )

        #expect(result.project == nil)
        #expect(result.projectSource == .none)
    }

    // MARK: - 3. Antigravity 1.2.1 Observed Evidence Parsing

    @Test func antigravityModelParsingPreservesVerbatim11ModelsAndNativeMetadata() async throws {
        // Matches the exact 11 models observed from agy 1.2.1
        let mockCatalogJSON = """
        {
            "default_agent_model_id": "gemini-3.8-flash-high",
            "models": {
                "gemini-3.8-flash-high": {
                    "display_name": "Gemini 3.8 Flash (High)",
                    "supports_thinking": true,
                    "thinking_level": "high",
                    "thinking_budget": 24576,
                    "min_thinking_budget": 1024,
                    "max_tokens": 1048576,
                    "max_output_tokens": 65536,
                    "supports_images": true,
                    "disabled": false,
                    "preview": false,
                    "is_internal": false
                },
                "gemini-3.8-flash-medium": {
                    "display_name": "Gemini 3.8 Flash (Medium)",
                    "supports_thinking": true,
                    "thinking_level": "medium",
                    "disabled": false
                },
                "gemini-3.8-flash-low": {
                    "display_name": "Gemini 3.8 Flash (Low)",
                    "supports_thinking": true,
                    "thinking_level": "low",
                    "disabled": false
                },
                "gemini-3.7-flash-high": {
                    "display_name": "Gemini 3.7 Flash (High)",
                    "supports_thinking": true,
                    "thinking_level": "high",
                    "disabled": false
                },
                "gemini-3.7-flash-medium": {
                    "display_name": "Gemini 3.7 Flash (Medium)",
                    "supports_thinking": true,
                    "thinking_level": "medium",
                    "disabled": false
                },
                "gemini-3.7-flash-low": {
                    "display_name": "Gemini 3.7 Flash (Low)",
                    "supports_thinking": true,
                    "thinking_level": "low",
                    "disabled": false
                },
                "gemini-3.6-flash-high": {
                    "display_name": "Gemini 3.6 Flash (High)",
                    "supports_thinking": true,
                    "thinking_level": "high",
                    "disabled": false
                },
                "gemini-3.6-flash-medium": {
                    "display_name": "Gemini 3.6 Flash (Medium)",
                    "supports_thinking": true,
                    "thinking_level": "medium",
                    "disabled": false
                },
                "gemini-3.6-flash-low": {
                    "display_name": "Gemini 3.6 Flash (Low)",
                    "supports_thinking": true,
                    "thinking_level": "low",
                    "disabled": false
                },
                "gemini-3.1-pro-high": {
                    "display_name": "Gemini 3.1 Pro (High)",
                    "supports_thinking": true,
                    "thinking_level": "high",
                    "disabled": false
                },
                "gemini-3.1-pro-low": {
                    "display_name": "Gemini 3.1 Pro (Low)",
                    "supports_thinking": true,
                    "thinking_level": "low",
                    "disabled": false
                }
            }
        }
        """

        let bootstrap = GoogleBootstrapResult(
            project: "projects/test-proj-456",
            projectSource: .upstreamBootstrap,
            tier: "FREE_TIER"
        )
        let json = try JSONSerialization.jsonObject(with: mockCatalogJSON.data(using: .utf8)!) as! [String: Any]
        let models = AntigravityRemoteModelDiscovery.parseModels(json: json, bootstrap: bootstrap)

        #expect(models.count == 11)

        let ids = Set(models.map(\.id))
        #expect(ids.contains("gemini-3.8-flash-high"))
        #expect(ids.contains("gemini-3.8-flash-medium"))
        #expect(ids.contains("gemini-3.8-flash-low"))
        #expect(ids.contains("gemini-3.7-flash-high"))
        #expect(ids.contains("gemini-3.7-flash-medium"))
        #expect(ids.contains("gemini-3.7-flash-low"))
        #expect(ids.contains("gemini-3.6-flash-high"))
        #expect(ids.contains("gemini-3.6-flash-medium"))
        #expect(ids.contains("gemini-3.6-flash-low"))
        #expect(ids.contains("gemini-3.1-pro-high"))
        #expect(ids.contains("gemini-3.1-pro-low"))

        // Verbatim upstream ID and clean display name
        let flashHigh = models.first { $0.id == "gemini-3.8-flash-high" }!
        #expect(flashHigh.upstreamModelID == "gemini-3.8-flash-high")
        #expect(flashHigh.displayName == "Gemini 3.8 Flash (High)")
        #expect(flashHigh.displayNameSource == "upstream")
        #expect(flashHigh.isDefault == true)
        // Upstream provided no explicit visibility field, so canonical visibility remains "unspecified"
        #expect(flashHigh.visibility == "unspecified")
        #expect(flashHigh.supportedReasoningEfforts == [.high])
        #expect(flashHigh.contextWindow == 1048576)
        #expect(flashHigh.maxOutputTokens == 65536)
        #expect(flashHigh.vision == true)

        // Native metadata preservation
        #expect(flashHigh.nativeMetadata?["supports_thinking"] == "true")
        #expect(flashHigh.nativeMetadata?["thinking_level"] == "high")
        #expect(flashHigh.nativeMetadata?["thinking_budget"] == "24576")
        #expect(flashHigh.nativeMetadata?["min_thinking_budget"] == "1024")
        #expect(flashHigh.nativeMetadata?["project"] == "projects/test-proj-456")
        #expect(flashHigh.nativeMetadata?["project_source"] == "upstreamBootstrap")
        #expect(flashHigh.nativeMetadata?["current_tier"] == "FREE_TIER")
    }

    // MARK: - 4. Selectability & Native Field Interpretation (Rule 4)

    @Test func selectabilityDistinguishesDisabledVsInternalWithoutSpeculation() async throws {
        let mockCatalogJSON = """
        {
            "models": {
                "gemini-active": {
                    "display_name": "Gemini Active",
                    "disabled": false,
                    "is_internal": false
                },
                "gemini-disabled": {
                    "display_name": "Gemini Disabled",
                    "disabled": true,
                    "is_internal": false
                },
                "gemini-internal": {
                    "display_name": "Gemini Internal",
                    "disabled": false,
                    "is_internal": true
                },
                "gemini-explicit-public": {
                    "display_name": "Gemini Explicit Public",
                    "visibility": "public",
                    "disabled": false
                }
            }
        }
        """

        let bootstrap = GoogleBootstrapResult(project: nil, projectSource: .none)
        let json = try JSONSerialization.jsonObject(with: mockCatalogJSON.data(using: .utf8)!) as! [String: Any]
        let models = AntigravityRemoteModelDiscovery.parseModels(json: json, bootstrap: bootstrap)

        let active = models.first { $0.id == "gemini-active" }!
        let disabled = models.first { $0.id == "gemini-disabled" }!
        let internalModel = models.first { $0.id == "gemini-internal" }!
        let explicitPublic = models.first { $0.id == "gemini-explicit-public" }!

        // 1. disabled == true maps explicitly to "disabled"
        #expect(disabled.visibility == "disabled")
        #expect(disabled.nativeMetadata?["disabled"] == "true")

        // 2. disabled=false does NOT deduce public; canonical visibility remains "unspecified"
        #expect(active.visibility == "unspecified")
        #expect(active.nativeMetadata?["disabled"] == "false")

        // 3. is_internal=true does NOT deduce public; canonical visibility remains "unspecified"
        #expect(internalModel.visibility == "unspecified")
        #expect(internalModel.nativeMetadata?["is_internal"] == "true")

        // 4. Upstream explicit visibility is respected
        #expect(explicitPublic.visibility == "public")

        // 5. Test ModelAvailabilityResolver selectability:
        // "disabled" visibility is withheld from selectable candidates;
        // "unspecified" models (active, internal) and "public" models are kept in candidates.
        let agyProduct = BuiltinProviderCatalog.registryProduct(id: "antigravity")!
        let resolved = ModelAvailabilityResolver.resolve(
            product: agyProduct,
            registryModels: [],
            accountModels: models,
            isConfigured: true
        )

        let selectableIDs = Set(resolved.models.map(\.id))
        #expect(selectableIDs.contains("antigravity/gemini-active"))
        #expect(selectableIDs.contains("antigravity/gemini-internal"))
        #expect(selectableIDs.contains("antigravity/gemini-explicit-public"))
        #expect(!selectableIDs.contains("antigravity/gemini-disabled")) // strictly withheld
    }

    // MARK: - 5. Multi-Product Physical Isolation

    @Test func googleProductsHaveIsolatedIdentitiesProfilesAndCaches() async throws {
        let agyMeta = BuiltinProviderCatalog.metadata(for: "antigravity")
        let gcaMeta = BuiltinProviderCatalog.metadata(for: "gemini-code-assist")

        // 1. Independent RequestProfiles
        #expect(agyMeta.requestProfileID == "antigravity@2026-09")
        #expect(gcaMeta.requestProfileID == "gemini-code-assist@2026-09")
        #expect(agyMeta.activeRequestProfile?.id != gcaMeta.activeRequestProfile?.id)

        // 2. Verified Antigravity UA
        #expect(agyMeta.activeRequestProfile?.userAgentProfile == "antigravity/1.2.1 (darwin; arm64)")

        // 3. Gemini Code Assist does NOT carry fabricated UA
        #expect(gcaMeta.activeRequestProfile?.userAgentProfile == nil)

        // 4. Cache isolation under identical account reference
        let cache = AccountScopedCatalogCache.shared
        let accountRef = "test-google-account-hash"

        let agyModels = [
            DiscoveredRemoteModel(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)")
        ]
        try await cache.save(productID: "antigravity", accountRef: accountRef, models: agyModels)

        let agyCached = await cache.load(productID: "antigravity", accountRef: accountRef)
        let gcaCached = await cache.load(productID: "gemini-code-assist", accountRef: accountRef)

        #expect(agyCached?.models.count == 1)
        #expect(gcaCached == nil) // strictly isolated
    }

    // MARK: - 6. End-to-End AccountModelDiscovery Flow with Mock HTTP

    @Test func antigravityDiscoveryEndToEndWithMockHTTP() async throws {
        let mockBootstrapJSON = """
        {
            "cloudaicompanion_project": "projects/cloud-code-12345",
            "current_tier": "AGY_BUSINESS_PAYGO_TIER"
        }
        """

        let mockModelsJSON = """
        {
            "default_agent_model_id": "gemini-3.8-flash-high",
            "models": {
                "gemini-3.8-flash-high": {
                    "display_name": "Gemini 3.8 Flash (High)",
                    "supports_thinking": true,
                    "thinking_level": "high",
                    "disabled": false
                }
            }
        }
        """

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let path = req.url?.path ?? ""
            if path.contains("loadCodeAssist") {
                let data = mockBootstrapJSON.data(using: .utf8)!
                let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (data, res)
            } else if path.contains("fetchAvailableModels") {
                // Verify that the project resolved from bootstrap was sent in the body
                if let body = req.httpBody,
                   let bodyObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    #expect(bodyObj["project"] as? String == "projects/cloud-code-12345")
                }
                let data = mockModelsJSON.data(using: .utf8)!
                let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (data, res)
            }
            throw URLError(.badURL)
        }

        let agyProduct = BuiltinProviderCatalog.registryProduct(id: "antigravity")!
        let discovered = try await AccountModelDiscovery.discoverAuthenticatedRemote(
            product: agyProduct,
            accessToken: "valid-mock-token",
            httpClient: mockClient
        )

        #expect(discovered.count == 1)
        #expect(discovered.first?.id == "gemini-3.8-flash-high")
        #expect(discovered.first?.nativeMetadata?["project"] == "projects/cloud-code-12345")
        #expect(discovered.first?.nativeMetadata?["current_tier"] == "AGY_BUSINESS_PAYGO_TIER")
    }

    // MARK: - 7. Gemini Code Assist Project Semantics Unverified

    @Test func geminiCodeAssistProjectSemanticsRemainUnverifiedWithoutAssumptions() async throws {
        // 1. GoogleProjectSource.unverified represents unverified / pendingEvidence semantics
        let unverifiedSource = GoogleProjectSource.unverified
        #expect(unverifiedSource.rawValue == "unverified")

        // 2. Gemini Code Assist product in catalog does NOT impose forced GCP project account fields
        let gcaProduct = BuiltinProviderCatalog.registryProduct(id: "gemini-code-assist")!
        #expect(gcaProduct.accountFields?.isEmpty ?? true)

        // 3. Discovery implementation is explicitly missing, with no registered backend and no forged UA
        #expect(gcaProduct.discoveryImplementation?.status == "missing")
        #expect(gcaProduct.discoveryImplementation?.backend == "googleCodeAssistCatalog")
        #expect(AuthenticatedDiscoveryBackendRegistry.shared.backend(for: "googleCodeAssistCatalog") == nil)

        let gcaMeta = BuiltinProviderCatalog.metadata(for: "gemini-code-assist")
        #expect(gcaMeta.activeRequestProfile?.userAgentProfile == nil)
    }
}
