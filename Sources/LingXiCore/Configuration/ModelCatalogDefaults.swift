import Foundation
import LingXiProtocol

/// What the existing model catalogs state about one configured model.
///
/// This is the read-only bottom layer of `catalog → override → effective`. It
/// reads only the catalogs Core already maintains — the unified model registry
/// and the `models.lingxifox.cn` cache — and never fetches, never guesses and
/// never fills in a field a source did not state. A `nil` field means "no
/// catalog default", which the settings form renders as an unset override.
///
/// Precedence is per field: the unified registry decides first because it is
/// the source Core already uses to present this provider's models; the
/// `models.lingxifox.cn` entry fills the gaps it leaves.
enum ModelCatalogDefaults {

    static func resolve(providerID: String, modelID: String) async -> ProviderModelCatalogDefaults {
        let registry = await registryRecord(providerID: providerID, modelID: modelID)
        let modelsSite = await modelsSiteEntry(providerID: providerID, modelID: modelID)
        guard registry != nil || modelsSite != nil else { return ProviderModelCatalogDefaults() }

        return ProviderModelCatalogDefaults(
            contextWindow: registry?.capabilities.contextWindow ?? modelsSite?.limit?.context,
            maxOutputTokens: registry?.capabilities.maxOutputTokens ?? modelsSite?.limit?.output,
            reasoning: registry?.capabilities.reasoning ?? modelsSite?.reasoning,
            toolCalling: registry?.capabilities.toolCalling ?? modelsSite?.tool_call,
            parallelToolCalling: registry?.capabilities.parallelToolCalling,
            vision: registry?.capabilities.vision ?? modelsSite?.attachment,
            structuredOutput: registry?.capabilities.structuredOutput,
            // Neither catalog publishes rate limits or retry policy, so these
            // stay nil: only a user override or Core's default decides them.
            tokensPerMinute: nil,
            requestsPerMinute: nil,
            maxConcurrentRequests: nil,
            maxRetries: nil,
            initialRetryDelayMilliseconds: nil,
            maxRetryDelayMilliseconds: nil,
            retryJitterRatio: nil
        )
    }

    private static func registryRecord(providerID: String, modelID: String) async -> RegistryModelRecord? {
        guard let catalog = await ModelRegistryClient.shared.catalog() else { return nil }
        let productModels = catalog.models(productID: providerID)
        if let match = productModels.first(where: { $0.id == modelID || $0.upstreamModelID == modelID }) {
            return match
        }
        // A custom provider ID is not necessarily a registry product ID; the
        // model itself may still be described under its canonical name.
        return catalog.models.first { $0.id == modelID || $0.upstreamModelID == modelID }
    }

    private static func modelsSiteEntry(
        providerID: String,
        modelID: String
    ) async -> LingXiModelsCatalogClient.ModelEntry? {
        guard let payload = await LingXiModelsCatalogClient.shared.loadCached(),
              let providers = payload.providers else { return nil }
        if let entry = providers[providerID]?.models?[modelID] { return entry }
        for provider in providers.values {
            if let entry = provider.models?[modelID] { return entry }
        }
        return nil
    }
}
