import Foundation
import LingXiProtocol
import LingXiModelSDK

/// The provider list a user chooses from, merged from the two sources Core
/// actually owns: the curated runtime provider contract (auth strategies, OAuth
/// products, local runtimes) and the published model catalog (far more
/// providers, each with its roster and endpoint).
///
/// Nothing here is hardcoded, and nothing here decides how a provider is
/// addressed: the wire protocol comes from LingXi's own runtime contract, never
/// from a field of the public catalog. A published provider the runtime has no
/// contract for is listed and reported as not connectable rather than guessed
/// into a protocol it may not speak.
enum ProviderCatalog {

    /// A connection plan for a published catalog entry.
    struct Plan: Sendable {
        let providerID: String
        let name: String
        let baseURL: String
        let adapter: String
    }

    static func entries(refresh: Bool, catalogClient: PublicModelCatalogClient = .shared) async -> [ProviderCatalogEntry] {
        if refresh { await catalogClient.warmup(force: true) }
        let published = await catalogClient.providers

        var result: [ProviderCatalogEntry] = []
        var seen: Set<String> = []

        for product in BuiltinProviderCatalog.connectableProducts().sorted(by: { $0.displayName < $1.displayName }) {
            seen.insert(product.id)
            // A curated product carries no roster of its own; the published
            // catalog is what lists its models, under its id or its aliases.
            let roster = await catalogClient.models(forProduct: product.id)
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

        for provider in published where !seen.contains(provider.id) {
            result.append(ProviderCatalogEntry(
                id: provider.id,
                name: provider.name,
                source: .modelsIndex,
                signInMode: signInMode(baseURL: provider.baseURL),
                modelCount: provider.modelCount,
                vendor: provider.fields["vendor"]?.stringValue,
                connectable: adapter(forPublishedProvider: provider.id) != nil
                    && !(provider.baseURL?.isEmpty ?? true)))
        }
        return result
    }

    /// Model ids published for one entry, in the catalog's documented order.
    static func modelIDs(entryID: String, catalogClient: PublicModelCatalogClient = .shared) async -> [String] {
        if BuiltinProviderCatalog.profile(for: entryID) != nil {
            return await catalogClient.models(forProduct: entryID).map(\.id)
        }
        return await catalogClient.models(providerID: entryID).map(\.id)
    }

    static func plan(entryID: String, catalogClient: PublicModelCatalogClient = .shared) async -> Plan? {
        guard let baseURL = await catalogClient.providerBaseURL(entryID), !baseURL.isEmpty,
              let adapter = adapter(forPublishedProvider: entryID) else { return nil }
        let name = await catalogClient.provider(entryID)?.name ?? entryID
        return Plan(providerID: entryID, name: name, baseURL: baseURL, adapter: adapter)
    }

    // MARK: - Runtime contract

    /// The wire protocol LingXi would use for a published provider — answered by
    /// the runtime's own product contract, or not at all.
    ///
    /// A public model catalog states what a model is. Which dialect a vendor
    /// speaks on the wire is LingXi's implementation detail, and reading it from
    /// an upstream package name is how a catalog ends up deciding runtime
    /// behaviour it cannot honor.
    static func adapter(forPublishedProvider providerID: String) -> String? {
        guard let family = protocolFamily(forPublishedProvider: providerID) else { return nil }
        switch family {
        case "anthropic_messages": return "anthropic-messages"
        case "openai_responses": return "openai-responses"
        case "openai_chat": return "openai-compatible"
        default: return nil
        }
    }

    /// Bridges the catalog's vendor namespace to LingXi's product namespace.
    ///
    /// The catalog publishes `openai`; the runtime contract knows `openai-api`.
    /// These are the two ways one is named after the other, and nothing else is
    /// consulted — a provider with no product here has no protocol either.
    static func protocolFamily(forPublishedProvider providerID: String) -> String? {
        for candidate in candidateProductIDs(forPublishedProvider: providerID) {
            if let profile = BuiltinProviderCatalog.profile(for: candidate) { return profile.protocolFamily }
        }
        return nil
    }

    static func candidateProductIDs(forPublishedProvider providerID: String) -> [String] {
        var candidates = [providerID]
        for suffix in ["-api", "-cloud", "-local"] { candidates.append(providerID + suffix) }
        candidates.append(contentsOf: PublicModelCatalogClient.productProviderAliases
            .filter { $0.value.contains(providerID) }
            .map(\.key)
            .sorted())
        return candidates
    }

    private static func signInMode(baseURL: String?) -> ProviderSignInMode {
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
