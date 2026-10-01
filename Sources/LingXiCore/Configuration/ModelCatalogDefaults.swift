import Foundation
import LingXiProtocol
import LingXiModelSDK

/// What the published model catalog states about one configured model.
///
/// This is the read-only bottom layer of `catalog → override → effective`. It
/// reads the single public model source and never fetches, never guesses and
/// never fills in a field the source did not state. A `nil` field means "no
/// catalog default", which the settings form renders as an unset override.
///
/// Rate limits and retry policy are not model metadata — no catalog publishes
/// them — so they stay nil and only a user override or Core's default decides.
enum ModelCatalogDefaults {

    static func resolve(providerID: String, modelID: String,
                            catalogClient: PublicModelCatalogClient = .shared) async -> ProviderModelCatalogDefaults {
        let client = catalogClient
        // The provider the user configured first; a catalog-wide match covers a
        // model published under a different vendor id than the one configured.
        var found = await client.model(providerID: providerID, modelID: modelID)
        if found == nil { found = await client.model(named: modelID) }
        guard let model = found else { return ProviderModelCatalogDefaults() }
        return ProviderModelCatalogDefaults(
            contextWindow: model.contextWindow,
            maxOutputTokens: model.maxOutputTokens,
            reasoning: model.capabilities.reasoning,
            toolCalling: model.capabilities.toolCalling,
            parallelToolCalling: nil,
            vision: model.capabilities.vision,
            structuredOutput: model.capabilities.structuredOutput,
            tokensPerMinute: nil,
            requestsPerMinute: nil,
            maxConcurrentRequests: nil,
            maxRetries: nil,
            initialRetryDelayMilliseconds: nil,
            maxRetryDelayMilliseconds: nil,
            retryJitterRatio: nil
        )
    }
}
