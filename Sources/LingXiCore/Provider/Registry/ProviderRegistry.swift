import Foundation
import LingXiProtocol

/// Central in-memory registry for built-in provider products and their protocol bindings.
public final class ProviderRegistry: Sendable {
    public static let shared = ProviderRegistry()

    private let products: [String: ResolvedProviderProduct]

    public init(loader: BuiltinProductLoader = .shared) {
        self.products = loader.loadResolvedProducts()
    }

    /// Returns the resolved provider product for a given product ID.
    public func product(id: String) -> ResolvedProviderProduct? {
        products[id]
    }

    /// All resolved provider products.
    public func allProducts() -> [ResolvedProviderProduct] {
        Array(products.values).sorted { $0.id < $1.id }
    }

    /// Returns all connectable products formatted as `ProviderProductSummary`.
    public func connectableProducts() -> [ProviderProductSummary] {
        allProducts().compactMap { product in
            let legacyDef = product.toLegacyDefinition()
            guard legacyDef.isRuntimeResolvable else { return nil }

            let authentication: ProviderRequestAuthentication? = legacyDef.endpoints.first.map { endpoint in
                switch endpoint.requestAuthentication {
                case .none: return .none
                case .bearerToken: return .bearerToken
                case .apiKeyHeader: return .apiKeyHeader
                case .oauthAccessToken: return .oauthAccessToken
                case .workloadIdentityToken: return .workloadIdentityToken
                case .gatewayToken: return .gatewayToken
                case .customHeaderSet: return .customHeaderSet
                case .providerNative: return .providerNative
                }
            }

            let headerName = legacyDef.endpoints.first.flatMap { endpoint in
                if case let .apiKeyHeader(name) = endpoint.requestAuthentication { return name }
                return nil
            }

            return ProviderProductSummary(
                id: product.id,
                displayName: product.displayName,
                vendorID: product.vendorID,
                type: legacyDef.type,
                accountTypes: legacyDef.accountTypes,
                requestAuthentication: authentication,
                requestAuthenticationHeaderName: headerName,
                requiresCredential: authentication.map { $0 != .none } ?? false,
                requiresLocalEndpoint: legacyDef.type == .localRuntime,
                requiredAccountFields: legacyDef.requiredAccountFields,
                verificationStatus: legacyDef.verificationStatus,
                connectable: true
            )
        }
    }

    /// Returns legacy `ProviderProductDefinition` array for backward compatibility.
    public func legacyDefinitions() -> [ProviderProductDefinition] {
        allProducts().map { $0.toLegacyDefinition() }
    }

    /// Returns legacy `ProviderProductDefinition` for a product ID.
    public func legacyDefinition(id: String) -> ProviderProductDefinition? {
        product(id: id)?.toLegacyDefinition()
    }

    /// Returns quirks for a product ID.
    public func quirks(for productID: String) -> [String] {
        product(id: productID)?.quirks ?? []
    }

    /// Checks whether a product has a specific quirk.
    public func hasQuirk(productID: String, quirk: String) -> Bool {
        quirks(for: productID).contains(quirk)
    }
}
