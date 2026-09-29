import Foundation
import LingXiProtocol

/// The provider list a user chooses from, merged from the catalogs Core already
/// maintains: the curated Provider registry (auth strategies, OAuth products,
/// local runtimes) and the published `models.lingxifox.cn` index (far more
/// providers, each with its endpoint and model list).
///
/// Nothing here is hardcoded: an entry exists because one of the two sources
/// states it, and an entry that no source gives a usable endpoint for is
/// reported as not connectable rather than dropped or guessed.
enum ProviderCatalog {

    /// A connection plan for a published index entry.
    struct Plan: Sendable {
        let providerID: String
        let name: String
        let baseURL: String
        let adapter: String
    }

    static func entries(refresh: Bool, siteClient: LingXiModelsCatalogClient = .shared) async -> [ProviderCatalogEntry] {
        let client = siteClient
        if refresh { await client.warmup(forceRefresh: true) }
        let site = await client.loadCached()?.providers ?? [:]

        var result: [ProviderCatalogEntry] = []
        var seen: Set<String> = []

        for product in BuiltinProviderCatalog.connectableProducts().sorted(by: { $0.displayName < $1.displayName }) {
            seen.insert(product.id)
            // A curated product carries no roster of its own; the published
            // index is what lists its models, under its id or its aliases.
            let roster = await siteClient.cachedModelsForProduct(productID: product.id)
            result.append(ProviderCatalogEntry(
                id: product.id,
                name: product.displayName,
                source: .registry,
                signInMode: mode(of: product),
                modelCount: roster.count,
                vendor: product.vendorID,
                connectable: true,
                requiredAccountFields: product.requiredAccountFields))
        }

        for (id, provider) in site.sorted(by: { ($0.value.name ?? $0.key) < ($1.value.name ?? $1.key) })
        where !seen.contains(id) {
            seen.insert(id)
            let adapter = adapter(for: provider.swiftDriver)
            let baseURL = provider.baseURL
            result.append(ProviderCatalogEntry(
                id: id,
                name: provider.name ?? id,
                source: .modelsIndex,
                signInMode: signInMode(baseURL: baseURL, driver: provider.swiftDriver),
                modelCount: provider.models?.count ?? 0,
                connectable: adapter != nil && baseURL?.isEmpty == false))
        }
        return result
    }

    /// Model ids published for one entry, in the order the source lists them.
    static func modelIDs(entryID: String, siteClient: LingXiModelsCatalogClient = .shared) async -> [String] {
        if BuiltinProviderCatalog.profile(for: entryID) != nil {
            return await siteClient.cachedModelsForProduct(productID: entryID).map(\.id).sorted()
        }
        let site = await siteClient.loadCached()?.providers ?? [:]
        guard let provider = site[entryID] else { return [] }
        let models = provider.models ?? [:]
        return models.keys.sorted()
    }

    static func plan(entryID: String, siteClient: LingXiModelsCatalogClient = .shared) async -> Plan? {
        let site = await siteClient.loadCached()?.providers ?? [:]
        guard let provider = site[entryID],
              let baseURL = provider.baseURL, !baseURL.isEmpty,
              let adapter = adapter(for: provider.swiftDriver) else { return nil }
        return Plan(providerID: entryID, name: provider.name ?? entryID,
                    baseURL: baseURL, adapter: adapter)
    }

    /// The three wire protocols the settings editor can store.
    private static func adapter(for driver: String?) -> String? {
        switch driver {
        case "anthropicMessages": "anthropic-messages"
        case "openaiChat", "ollamaNative": "openai-compatible"
        default: nil
        }
    }

    private static func signInMode(baseURL: String?, driver: String?) -> ProviderSignInMode {
        guard let baseURL else { return .none }
        let lower = baseURL.lowercased()
        if lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("::1") {
            return .localEndpoint
        }
        return .apiKey
    }

    private static func mode(of product: ProviderProductSummary) -> ProviderSignInMode {
        if product.requestAuthentication == .oauthAccessToken || product.accountTypes.contains(.oauthUser) {
            return .browser
        }
        if product.requiresLocalEndpoint { return .localEndpoint }
        if product.requiresCredential { return .apiKey }
        return .none
    }
}
