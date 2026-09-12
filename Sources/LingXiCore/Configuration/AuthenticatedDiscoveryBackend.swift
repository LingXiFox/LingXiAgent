import Foundation
import LingXiProtocol

/// Execution context for authenticated discovery backends, holding account metadata,
/// project bootstrap state, and subscription tier facts.
public struct AuthenticatedDiscoveryContext: Sendable, Equatable {
    public var accountIdentity: String?
    public var project: String?
    public var projectSource: String?
    public var tier: String?
    public var extra: [String: String]

    public init(
        accountIdentity: String? = nil,
        project: String? = nil,
        projectSource: String? = nil,
        tier: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.accountIdentity = accountIdentity
        self.project = project
        self.projectSource = projectSource
        self.tier = tier
        self.extra = extra
    }
}

/// Strategy for authenticated model catalog discovery. Concrete backends implement
/// upstream-specific protocols (e.g. ChatGPT Codex, Google Cloud Code / Antigravity)
/// without the runtime needing hardcoded product ID switches.
public protocol AuthenticatedDiscoveryBackend: Sendable {
    var backendID: String { get }

    func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL?,
        requestProfile: OverlayRequestProfile?,
        context: AuthenticatedDiscoveryContext?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel]
}

/// Thread-safe registry mapping discovery backend identifiers to concrete strategies.
public final class AuthenticatedDiscoveryBackendRegistry: @unchecked Sendable {
    public static let shared = AuthenticatedDiscoveryBackendRegistry()

    private let lock = NSLock()
    private var backends: [String: any AuthenticatedDiscoveryBackend] = [:]

    public init() {
        register(CodexAuthenticatedDiscoveryBackend())
        register(AntigravityAuthenticatedDiscoveryBackend())
        // Note: googleCodeAssistCatalog is deliberately omitted until
        // independent observed evidence is verified.
    }

    public func register(_ backend: any AuthenticatedDiscoveryBackend) {
        lock.lock()
        defer { lock.unlock() }
        backends[backend.backendID] = backend
    }

    public func unregister(backendID: String) {
        lock.lock()
        defer { lock.unlock() }
        backends.removeValue(forKey: backendID)
    }

    public func backend(for backendID: String) -> (any AuthenticatedDiscoveryBackend)? {
        lock.lock()
        defer { lock.unlock() }
        return backends[backendID]
    }
}

/// Built-in backend for OpenAI Codex authenticated catalog discovery.
public struct CodexAuthenticatedDiscoveryBackend: AuthenticatedDiscoveryBackend {
    public let backendID = "codexAuthenticatedCatalog"

    public init() {}

    public func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL?,
        requestProfile: OverlayRequestProfile?,
        context: AuthenticatedDiscoveryContext?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        try await CodexRemoteModelDiscovery.discoverModels(
            tokens: tokens,
            endpoint: endpoint,
            requestProfile: requestProfile,
            httpClient: httpClient
        )
    }
}
