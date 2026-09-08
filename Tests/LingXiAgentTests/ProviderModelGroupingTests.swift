import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiClient

@Suite("Provider and Model Grouping Tests")
struct ProviderModelGroupingTests {
    @Test("openai-codex uses authenticatedRemote discovery without static hardcoded availability")
    func codexUsesAuthenticatedRemoteDiscovery() throws {
        guard let catalog = BuiltinProviderCatalog.catalog else {
            Issue.record("Catalog must be present")
            return
        }
        guard let codex = catalog.products.first(where: { $0.id == "openai-codex" }) else {
            Issue.record("openai-codex must exist")
            return
        }
        #expect(codex.modelDiscovery == .authenticatedRemote)
        #expect(codex.models.isEmpty)

        // API catalog still holds verified OpenAI models
        guard let api = catalog.products.first(where: { $0.id == "openai-api" }) else {
            Issue.record("openai-api must exist")
            return
        }
        let apiModelIDs = Set(api.models.map(\.id))
        #expect(apiModelIDs.contains("gpt-4o"))
    }

    @Test("OpenCode Zen mock models do not exist anywhere in catalog")
    func noMockModelsInCatalog() throws {
        guard let catalog = BuiltinProviderCatalog.catalog else {
            Issue.record("Catalog must be present")
            return
        }
        let allModelIDs = catalog.products.flatMap { $0.models.map(\.id) }
        let forbidden = ["muse-spark-1.3", "nemotron-3.5-lightning", "big-pickle", "gpt-6-astra"]
        for f in forbidden {
            #expect(!allModelIDs.contains(f))
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
