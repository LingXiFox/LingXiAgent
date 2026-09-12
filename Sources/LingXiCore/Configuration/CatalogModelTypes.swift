import Foundation
import LingXiProtocol

// MARK: - OAuth and request-profile knowledge
//
// These two types describe protocol and authentication facts that LingXi
// maintains by hand, which is why they survived the registry refactor.
//
// Everything else this file used to hold is gone: upstream snapshot DTOs, the
// generated catalog, and per-model overlay entries. Those existed to carry a
// checked-in model roster derived from models.dev, and a product's models now
// come from discovery instead. Keeping them would have kept two answers to the
// same question, one of them permanently stale.

/// OAuth authorization-server facts for a product.
public struct OverlayOAuth: Codable, Sendable, Equatable {
    public let provider: String
    public let clientID: String
    public let authURL: String
    public let tokenURL: String
    public let scopes: [String]
    public let usePKCE: Bool
    public let requestProfileID: String
    public let redirectURI: String?

    public init(
        provider: String,
        clientID: String,
        authURL: String,
        tokenURL: String,
        scopes: [String],
        usePKCE: Bool = true,
        requestProfileID: String,
        redirectURI: String? = nil
    ) {
        self.provider = provider
        self.clientID = clientID
        self.authURL = authURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.usePKCE = usePKCE
        self.requestProfileID = requestProfileID
        self.redirectURI = redirectURI
    }
}

/// A versioned request-compatibility profile: which headers an upstream
/// requires, which user agent to present, and how conservative to be.
public struct OverlayRequestProfile: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let compatibilityMode: String // "conservative" | "officialLike"
    public let endpointOverride: String?
    public let requiredHeaders: [String: String]?
    public let dynamicHeaders: [String: String]?
    public let userAgentProfile: String?

    public init(
        id: String,
        version: String,
        compatibilityMode: String = "conservative",
        endpointOverride: String? = nil,
        requiredHeaders: [String: String]? = nil,
        dynamicHeaders: [String: String]? = nil,
        userAgentProfile: String? = nil
    ) {
        self.id = id
        self.version = version
        self.compatibilityMode = compatibilityMode
        self.endpointOverride = endpointOverride
        self.requiredHeaders = requiredHeaders
        self.dynamicHeaders = dynamicHeaders
        self.userAgentProfile = userAgentProfile
    }
}
