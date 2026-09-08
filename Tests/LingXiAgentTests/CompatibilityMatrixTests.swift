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

    @Test func reasoningCapabilitiesMatchProviderCapabilities() {
        // Claude 3.7 Sonnet uses budget mode
        let claudeSonnet = BuiltinProviderCatalog.modelProfile(providerID: "anthropic-api", modelID: "claude-3-7-sonnet")
        #expect(claudeSonnet?.reasoningCapability?.mode == .budget)
        #expect(claudeSonnet?.reasoningCapability?.emitsVisibleReasoning == true)

        // o3-mini uses effort mode
        let o3Mini = BuiltinProviderCatalog.modelProfile(providerID: "openai-api", modelID: "o3-mini")
        #expect(o3Mini?.reasoningCapability?.mode == .effort)
        #expect(o3Mini?.reasoningCapability?.emitsReasoningSummary == true)

        // DeepSeek R1 uses adaptive mode
        let r1 = BuiltinProviderCatalog.modelProfile(providerID: "deepseek-api", modelID: "deepseek-reasoner")
        #expect(r1?.reasoningCapability?.mode == .adaptive)
        #expect(r1?.reasoningCapability?.defaultEffort == .auto)

        // Grok Composer 2.5 Fast uses effort mode
        let grokComposer = BuiltinProviderCatalog.modelProfile(providerID: "xai-api", modelID: "grok-composer-2.5-fast")
        #expect(grokComposer?.reasoningCapability?.mode == .effort)
        #expect(grokComposer?.reasoningCapability?.defaultEffort == .high)
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
