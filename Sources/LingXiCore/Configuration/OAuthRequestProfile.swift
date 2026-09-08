import Foundation
import LingXiProtocol

public enum RequestCompatibilityMode: String, Codable, Sendable, Equatable {
    case conservative
    case officialLike
}

public struct RequestProfileProvenance: Codable, Sendable, Equatable {
    public let profileVersion: String
    public let verifiedAt: String
    public let evidenceSources: [String]
    public let compatibilityStatus: String
    public let knownRequiredHeaders: [String: String]
    public let optionalOfficialLikeHeaders: [String: String]

    public init(
        profileVersion: String,
        verifiedAt: String,
        evidenceSources: [String] = [],
        compatibilityStatus: String = "compatibleNonOfficial",
        knownRequiredHeaders: [String: String] = [:],
        optionalOfficialLikeHeaders: [String: String] = [:]
    ) {
        self.profileVersion = profileVersion
        self.verifiedAt = verifiedAt
        self.evidenceSources = evidenceSources
        self.compatibilityStatus = compatibilityStatus
        self.knownRequiredHeaders = knownRequiredHeaders
        self.optionalOfficialLikeHeaders = optionalOfficialLikeHeaders
    }
}

public struct OAuthRequestProfile: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let compatibilityMode: RequestCompatibilityMode
    public let endpointOverride: URL?
    public let requiredHeaders: [String: String]
    public let dynamicHeaders: [String: String]
    public let userAgentProfile: String?
    public let stripHeaders: [String]
    public let authHeaderOwnership: Bool
    public let provenance: RequestProfileProvenance?

    public init(
        id: String,
        version: String,
        compatibilityMode: RequestCompatibilityMode = .conservative,
        endpointOverride: URL? = nil,
        requiredHeaders: [String: String] = [:],
        dynamicHeaders: [String: String] = [:],
        userAgentProfile: String? = nil,
        stripHeaders: [String] = [],
        authHeaderOwnership: Bool = true,
        provenance: RequestProfileProvenance? = nil
    ) {
        self.id = id
        self.version = version
        self.compatibilityMode = compatibilityMode
        self.endpointOverride = endpointOverride
        self.requiredHeaders = requiredHeaders
        self.dynamicHeaders = dynamicHeaders
        self.userAgentProfile = userAgentProfile
        self.stripHeaders = stripHeaders
        self.authHeaderOwnership = authHeaderOwnership
        self.provenance = provenance
    }

    public func apply(to request: inout URLRequest) {
        // 1. Endpoint override if provided
        if let overrideURL = endpointOverride {
            // Rewrite baseURL scheme, host, port while preserving request path
            if var components = URLComponents(url: request.url ?? overrideURL, resolvingAgainstBaseURL: true),
               let overrideComp = URLComponents(url: overrideURL, resolvingAgainstBaseURL: true) {
                components.scheme = overrideComp.scheme
                components.host = overrideComp.host
                components.port = overrideComp.port
                if let newURL = components.url {
                    request.url = newURL
                }
            }
        }

        // 2. Strip specified headers
        for h in stripHeaders {
            request.setValue(nil, forHTTPHeaderField: h)
        }

        // 3. Apply required headers
        for (k, v) in requiredHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // 4. Apply dynamic headers
        for (k, v) in dynamicHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // 5. Apply User-Agent profile
        if let ua = userAgentProfile {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    /// Redacts sensitive auth values for logging
    public static func redactSensitiveValue(_ value: String, header: String) -> String {
        let lower = header.lowercased()
        if lower == "authorization" {
            if value.lowercased().hasPrefix("bearer ") {
                let tokenPart = String(value.dropFirst(7))
                let preview = tokenPart.count > 8 ? "\(tokenPart.prefix(4))...\(tokenPart.suffix(4))" : "***"
                return "Bearer [REDACTED:len=\(tokenPart.count):\(preview)]"
            }
            return "[REDACTED:len=\(value.count)]"
        }
        if lower.contains("key") || lower.contains("token") || lower.contains("secret") {
            let preview = value.count > 8 ? "\(value.prefix(4))...\(value.suffix(4))" : "***"
            return "[REDACTED:len=\(value.count):\(preview)]"
        }
        return value
    }
}
