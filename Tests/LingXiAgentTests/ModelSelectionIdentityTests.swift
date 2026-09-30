import Testing
@testable import LingXiApplication
@testable import LingXiProtocol

@Suite("Model selection identity")
struct ModelSelectionIdentityTests {
    private func model(id: String, provider: String, modelID: String) -> ProviderModelInfo {
        ProviderModelInfo(id: id, providerID: provider, modelID: modelID, displayName: modelID,
                          contextWindow: 0, maxOutputTokens: 0, reasoning: true, configured: true)
    }

    @Test("A model from another account selects by provider/model, never by bare ID")
    func qualifiedIDCarriesTheProvider() {
        // Core resolves a bare ID under the *current* provider, so `gpt-5.6-luna`
        // became `bai/gpt-5.6-luna` and failed with 「模型不可用」.
        #expect(model(id: "openai-codex/gpt-5.6-luna", provider: "openai-codex", modelID: "gpt-5.6-luna").qualifiedID
                == "openai-codex/gpt-5.6-luna")
        // Core's fallback entry for the running assembly uses a bare id.
        #expect(model(id: "deepseek-v4-flash", provider: "bai", modelID: "deepseek-v4-flash").qualifiedID
                == "bai/deepseek-v4-flash")
    }

    @Test("Stored selections match in qualified, id and bare form")
    func storedSelectionsMatch() {
        let luna = model(id: "openai-codex/gpt-5.6-luna", provider: "openai-codex", modelID: "gpt-5.6-luna")
        #expect(luna.matches(selection: "openai-codex/gpt-5.6-luna"))
        #expect(luna.matches(selection: "gpt-5.6-luna"))
        #expect(!luna.matches(selection: "bai/gpt-5.6-luna"))
    }

    @Test("Core's selection info qualifies only when the provider is known")
    func selectionInfoQualifies() {
        #expect(ModelSelectionInfo(modelID: "deepseek-v4-flash", providerID: "bai").qualifiedID == "bai/deepseek-v4-flash")
        #expect(ModelSelectionInfo(modelID: "deepseek-v4-flash").qualifiedID == "deepseek-v4-flash")
    }
}
