import Foundation
import LingXiPlatform
import LingXiProtocol

/// Owns sign-in flows that a front end starts.
///
/// Core is the single owner of the OAuth lifecycle: it builds the authorize URL,
/// listens for the browser's callback on loopback, exchanges the code, stores the
/// tokens in the credential vault and refreshes the account-scoped catalog.
/// A front end only ever sees a flow ID, the authorize URL and a phase — never a
/// token, and never the callback itself.
public actor ProviderAuthCoordinator {

    /// How long a flow waits for the browser to come back.
    public static let callbackTimeout: TimeInterval = 180

    private struct Flow {
        let id: String
        let productID: String
        let authorizeURL: URL
        let state: String
        var phase: ProviderAuthPhase
        var message: String?
        let server: PlatformLoopbackServer
        var task: Task<Void, Never>?
    }

    public struct Started: Sendable, Equatable {
        public let flowID: String
        public let authorizeURL: String
    }

    private let credentialStore: CredentialStore
    private let configurationStore: ConfigurationStore?
    private let httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private var flows: [String: Flow] = [:]

    public init(
        credentialStore: CredentialStore,
        configurationStore: ConfigurationStore?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.credentialStore = credentialStore
        self.configurationStore = configurationStore
        self.httpClient = httpClient
    }

    /// Products Core can actually sign a user in to: an OAuth configuration that
    /// states both endpoints, and a loopback redirect the callback can land on.
    public static func authProducts() -> [ProviderAuthProduct] {
        BuiltinProviderCatalog.profiles.compactMap { profile in
            guard let oauth = BuiltinProviderCatalog.metadata(for: profile.id).oauth,
                  URL(string: oauth.authURL) != nil, URL(string: oauth.tokenURL) != nil else { return nil }
            let redirect = URL(string: oauth.redirectURI ?? "http://localhost:1455/auth/callback")
            let loopback = redirect?.host.map { $0 == "localhost" || $0 == "127.0.0.1" } ?? false
            return ProviderAuthProduct(
                productID: profile.id,
                displayName: profile.displayName,
                authMethods: profile.authMethods,
                loopbackCallback: loopback)
        }
    }

    public func begin(productID: String) async throws -> Started {
        guard let oauth = BuiltinProviderCatalog.metadata(for: productID).oauth,
              let authEndpoint = URL(string: oauth.authURL),
              let tokenEndpoint = URL(string: oauth.tokenURL) else {
            throw CoreError(code: .provider, message: "\(productID) 没有可用的 OAuth 配置")
        }
        let declared = URL(string: oauth.redirectURI ?? "http://localhost:1455/auth/callback")
        guard let declared, let port = declared.port else {
            throw CoreError(code: .provider, message: "\(productID) 的回调地址没有明确端口，无法在 GUI 中完成登录")
        }
        // The redirect URI must be exactly the one the provider registered, so
        // Core binds that port instead of picking a free one.
        let server: PlatformLoopbackServer
        do {
            server = try PlatformLoopbackServer(preferredPort: UInt16(port))
        } catch {
            throw CoreError(code: .provider, message: "回调端口 \(port) 无法监听：\(error.localizedDescription)")
        }
        guard Int(server.port) == port else {
            server.close()
            throw CoreError(code: .provider, message: "\(productID) 需要回调端口 \(port)，但该端口被占用")
        }

        let authorization = OAuthFlowCoordinator.makeAuthorizationURL(
            authEndpoint: authEndpoint,
            clientID: oauth.clientID,
            redirectURI: declared,
            scopes: oauth.scopes,
            usePKCE: oauth.usePKCE)
        let flowID = UUID().uuidString
        flows[flowID] = Flow(id: flowID, productID: productID, authorizeURL: authorization.authorizeURL,
                             state: authorization.state, phase: .awaitingCallback, server: server)

        let credentialStore = self.credentialStore
        let configurationStore = self.configurationStore
        let httpClient = self.httpClient
        flows[flowID]?.task = Task { [weak self] in
            let outcome = await Self.complete(
                productID: productID,
                oauth: oauth,
                redirectURI: declared,
                tokenEndpoint: tokenEndpoint,
                codeVerifier: authorization.codeVerifier,
                state: authorization.state,
                server: server,
                credentialStore: credentialStore,
                configurationStore: configurationStore,
                httpClient: httpClient)
            await self?.record(phase: outcome.phase, message: outcome.message, flowID: flowID)
        }
        return Started(flowID: flowID, authorizeURL: authorization.authorizeURL.absoluteString)
    }

    public func status(flowID: String) -> ProviderAuthFlow? {
        guard let flow = flows[flowID] else { return nil }
        return ProviderAuthFlow(
            flowID: flow.id,
            productID: flow.productID,
            authorizeURL: flow.phase == .awaitingCallback ? flow.authorizeURL.absoluteString : nil,
            phase: flow.phase,
            message: flow.message)
    }

    public func cancel(flowID: String) {
        guard let flow = flows[flowID] else { return }
        // A finished login is a fact about the vault; cancelling the view of it
        // must not pretend the account is not there.
        guard flow.phase == .awaitingCallback || flow.phase == .exchanging else { return }
        flow.task?.cancel()
        flow.server.close()
        flows[flowID]?.phase = .cancelled
        flows[flowID]?.message = nil
    }

    /// Ends every waiting flow; called when Core shuts down or the workspace closes.
    public func shutdown() {
        for flow in flows.values {
            flow.task?.cancel()
            flow.server.close()
        }
        flows.removeAll()
    }

    private func record(phase: ProviderAuthPhase, message: String?, flowID: String) {
        guard var flow = flows[flowID] else { return }
        // A cancelled flow stays cancelled even if the callback arrives late.
        if flow.phase == .cancelled { return }
        flow.phase = phase
        flow.message = message
        flows[flowID] = flow
    }

    /// Waits for the browser, exchanges the code and persists the tokens.
    /// Runs outside actor isolation so the 180s wait never blocks other flows.
    private static func complete(
        productID: String,
        oauth: OverlayOAuth,
        redirectURI: URL,
        tokenEndpoint: URL,
        codeVerifier: String,
        state: String,
        server: PlatformLoopbackServer,
        credentialStore: CredentialStore,
        configurationStore: ConfigurationStore?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async -> (phase: ProviderAuthPhase, message: String?) {
        defer { server.close() }
        let code: String
        do {
            code = try await server.waitForCallback(expectedState: state, timeoutSeconds: callbackTimeout)
        } catch {
            return (.failed, "等待浏览器回调失败：\(error.localizedDescription)")
        }
        let tokens: OAuthTokens
        do {
            tokens = try await OAuthFlowCoordinator.exchangeCodeForTokens(
                tokenEndpoint: tokenEndpoint,
                clientID: oauth.clientID,
                redirectURI: redirectURI,
                code: code,
                codeVerifier: codeVerifier,
                client: httpClient)
        } catch {
            return (.failed, "换取令牌失败：\(error.localizedDescription)")
        }

        let reference = CredentialRef("provider-\(productID)-oauth")
        do {
            let serialized = try JSONEncoder().encode(tokens)
            try await credentialStore.setSecret(String(data: serialized, encoding: .utf8) ?? "", for: reference)
        } catch {
            return (.failed, "凭据保存失败：\(error.localizedDescription)")
        }

        // The account's own model listing, cached per account like the CLI does.
        if let product = BuiltinProviderCatalog.registryProduct(id: productID) {
            let accountRef = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: tokens.accessToken)
            do {
                let discovered = try await AccountModelDiscovery.discoverAuthenticatedRemote(
                    product: product, accessToken: tokens.accessToken, httpClient: httpClient)
                try await AccountScopedCatalogCache.shared.save(
                    productID: productID, accountRef: accountRef, models: discovered)
            } catch {
                await AccountScopedCatalogCache.shared.markStale(productID: productID, accountRef: accountRef)
            }
        }
        // A signed-in account is not a providers.json entry; drop any stale one so
        // the vault credential stays the only source.
        if let configurationStore {
            let snapshot = try? await configurationStore.load()
            if snapshot?.providers.providers[productID] != nil {
                var providers = snapshot!.providers.providers
                providers.removeValue(forKey: productID)
                try? await configurationStore.saveProviders(ProvidersConfiguration(
                    schema: snapshot!.providers.schema, version: snapshot!.providers.version,
                    model: snapshot!.providers.model, providers: providers))
            }
        }
        return (.connected, nil)
    }
}
