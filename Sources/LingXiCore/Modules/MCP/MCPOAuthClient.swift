import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol
import LingXiPlatform

// MARK: - Loopback Callback Server

public final class LoopbackOAuthServer: @unchecked Sendable {
    private let platformServer: PlatformLoopbackServer

    public var port: UInt16 {
        platformServer.port
    }

    public init(preferredPort: UInt16 = 54321) throws {
        self.platformServer = try PlatformLoopbackServer(preferredPort: preferredPort)
    }

    public func closeServer() {
        platformServer.closeServer()
    }

    public func waitForCallback(expectedState: String, timeoutSeconds: Double = 180.0) async throws -> String {
        try await platformServer.waitForCallback(expectedState: expectedState, timeoutSeconds: timeoutSeconds)
    }
}

// MARK: - MCP OAuth Metadata Models

public struct MCPOAuthProtectedResourceMetadata: Codable, Sendable {
    public let resource: String?
    public let authorizationServers: [String]?
    public let scopesSupported: [String]?
    public let resourceName: String?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case resourceName = "resource_name"
    }
}

public struct MCPOAuthServerMetadata: Codable, Sendable {
    public let issuer: String?
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let registrationEndpoint: String?
    public let scopesSupported: [String]?
    public let codeChallengeMethodsSupported: [String]?
    public let tokenEndpointAuthMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }
}

public struct MCPOAuthRegistrationResponse: Codable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public let tokenEndpointAuthMethod: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

// MARK: - MCPOAuthClient Engine

public enum MCPOAuthClient {
    public struct DiscoveredEndpoints: Sendable {
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
        public let scopes: [String]
        public let resourceName: String?
    }

    /// Discovers OAuth endpoints according to RFC 9728 and RFC 8414
    public static func discoverEndpoints(for endpointURL: URL) async throws -> DiscoveredEndpoints {
        guard let host = endpointURL.host else {
            throw CoreError(code: .toolArgumentInvalid, message: "Invalid MCP server URL: \(endpointURL)")
        }

        let scheme = endpointURL.scheme ?? "https"
        var candidates: [URL] = []

        // Path-specific protected resource metadata (RFC 9728)
        let path = endpointURL.path
        if !path.isEmpty && path != "/" {
            if let u = URL(string: "\(scheme)://\(host)/.well-known/oauth-protected-resource\(path)") {
                candidates.append(u)
            }
        }
        if let u = URL(string: "\(scheme)://\(host)/.well-known/oauth-protected-resource") {
            candidates.append(u)
        }

        var protectedResource: MCPOAuthProtectedResourceMetadata?
        for candidate in candidates {
            if let (data, resp) = try? await URLSession.shared.data(from: candidate),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let meta = try? JSONDecoder().decode(MCPOAuthProtectedResourceMetadata.self, from: data) {
                protectedResource = meta
                break
            }
        }

        let authServerBase: String
        if let servers = protectedResource?.authorizationServers, let first = servers.first, !first.isEmpty {
            authServerBase = first
        } else {
            authServerBase = "\(scheme)://\(host)"
        }

        var serverMetaCandidates: [URL] = []
        if let u = URL(string: "\(authServerBase)/.well-known/oauth-authorization-server") {
            serverMetaCandidates.append(u)
        }
        if let u = URL(string: "\(authServerBase)/.well-known/openid-configuration") {
            serverMetaCandidates.append(u)
        }

        var authServerMeta: MCPOAuthServerMetadata?
        for candidate in serverMetaCandidates {
            if let (data, resp) = try? await URLSession.shared.data(from: candidate),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let meta = try? JSONDecoder().decode(MCPOAuthServerMetadata.self, from: data) {
                authServerMeta = meta
                break
            }
        }

        guard let authMeta = authServerMeta,
              let authURL = URL(string: authMeta.authorizationEndpoint),
              let tokenURL = URL(string: authMeta.tokenEndpoint) else {
            throw CoreError(code: .mcpServerUnavailable, message: "Could not discover OAuth authorization server metadata for \(endpointURL)")
        }

        let regURL = authMeta.registrationEndpoint.flatMap { URL(string: $0) }
        let scopes = protectedResource?.scopesSupported ?? authMeta.scopesSupported ?? ["default"]

        return DiscoveredEndpoints(
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL,
            registrationEndpoint: regURL,
            scopes: scopes,
            resourceName: protectedResource?.resourceName
        )
    }

    /// Performs Dynamic Client Registration (RFC 7591)
    public static func registerClient(
        registrationEndpoint: URL,
        redirectURI: URL,
        clientName: String = "LingXiAgent"
    ) async throws -> MCPOAuthRegistrationResponse {
        var req = URLRequest(url: registrationEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(decoding: data, as: UTF8.self)
            throw CoreError(code: .permissionDenied, message: "Dynamic client registration failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(bodyStr)")
        }

        return try JSONDecoder().decode(MCPOAuthRegistrationResponse.self, from: data)
    }

    /// Exchanges authorization code for OAuth access tokens
    public static func exchangeCodeForToken(
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String?,
        authMethod: String?,
        redirectURI: URL,
        code: String,
        codeVerifier: String
    ) async throws -> String {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var bodyParams: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ]

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        if let secret = clientSecret, !secret.isEmpty {
            if authMethod == nil || authMethod == "client_secret_basic" {
                let encID = clientID.addingPercentEncoding(withAllowedCharacters: allowed) ?? clientID
                let encSecret = secret.addingPercentEncoding(withAllowedCharacters: allowed) ?? secret
                let cred = "\(encID):\(encSecret)"
                let base64 = Data(cred.utf8).base64EncodedString()
                req.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            } else {
                bodyParams["client_id"] = clientID
                bodyParams["client_secret"] = secret
            }
        } else {
            bodyParams["client_id"] = clientID
        }
        let bodyStr = bodyParams.map { key, value in
            let encKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encKey)=\(encValue)"
        }.joined(separator: "&")
        req.httpBody = Data(bodyStr.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyErr = String(decoding: data, as: UTF8.self)
            throw CoreError(code: .permissionDenied, message: "Token exchange failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(bodyErr)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw CoreError(code: .provider, message: "No access_token found in token response")
        }

        return token
    }

    /// 自动在系统默认浏览器中打开授权 URL
    public static func openURLInBrowser(_ url: URL) {
        LingXiPlatform.system.openBrowser(at: url)
    }
}
