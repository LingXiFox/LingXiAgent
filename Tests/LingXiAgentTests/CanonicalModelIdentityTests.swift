import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore

@Suite("Canonical Model Identity and Backend Variant Tests")
struct CanonicalModelIdentityTests {

    @Test("parseSlug properly decomposes standard, instant, and thinking slugs")
    func parseSlugDecomposition() {
        let cases: [(slug: String, expectedCanonical: String, expectedKind: BackendVariantKind)] = [
            ("gpt-5-6", "gpt-5-6", .standard),
            ("gpt-5-6-instant", "gpt-5-6", .instant),
            ("gpt-5-6-thinking", "gpt-5-6", .thinking),
            ("gpt-5-5", "gpt-5-5", .standard),
            ("gpt-5-5-instant", "gpt-5-5", .instant),
            ("gpt-5-5-thinking", "gpt-5-5", .thinking),
            ("gpt-5-6-mini", "gpt-5-6-mini", .standard),
            ("gpt-5-6-t-mini", "gpt-5-6-mini", .thinking),
            ("claude-3-7-sonnet", "claude-3-7-sonnet", .standard),
            ("gpt-5.4-openai-compact", "gpt-5.4-openai-compact", .specialized),
        ]

        for (slug, expectedCanonical, expectedKind) in cases {
            let (canonical, kind) = CanonicalModelParser.parseSlug(slug)
            #expect(canonical == expectedCanonical, "Expected canonical \(expectedCanonical) for \(slug), got \(canonical)")
            #expect(kind == expectedKind, "Expected kind \(expectedKind) for \(slug), got \(kind)")
        }
    }

    @Test("cleanDisplayName strips variant suffixes without inventing model names")
    func cleanDisplayNameBehavior() {
        #expect(CanonicalModelParser.cleanDisplayName("GPT-5.6 Sol", fallbackSlug: "gpt-5-6") == "GPT-5.6 Sol")
        #expect(CanonicalModelParser.cleanDisplayName("GPT-5.6 Sol Thinking", fallbackSlug: "gpt-5-6-thinking") == "GPT-5.6 Sol")
        #expect(CanonicalModelParser.cleanDisplayName("GPT-5.6 Sol Instant", fallbackSlug: "gpt-5-6-instant") == "GPT-5.6 Sol")
        #expect(CanonicalModelParser.cleanDisplayName("GPT-5.6 Sol (Thinking)", fallbackSlug: "gpt-5-6-thinking") == "GPT-5.6 Sol")
        #expect(CanonicalModelParser.cleanDisplayName("", fallbackSlug: "gpt-5-6") == "gpt-5-6")
    }

    @Test("groupModels aggregates OpenAI Codex discovered models into canonical groups while keeping upstreamModelIDs verbatim")
    func groupModelsAggregatesVerbatimSlugs() {
        let discovered: [DiscoveredRemoteModel] = [
            DiscoveredRemoteModel(
                id: "gpt-5-6",
                displayName: "GPT-5.6 Sol",
                priority: 100,
                supportedReasoningEfforts: [.auto, .low, .high],
                upstreamModelID: "gpt-5-6",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "standard"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-6-instant",
                displayName: "GPT-5.6 Sol Instant",
                priority: 100,
                supportedReasoningEfforts: [],
                upstreamModelID: "gpt-5-6-instant",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "instant"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-6-thinking",
                displayName: "GPT-5.6 Sol Thinking",
                priority: 100,
                supportedReasoningEfforts: [.low, .high, .max],
                upstreamModelID: "gpt-5-6-thinking",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "thinking"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-5",
                displayName: "GPT-5.5",
                priority: 90,
                supportedReasoningEfforts: [.auto, .high],
                upstreamModelID: "gpt-5-5",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-5",
                backendVariant: "standard"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-5-instant",
                displayName: "GPT-5.5 Instant",
                priority: 90,
                supportedReasoningEfforts: [],
                upstreamModelID: "gpt-5-5-instant",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-5",
                backendVariant: "instant"
            ),
        ]

        let groups = CanonicalModelParser.groupModels(discovered)

        #expect(groups.count == 2, "Expected 2 canonical groups (gpt-5-6, gpt-5-5)")

        let gpt56 = groups.first { $0.id == "gpt-5-6" }
        #expect(gpt56 != nil)
        #expect(gpt56?.displayName == "GPT-5.6 Sol", "Clean display name must not contain 'Instant' or 'Thinking'")
        #expect(gpt56?.primaryUpstreamModelID == "gpt-5-6")
        #expect(gpt56?.variants.count == 3)

        // Verify verbatim slugs
        let slugs = gpt56?.variants.map(\.upstreamModelID) ?? []
        #expect(slugs.contains("gpt-5-6"))
        #expect(slugs.contains("gpt-5-6-instant"))
        #expect(slugs.contains("gpt-5-6-thinking"))

        // Verify effort resolution
        #expect(gpt56?.resolveUpstreamModelID(for: .off) == "gpt-5-6-instant")
        #expect(gpt56?.resolveUpstreamModelID(for: .high) == "gpt-5-6-thinking")
        #expect(gpt56?.resolveUpstreamModelID(for: .auto) == "gpt-5-6")
        #expect(gpt56?.resolveUpstreamModelID(for: nil) == "gpt-5-6")
    }

    @Test("ModelAvailabilityResolver preserves verbatim variants when aggregateCanonicalModels is true")
    func resolverAggregatesCanonicalModels() {
        let product = RegistryProduct(
            id: "openai-codex",
            vendorID: "openai",
            displayName: "OpenAI Codex",
            type: "subscription",
            authStrategy: "oauthUser",
            authMethods: ["oauthUser"],
            protocolFamily: "responses",
            discoveryStrategy: "authenticatedRemote",
            endpoint: "https://chatgpt.com/backend-api",
            runtimeSupport: "implemented",
            modelIDs: []
        )

        let accountModels: [DiscoveredRemoteModel] = [
            DiscoveredRemoteModel(
                id: "gpt-5-6",
                displayName: "GPT-5.6 Sol",
                upstreamModelID: "gpt-5-6",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "standard"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-6-instant",
                displayName: "GPT-5.6 Sol Instant",
                upstreamModelID: "gpt-5-6-instant",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "instant"
            ),
            DiscoveredRemoteModel(
                id: "gpt-5-6-thinking",
                displayName: "GPT-5.6 Sol Thinking",
                upstreamModelID: "gpt-5-6-thinking",
                displayNameSource: "title",
                canonicalModelID: "gpt-5-6",
                backendVariant: "thinking"
            )
        ]

        // When flat
        let flatOutcome = ModelAvailabilityResolver.resolve(
            product: product,
            registryModels: [],
            accountModels: accountModels,
            isConfigured: true,
            aggregateCanonicalModels: false
        )
        #expect(flatOutcome.models.count == 3)

        // When aggregated
        let aggregatedOutcome = ModelAvailabilityResolver.resolve(
            product: product,
            registryModels: [],
            accountModels: accountModels,
            isConfigured: true,
            aggregateCanonicalModels: true
        )
        #expect(aggregatedOutcome.models.count == 1)
        let single = aggregatedOutcome.models[0]
        #expect(single.modelID == "gpt-5-6")
        #expect(single.displayName == "GPT-5.6 Sol")
        #expect(single.canonicalModelID == "gpt-5-6")
        #expect(single.backendVariants?.sorted() == ["gpt-5-6", "gpt-5-6-instant", "gpt-5-6-thinking"].sorted())
    }

    @Test("Official Codex 0.154.0 catalog returns 7 real models with Astra, Sol, Terra, Luna and verbatim IDs")
    func officialCodex7ModelsParsing() throws {
        let sampleJson = """
        {
          "models": [
            {
              "slug": "gpt-6-astra",
              "display_name": "GPT-6-Astra",
              "default_reasoning_level": "low",
              "supported_reasoning_levels": [
                {"effort": "low", "description": "Fast responses with lighter reasoning"},
                {"effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks"},
                {"effort": "high", "description": "Greater reasoning depth for complex problems"},
                {"effort": "xhigh", "description": "Extra high reasoning depth for complex problems"},
                {"effort": "max", "description": "Maximum reasoning depth for the hardest problems"},
                {"effort": "ultra", "description": "Maximum reasoning with automatic task delegation"}
              ],
              "priority": 1,
              "context_window": 272000,
              "input_modalities": ["text", "image"]
            },
            {
              "slug": "gpt-reserve",
              "display_name": "GPT-Reserve",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}
              ],
              "priority": 3
            },
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6-Sol",
              "default_reasoning_level": "low",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}
              ],
              "priority": 6
            },
            {
              "slug": "gpt-5.6-terra",
              "display_name": "GPT-5.6-Terra",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}
              ],
              "priority": 7
            },
            {
              "slug": "gpt-5.6-luna",
              "display_name": "GPT-5.6-Luna",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}
              ],
              "priority": 8
            },
            {
              "slug": "gpt-5.5",
              "display_name": "GPT-5.5",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}
              ],
              "priority": 12
            },
            {
              "slug": "codex-auto-review",
              "display_name": "Codex Auto Review",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}
              ],
              "priority": 43
            }
          ]
        }
        """

        let data = sampleJson.data(using: .utf8)!
        let models = try CodexRemoteModelDiscovery.parseRemoteModels(from: data)

        #expect(models.count == 7)
        let slugs = models.map(\.id)
        #expect(slugs == [
            "gpt-6-astra",
            "gpt-reserve",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "codex-auto-review"
        ])

        // Verify Astra
        let astra = models.first { $0.id == "gpt-6-astra" }
        #expect(astra != nil)
        #expect(astra?.displayName == "GPT-6-Astra")
        #expect(astra?.upstreamModelID == "gpt-6-astra")
        #expect(astra?.contextWindow == 272000)
        #expect(astra?.vision == true)
        #expect(astra?.capabilities?.reasoning == true)
        #expect(astra?.supportedReasoningEfforts.contains(.low) == true)
        #expect(astra?.supportedReasoningEfforts.contains(.max) == true)

        // Verify reasoning levels (lossless xhigh, ultra)
        #expect(astra?.supportedReasoningEfforts.contains(.xhigh) == true)
        #expect(astra?.supportedReasoningEfforts.contains(.ultra) == true)
        #expect(astra?.supportedReasoningEfforts == [.low, .medium, .high, .xhigh, .max, .ultra])

        // Verify Sol, Terra, Luna
        #expect(models.contains(where: { $0.id == "gpt-5.6-sol" && $0.displayName == "GPT-5.6-Sol" }))
        #expect(models.contains(where: { $0.id == "gpt-5.6-terra" && $0.displayName == "GPT-5.6-Terra" }))
        #expect(models.contains(where: { $0.id == "gpt-5.6-luna" && $0.displayName == "GPT-5.6-Luna" }))

        // Verify grouping
        let groups = CanonicalModelParser.groupModels(models)
        #expect(groups.count == 7)
        for g in groups {
            #expect(g.variants.count == 1)
            #expect(g.primaryUpstreamModelID == g.id)
        }

        // Verify ModelAvailabilityResolver respects visibility: "hide"
        // Let's create models with upstream visibility fields:
        let modelsWithVisibility: [DiscoveredRemoteModel] = models.map { m in
            let vis = (m.id == "gpt-reserve" || m.id == "codex-auto-review") ? "hide" : "list"
            return DiscoveredRemoteModel(
                id: m.id,
                displayName: m.displayName,
                priority: m.priority,
                visibility: vis,
                isDefault: m.isDefault,
                supportedReasoningEfforts: m.supportedReasoningEfforts,
                minimalClientVersion: m.minimalClientVersion,
                contextWindow: m.contextWindow,
                maxOutputTokens: m.maxOutputTokens,
                toolCalling: m.toolCalling,
                vision: m.vision,
                metadataIncomplete: m.metadataIncomplete,
                capabilities: m.capabilities,
                upstreamModelID: m.upstreamModelID,
                displayNameSource: m.displayNameSource,
                canonicalModelID: m.canonicalModelID,
                backendVariant: m.backendVariant
            )
        }

        let product = RegistryProduct(
            id: "openai-codex",
            vendorID: "openai",
            displayName: "OpenAI Codex",
            type: "llm",
            authStrategy: "oauthUser",
            authMethods: ["oauthUser"],
            protocolFamily: "responses",
            discoveryStrategy: "authenticatedRemote",
            endpoint: "https://chatgpt.com/backend-api",
            runtimeSupport: "implemented",
            modelIDs: []
        )

        let outcome = ModelAvailabilityResolver.resolve(
            product: product,
            registryModels: [],
            accountModels: modelsWithVisibility,
            isConfigured: true,
            aggregateCanonicalModels: true
        )

        // Only the 5 models with visibility: "list" should be selectable!
        // "gpt-reserve" and "codex-auto-review" must be filtered by first-party visibility metadata.
        #expect(outcome.models.count == 5)
        let selectableIDs = outcome.models.map(\.modelID)
        #expect(selectableIDs.contains("gpt-6-astra"))
        #expect(selectableIDs.contains("gpt-5.6-sol"))
        #expect(selectableIDs.contains("gpt-5.6-terra"))
        #expect(selectableIDs.contains("gpt-5.6-luna"))
        #expect(selectableIDs.contains("gpt-5.5"))
        #expect(!selectableIDs.contains("gpt-reserve"))
        #expect(!selectableIDs.contains("codex-auto-review"))
    }
}
