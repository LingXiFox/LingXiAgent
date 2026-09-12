import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct CompatibilityMatrixTests {
    @Test func matrixCoversAllThirteenBuiltinProviders() {
        let matrix = ProviderCompatibilityMatrix.generateMatrix()
        #expect(matrix.count >= 13)

        let coreIDs: Set<String> = [
            "anthropic-api", "openai-api", "deepseek-api", "gemini-api",
            "xai-api", "openrouter", "ollama-local", "lm-studio-local",
            "llama-cpp-local", "alibaba-bailian-api", "minimax-api",
            "openai-codex", "gemini-code-assist", "antigravity"
        ]
        let actualIDs = Set(matrix.map(\.providerID))
        #expect(coreIDs.isSubset(of: actualIDs))
    }

    @Test func protocolFamiliesConvergedToThreeStandards() {
        let matrix = ProviderCompatibilityMatrix.generateMatrix()
        let allowedFamilies: Set<String> = [
            "openai_chat",
            "openai_responses",
            "anthropic_messages"
        ]
        for entry in matrix {
            #expect(allowedFamilies.contains(entry.protocolFamily), "Provider \(entry.providerID) uses invalid protocol family \(entry.protocolFamily)")
        }
    }

    @Test func localRuntimesAllowNoAuth() {
        let localProviders = ["ollama-local", "lm-studio-local", "llama-cpp-local"]
        for id in localProviders {
            guard let profile = BuiltinProviderCatalog.profile(for: id) else {
                Issue.record("Missing local provider: \(id)")
                continue
            }
            #expect(profile.authMethods.contains("none"), "\(id) should support none auth")
            #expect(BuiltinProviderCatalog.hasQuirk(providerID: id, quirk: "localRuntime"))
        }
    }

    @Test func quirksAreProperlyConfiguredAndQueryable() {
        #expect(BuiltinProviderCatalog.hasQuirk(providerID: "xai-api", quirk: "statelessContinuationOnly"))
        #expect(BuiltinProviderCatalog.hasQuirk(providerID: "deepseek-api", quirk: "statelessContinuationOnly"))
        #expect(BuiltinProviderCatalog.hasQuirk(providerID: "anthropic-api", quirk: "requiresAnthropicVersionHeader"))
        #expect(!BuiltinProviderCatalog.hasQuirk(providerID: "openai-api", quirk: "statelessContinuationOnly"))
    }

    /// Reasoning capability is no longer declared per model in a built-in table.
    /// It now arrives with the model: either from the registry overlay, or from
    /// whatever the upstream listing stated. The matrix therefore describes
    /// products, and a model-level assertion here would re-introduce exactly the
    /// static roster this refactor removed. Model-level reasoning coverage lives
    /// in `UnifiedModelRegistryTests`.
    @Test func reasoningIsNoLongerDeclaredPerModelStatically() {
        let matrix = ProviderCompatibilityMatrix.generateMatrix()
        #expect(!matrix.isEmpty)
        // The matrix carries product-level facts only.
        for entry in matrix {
            #expect(!entry.providerID.isEmpty)
            #expect(!entry.discoveryStrategy.isEmpty)
        }
    }

    @Test func markdownTableRendersCorrectly() {
        let table = ProviderCompatibilityMatrix.renderMarkdownTable()
        #expect(table.contains("# Provider Compatibility Matrix"))
        #expect(table.contains("anthropic-api"))
        #expect(table.contains("openai-api"))
        #expect(table.contains("openai_responses"))
        #expect(table.contains("openai_chat"))
        #expect(table.contains("anthropic_messages"))
    }
}
