import Testing
@testable import LingXiCore

struct BuiltinProviderCatalogTests {
    @Test func lmStudioDefaultsToResponsesInBundleAndStaticFallback() throws {
        let product = try #require(ProviderRegistry.shared.product(id: "lm-studio-local"))
        #expect(product.primaryProtocol == "openaiResponses")
        #expect(product.bindings[product.primaryProtocol]?.path == "/responses")
        #expect(BuiltinStaticCatalog.loadStaticProducts()["lm-studio-local"]?.defaultProtocol == "openaiResponses")
    }

    @Test func catalogHasStableUniqueProductsAndSeparateSubscriptionProducts() {
        let definitions = BuiltinProviderCatalog.definitions
        #expect(definitions.count == 27)
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        #expect(definitions.allSatisfy { !$0.id.rawValue.isEmpty && !$0.displayName.isEmpty })
        #expect(BuiltinProviderCatalog.definition(id: "openai-api")?.type == .cloudAPI)
        #expect(BuiltinProviderCatalog.definition(id: "openai-codex")?.type == .subscription)
        #expect(BuiltinProviderCatalog.definition(id: "minimax-api")?.type == .cloudAPI)
        #expect(BuiltinProviderCatalog.definition(id: "minimax-token-plan")?.type == .subscription)
        #expect(BuiltinProviderCatalog.definition(id: "antigravity")?.verificationStatus == .nonOfficialRunnableEvidence)
    }
}
