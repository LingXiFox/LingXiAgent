import Foundation
import LingXiProtocol

public enum ResolvedModelCatalogResolver {
    public static func resolve(
        productID: String,
        authenticatedModels: [DiscoveredRemoteModel],
        staticCatalog: GeneratedProviderCatalog?,
        overlayProduct: OverlayProduct? = nil,
        isConfigured: Bool = true
    ) -> [ProviderModelInfo] {
        // Find matching product in static catalog (e.g. openai-api / openai-codex)
        let staticProduct = staticCatalog?.products.first(where: { $0.id == productID })
            ?? staticCatalog?.products.first(where: { $0.vendor == "openai" && $0.type == "cloudAPI" })

        // Build index of static model metadata
        var staticModelsByID: [String: GeneratedModel] = [:]
        if let staticProduct {
            for m in staticProduct.models {
                staticModelsByID[m.id] = m
                staticModelsByID[m.upstreamID] = m
            }
        }

        var results: [ProviderModelInfo] = []

        // Authenticated models are the sole source of availability for authenticated products
        for remote in authenticatedModels {
            let matchedStatic = staticModelsByID[remote.id]

            let displayName = matchedStatic?.displayName ?? remote.displayName
            let contextWindow = remote.contextWindow ?? matchedStatic?.contextWindow ?? 128_000
            let maxOutputTokens = remote.maxOutputTokens ?? matchedStatic?.maxOutputTokens ?? 4_096
            let isReasoning = !remote.supportedReasoningEfforts.isEmpty || (matchedStatic?.reasoningCapability != nil)
            let isIncomplete = (matchedStatic == nil)

            let modelInfo = ProviderModelInfo(
                id: "\(productID)/\(remote.id)",
                providerID: productID,
                modelID: remote.id,
                displayName: displayName,
                contextWindow: contextWindow,
                maxOutputTokens: maxOutputTokens,
                reasoning: isReasoning,
                configured: isConfigured,
                metadataIncomplete: isIncomplete
            )
            results.append(modelInfo)
        }

        // Deterministic sort: default models first, then by priority, then by id
        return results.sorted { m1, m2 in
            let r1 = authenticatedModels.first(where: { $0.id == m1.modelID })
            let r2 = authenticatedModels.first(where: { $0.id == m2.modelID })
            if let r1, let r2 {
                if r1.isDefault != r2.isDefault { return r1.isDefault && !r2.isDefault }
                if r1.priority != r2.priority { return r1.priority < r2.priority }
            }
            return m1.modelID < m2.modelID
        }
    }
}
