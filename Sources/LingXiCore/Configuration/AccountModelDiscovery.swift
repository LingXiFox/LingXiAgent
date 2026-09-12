import Foundation
import LingXiProtocol

/// Discovers the models a *specific account* can reach, using that account's own
/// credential against the upstream vendor.
///
/// This is the second of the three layers that must stay distinct:
///
///   - the registry catalog says what exists in the world,
///   - **account discovery** (here) says what this user can actually reach,
///   - runtime support says what LingXi can execute.
///
/// A user's key is read from the local credential store, sent only to the vendor
/// that issued it, and never uploaded to the LingXi registry.
public enum AccountModelDiscovery {

    /// Reasons a discovery attempt produced no models.
    public enum DiscoveryFailure: Error, LocalizedError, Equatable {
        case noProfileDeclared(productID: String)
        case noCredential(productID: String)
        case requestConstructionFailed(profileID: String)
        case transport(String)
        case empty(productID: String)
        case noBackendDeclared(productID: String)
        case implementationMissing(productID: String)
        case backendUnavailable(backendID: String, productID: String)
        case http(statusCode: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case let .noProfileDeclared(productID):
                return "'\(productID)' declares no discovery profile"
            case let .noCredential(productID):
                return "'\(productID)' requires a credential to list its models"
            case let .requestConstructionFailed(profileID):
                return "could not build a discovery request for profile '\(profileID)'"
            case let .transport(detail):
                return "discovery request failed: \(detail)"
            case let .empty(productID):
                return "upstream returned no models for '\(productID)'"
            case let .noBackendDeclared(productID):
                return "'\(productID)' declares no discovery backend adapter"
            case let .implementationMissing(productID):
                return "discovery implementation for '\(productID)' is missing or unverified"
            case let .backendUnavailable(backendID, productID):
                return "discovery backend '\(backendID)' for '\(productID)' is not registered or unavailable"
            case let .http(statusCode, body):
                return "discovery HTTP request failed with status \(statusCode): \(body)"
            }
        }
    }

    /// Models an upstream listing may include but which are not meant to be
    /// user-selectable. The ChatGPT backend exposes internal watermark variants
    /// alongside the public model of the same name.
    ///
    /// This filter lives here, once, rather than being re-implemented at every
    /// call site that touches a model list.
    public static func isUserSelectable(modelID: String) -> Bool {
        !(modelID.hasSuffix("-wm") || modelID.contains("-wm-"))
    }

    /// Evaluates whether a discovered model is user-selectable in UI / /model
    /// based on first-party metadata (such as upstream `visibility`).
    /// Verbatim discovery listings and caches preserve ALL returned models,
    /// but hidden upstream models (e.g. visibility: "hide") are excluded from user selection.
    public static func isUserSelectable(model: DiscoveredRemoteModel) -> Bool {
        guard isUserSelectable(modelID: model.id) else { return false }
        if model.visibility.lowercased() == "hide" {
            return false
        }
        return true
    }

    /// Discovers models for an API product by calling its declared upstream
    /// model-listing endpoint with the supplied credential.
    ///
    /// The endpoint and wire format come from the registry's discovery profile —
    /// no provider name is consulted anywhere in this path.
    public static func discoverAPIModels(
        product: RegistryProduct,
        credential: String?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> [DiscoveredRemoteModel] {
        guard let profile = product.discoveryProfile else {
            throw DiscoveryFailure.noProfileDeclared(productID: product.id)
        }
        let isPublic = profile.`public` ?? false
        if !isPublic, credential?.isEmpty != false {
            throw DiscoveryFailure.noCredential(productID: product.id)
        }
        guard let request = DiscoveryRequestBuilder.build(profile: profile, credential: credential) else {
            throw DiscoveryFailure.requestConstructionFailed(profileID: profile.id)
        }

        let data: Data
        let response: URLResponse
        do {
            if let httpClient {
                (data, response) = try await httpClient(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            throw DiscoveryFailure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryFailure.transport("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DiscoveryFailure.transport("HTTP \(http.statusCode)")
        }

        let parsed = try ModelListAdapters.parse(kind: profile.kind, data: data, source: profile.url)
        let filtered = parsed.filter { isUserSelectable(modelID: $0.id) }
        guard !filtered.isEmpty else {
            throw DiscoveryFailure.empty(productID: product.id)
        }
        return filtered
    }

    /// Discovers models for an OAuth-subscription product. These are not public
    /// APIs; the wire format is maintained in the adapter layer and dispatched
    /// dynamically through AuthenticatedDiscoveryBackendRegistry.
    public static func discoverAuthenticatedRemote(
        product: RegistryProduct,
        accessToken: String,
        endpoint: URL? = nil,
        requestProfile: OverlayRequestProfile? = nil,
        context: AuthenticatedDiscoveryContext? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> [DiscoveredRemoteModel] {
        guard let discoveryImpl = product.discoveryImplementation else {
            throw DiscoveryFailure.noBackendDeclared(productID: product.id)
        }
        guard discoveryImpl.status != "missing" else {
            throw DiscoveryFailure.implementationMissing(productID: product.id)
        }
        guard let backendID = discoveryImpl.backend else {
            throw DiscoveryFailure.noBackendDeclared(productID: product.id)
        }
        guard let backend = AuthenticatedDiscoveryBackendRegistry.shared.backend(for: backendID) else {
            throw DiscoveryFailure.backendUnavailable(backendID: backendID, productID: product.id)
        }

        let tokens = OAuthTokens(accessToken: accessToken)
        let resolvedProfile = requestProfile ?? BuiltinProviderCatalog.metadata(for: product.id).activeRequestProfile
        let discovered = try await backend.discoverModels(
            tokens: tokens,
            endpoint: endpoint,
            requestProfile: resolvedProfile,
            context: context,
            httpClient: httpClient
        )
        guard !discovered.isEmpty else {
            throw DiscoveryFailure.empty(productID: product.id)
        }
        return discovered
    }

    /// Runs discovery for a product according to its declared strategy and
    /// stores the outcome in the account-scoped cache.
    ///
    /// A failure never clears the cache: the previous list stays as
    /// last-known-good so an upstream outage cannot empty a user's model picker.
    @discardableResult
    public static func refresh(
        product: RegistryProduct,
        accountRef: String,
        credential: String?,
        cache: AccountScopedCatalogCache = .shared,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> Result<[DiscoveredRemoteModel], Error> {
        do {
            let models: [DiscoveredRemoteModel]
            switch product.discovery {
            case .endpoint, .staticCatalog:
                guard product.discoveryProfile != nil else {
                    // Nothing to discover against; the registry catalog already
                    // supplies whatever is published for this product.
                    return .success([])
                }
                models = try await discoverAPIModels(product: product, credential: credential, httpClient: httpClient)

            case .authenticatedRemote:
                guard let credential, !credential.isEmpty else {
                    return .failure(DiscoveryFailure.noCredential(productID: product.id))
                }
                models = try await discoverAuthenticatedRemote(
                    product: product,
                    accessToken: extractAccessToken(from: credential),
                    httpClient: httpClient
                )

            case .local, .custom:
                guard product.discoveryProfile != nil else { return .success([]) }
                models = try await discoverAPIModels(product: product, credential: credential, httpClient: httpClient)
            }

            guard !models.isEmpty else { return .success([]) }

            _ = try? await cache.save(
                productID: product.id,
                accountRef: accountRef,
                models: models,
                source: product.discoveryProfile?.url ?? "LingXi Registry",
                ttl: ttlSeconds(for: product)
            )
            return .success(models)
        } catch {
            // Keep the last-known-good list; only the freshness marker changes.
            await cache.markStale(productID: product.id, accountRef: accountRef)
            return .failure(error)
        }
    }

    /// Extracts the bearer token from whatever shape the credential store holds
    /// it in: a JSON OAuth token document, or a bare token string.
    static func extractAccessToken(from credential: String) -> String {
        if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(credential.utf8)) {
            return tokens.accessToken
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(credential.utf8)) as? [String: Any] {
            if let token = (json["accessToken"] as? String) ?? (json["access_token"] as? String) {
                return token
            }
        }
        return credential
    }

    private static func ttlSeconds(for product: RegistryProduct) -> TimeInterval {
        guard let raw = product.discoveryProfile?.cacheTTL,
              let seconds = parseDuration(raw) else {
            return 3600
        }
        return seconds
    }

    /// Parses a Go-style duration string ("30m", "6h", "90s").
    static func parseDuration(_ raw: String) -> TimeInterval? {
        guard let unit = raw.last else { return nil }
        let numberPart = raw.dropLast()
        guard let value = Double(numberPart) else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default: return nil
        }
    }
}
