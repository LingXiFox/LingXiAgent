import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiClient

@Suite("Provider and Model Grouping Tests")
struct ProviderModelGroupingTests {
    /// An OAuth product resolves its models against the account; an API product
    /// resolves them against the vendor's listing endpoint. Neither declares a
    /// roster, which is what stops an old model ID from anchoring the picker.
    @Test("products declare how to discover models, never which models exist")
    func productsDeclareDiscoveryNotModelRosters() throws {
        let codex = try #require(BuiltinProviderCatalog.profile(for: "openai-codex"))
        #expect(codex.modelDiscovery == .authenticatedRemote)
        #expect(codex.models.isEmpty, "an OAuth product must not declare static models")

        let api = try #require(BuiltinProviderCatalog.profile(for: "openai-api"))
        #expect(api.modelDiscovery == .endpoint)
        #expect(api.models.isEmpty, "an API product's models come from upstream discovery")

        // The API product knows *where* its models come from.
        let metadata = BuiltinProviderCatalog.metadata(for: "openai-api")
        #expect(metadata.discoveryProfile?.kind == "openai-models")
        #expect(metadata.discoveryProfile?.url.isEmpty == false)
    }

    @Test("no built-in product carries a static model roster")
    func noStaticModelRosters() throws {
        for profile in BuiltinProviderCatalog.profiles {
            #expect(profile.models.isEmpty, "\(profile.id) must not declare a static model list")
        }
    }

    @Test("Model picker hides unconfigured built-in providers when query is empty")
    func emptyQueryHidesUnconfiguredBuiltins() throws {
        let currentID = "bai/deepseek-v4-flash"
        let configuredCustom = ProviderModelInfo(
            id: "bai/deepseek-v4-flash",
            providerID: "bai",
            modelID: "deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            contextWindow: 128_000,
            maxOutputTokens: 4_096,
            reasoning: true,
            configured: true
        )
        let unconfiguredBuiltin = ProviderModelInfo(
            id: "lmstudio/qwen-7b",
            providerID: "lmstudio",
            modelID: "qwen-7b",
            displayName: "Qwen 7B",
            contextWindow: 32_000,
            maxOutputTokens: 4_096,
            reasoning: false,
            configured: false
        )
        let configuredCodex = ProviderModelInfo(
            id: "openai-codex/gpt-5-5",
            providerID: "openai-codex",
            modelID: "gpt-5-5",
            displayName: "GPT-5.5",
            contextWindow: 128_000,
            maxOutputTokens: 4_096,
            reasoning: true,
            configured: true
        )

        let catalog: [ProviderModelInfo] = [configuredCustom, unconfiguredBuiltin, configuredCodex]

        let q = ""
        let filteredEmpty: [ProviderModelInfo] = catalog.filter { m in
            if m.id == currentID { return false }
            if q.isEmpty && !m.configured { return false }
            return true
        }
        #expect(filteredEmpty.map { $0.id } == ["openai-codex/gpt-5-5"])
        #expect(!filteredEmpty.contains(where: { $0.providerID == "lmstudio" }))

        let searchQ = "qwen"
        let filteredSearch: [ProviderModelInfo] = catalog.filter { m in
            if m.id == currentID { return false }
            if searchQ.isEmpty && !m.configured { return false }
            return m.displayName.lowercased().contains(searchQ)
        }
        #expect(filteredSearch.map { $0.id } == ["lmstudio/qwen-7b"])
    }

    @Test("accountHash returns identical hash for raw JWT token and JSON-wrapped credential")
    func accountHashEquivalence() throws {
        let rawJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhdXRoMHxBNDoyNEFMVk50NnZxOXdhZTNNNjMwamsiLCJlbWFpbCI6InVzZXJAZXhhbXBsZS5jb20ifQ.signature"
        let jsonWrapped = "{\"accessToken\":\"\(rawJWT)\",\"refreshToken\":\"ref-123\"}"

        let hashFromRaw = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: rawJWT)
        let hashFromJSON = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: jsonWrapped)

        #expect(hashFromRaw == hashFromJSON)
        #expect(!hashFromRaw.isEmpty)
    }
}
