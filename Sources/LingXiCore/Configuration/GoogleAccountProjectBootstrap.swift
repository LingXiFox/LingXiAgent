import Foundation
import LingXiProtocol

/// The provenance of a Google Cloud project identifier used during discovery.
public enum GoogleProjectSource: String, Codable, Sendable {
    /// Provided directly by explicit configuration (account fields / options).
    case explicitConfig
    /// Returned by Google's upstream loadCodeAssist RPC (e.g. cloudaicompanion_project).
    case upstreamBootstrap
    /// No project was supplied or returned; requests proceed without a project parameter.
    case none
    /// Project semantics are unverified pending independent first-party empirical evidence (e.g. Gemini Code Assist).
    case unverified
}

/// Result of the Google Account / Project Bootstrap phase.
public struct GoogleBootstrapResult: Sendable, Equatable {
    public let project: String?
    public let projectSource: GoogleProjectSource
    public let tier: String?
    public let accountIdentity: String?
    public let rawMetadata: [String: String]

    public init(
        project: String?,
        projectSource: GoogleProjectSource,
        tier: String? = nil,
        accountIdentity: String? = nil,
        rawMetadata: [String: String] = [:]
    ) {
        self.project = project
        self.projectSource = projectSource
        self.tier = tier
        self.accountIdentity = accountIdentity
        self.rawMetadata = rawMetadata
    }
}

/// Discovers Google account project and tier context before invoking model listing.
/// Layered strictly as:
/// OAuth Credential -> Google Account Metadata -> Project/Tier Bootstrap -> Authenticated Model Discovery
public enum GoogleAccountProjectBootstrap {
    public static let defaultBootstrapEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    /// Resolves project and subscription tier context without synthetic defaults or cross-product leakage.
    public static func bootstrap(
        tokens: OAuthTokens,
        endpoint: URL? = nil,
        requestProfile: OverlayRequestProfile? = nil,
        context: AuthenticatedDiscoveryContext? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> GoogleBootstrapResult {
        // 1. If project was already explicitly supplied in context, honor it verbatim.
        if let explicit = context?.project, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GoogleBootstrapResult(
                project: explicit,
                projectSource: .explicitConfig,
                tier: context?.tier,
                accountIdentity: context?.accountIdentity
            )
        }

        let targetURL = endpoint ?? defaultBootstrapEndpoint
        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let defaultUA = ClientFingerprint.userAgent(for: "antigravity")
        let ua = requestProfile?.userAgentProfile ?? defaultUA
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let clientHeader = ClientFingerprint.headers(for: "antigravity")["X-Goog-Api-Client"] {
            request.setValue(clientHeader, forHTTPHeaderField: "X-Goog-Api-Client")
        }

        if let headers = requestProfile?.requiredHeaders {
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        // Empty body or basic health check mode
        request.httpBody = "{}".data(using: .utf8)

        let execute = httpClient ?? { req in
            try await URLSession.shared.data(for: req)
        }

        let (data, response) = try await execute(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // If bootstrap fails or returns non-200, return none without guessing
            return GoogleBootstrapResult(
                project: nil,
                projectSource: .none,
                tier: context?.tier,
                accountIdentity: context?.accountIdentity
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GoogleBootstrapResult(
                project: nil,
                projectSource: .none,
                tier: context?.tier,
                accountIdentity: context?.accountIdentity
            )
        }

        // Upstream first-party field names from Protobuf:
        // cloudaicompanion_project or cloudaicompanionProject
        let companionProject = (json["cloudaicompanion_project"] as? String)
            ?? (json["cloudaicompanionProject"] as? String)

        // Tier information from Protobuf: current_tier or currentTier
        let tier = (json["current_tier"] as? String)
            ?? (json["currentTier"] as? String)
            ?? context?.tier

        var raw: [String: String] = [:]
        if let companionProject { raw["cloudaicompanion_project"] = companionProject }
        if let tier { raw["current_tier"] = tier }

        let resolvedProject: String? = {
            if let p = companionProject, !p.isEmpty { return p }
            return nil
        }()

        let source: GoogleProjectSource = resolvedProject != nil ? .upstreamBootstrap : .none

        return GoogleBootstrapResult(
            project: resolvedProject,
            projectSource: source,
            tier: tier,
            accountIdentity: context?.accountIdentity,
            rawMetadata: raw
        )
    }
}
