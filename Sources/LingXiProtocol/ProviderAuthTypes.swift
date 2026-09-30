import Foundation

// Contract for GUI-initiated provider sign-in. The whole token lifecycle lives
// in Core: a front end receives an authorize URL, opens it, and then reads a
// phase. Access tokens, refresh tokens and the callback listener never cross
// this boundary.

/// A provider product Core can actually sign a user in to.
public struct ProviderAuthProduct: Codable, Sendable, Equatable, Identifiable {
    public let productID: String
    public let displayName: String
    /// Auth methods as the product registry states them, e.g. `oauthPKCE`.
    public let authMethods: [String]
    /// True when the product's redirect URI is a loopback URL Core can listen on.
    public let loopbackCallback: Bool

    public var id: String { productID }

    public init(productID: String, displayName: String, authMethods: [String], loopbackCallback: Bool) {
        self.productID = productID
        self.displayName = displayName
        self.authMethods = authMethods
        self.loopbackCallback = loopbackCallback
    }
}

/// Where a sign-in flow stands. `connected` says the vault holds usable tokens;
/// it never carries them.
public enum ProviderAuthPhase: String, Codable, Sendable, Equatable {
    /// Waiting for the browser to return through the loopback callback.
    case awaitingCallback
    /// Callback received; exchanging the code for tokens.
    case exchanging
    /// Tokens stored and the account usable.
    case connected
    /// Sign-in failed; `message` is a user-readable cause.
    case failed
    /// The stored credential no longer works and the user must sign in again.
    case needsReauthentication
    /// Cancelled by the user or by Core.
    case cancelled
}

public struct BeginProviderAuthRequest: Codable, Sendable, Equatable {
    public let productID: String
    public init(productID: String) { self.productID = productID }
}

/// One sign-in flow as the front end sees it.
public struct ProviderAuthFlow: Codable, Sendable, Equatable {
    public let flowID: String
    public let productID: String
    /// URL to hand to the system browser. Present only while the flow waits.
    public let authorizeURL: String?
    public let phase: ProviderAuthPhase
    /// Readable cause for `failed`; nil otherwise.
    public let message: String?

    public init(flowID: String, productID: String, authorizeURL: String? = nil,
                phase: ProviderAuthPhase, message: String? = nil) {
        self.flowID = flowID
        self.productID = productID
        self.authorizeURL = authorizeURL
        self.phase = phase
        self.message = message
    }
}

public struct GetProviderAuthFlowRequest: Codable, Sendable, Equatable {
    public let flowID: String
    public init(flowID: String) { self.flowID = flowID }
}

public struct CancelProviderAuthRequest: Codable, Sendable, Equatable {
    public let flowID: String
    public init(flowID: String) { self.flowID = flowID }
}

/// Connects a registry product with whatever its own contract requires.
///
/// The key never appears here: it is staged in Core's vault first and referenced.
/// Built-in products carry their endpoint, so the form sends no URL.
public struct ConnectProviderRequest: Codable, Sendable, Equatable {
    public let productID: String
    public var credentialRef: CredentialRef?
    /// Only for products whose contract requires a local endpoint.
    public var endpoint: String?
    /// Values for `requiredAccountFields` the product declares.
    public var fields: [String: String]
    /// Models to configure. Only published-index providers need them; a curated
    /// registry product discovers its own list.
    public var modelIDs: [String]

    public init(productID: String, credentialRef: CredentialRef? = nil, endpoint: String? = nil,
                fields: [String: String] = [:], modelIDs: [String] = []) {
        self.productID = productID
        self.credentialRef = credentialRef
        self.endpoint = endpoint
        self.fields = fields
        self.modelIDs = modelIDs
    }
}
