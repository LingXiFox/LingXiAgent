import Foundation
import CryptoKit
import LingXiProtocol
#if canImport(Network)
import Network
#endif

// MARK: - PKCE Utilities (RFC 7636)

public enum PKCE {
    public static func generateVerifier(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func challenge(for verifier: String) -> String {
        guard let data = verifier.data(using: .ascii) else { return "" }
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth Callback Listener

public actor OAuthCallbackServer {
    public enum CallbackResult: Sendable, Equatable {
        case success(code: String)
        case error(String)
        case stateMismatch
    }

    private let expectedState: String
    private var completionContinuation: CheckedContinuation<CallbackResult, Never>?

    public init(expectedState: String) {
        self.expectedState = expectedState
    }

    /// Validates callback query parameters against the expected state
    public func handleCallbackURL(_ url: URL) -> CallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = components.queryItems else {
            return .error("Missing query items in callback URL")
        }

        let state = items.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            return .stateMismatch
        }

        if let error = items.first(where: { $0.name == "error" })?.value {
            let errorDesc = items.first(where: { $0.name == "error_description" })?.value ?? error
            return .error(errorDesc)
        }

        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .error("Missing authorization code in callback")
        }

        return .success(code: code)
    }

    public func finish(result: CallbackResult) {
        completionContinuation?.resume(returning: result)
        completionContinuation = nil
    }
}

// MARK: - OAuth Flow Coordinator

public enum OAuthFlowCoordinator {
    public struct AuthorizeURLResult: Sendable, Equatable {
        public let authorizeURL: URL
        public let state: String
        public let codeVerifier: String
    }

    public static func makeAuthorizationURL(
        authEndpoint: URL,
        clientID: String,
        redirectURI: URL,
        scopes: [String],
        usePKCE: Bool = true
    ) -> AuthorizeURLResult {
        let state = PKCE.generateVerifier(length: 16)
        let verifier = PKCE.generateVerifier(length: 32)
        let challenge = PKCE.challenge(for: verifier)

        var comp = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: true)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        if usePKCE {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        comp.queryItems = items
        return AuthorizeURLResult(authorizeURL: comp.url!, state: state, codeVerifier: verifier)
    }

    public static func exchangeCodeForTokens(
        tokenEndpoint: URL,
        clientID: String,
        redirectURI: URL,
        code: String,
        codeVerifier: String,
        client: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        if let client {
            (data, response) = try await client(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CoreError(code: .provider, message: "Token exchange failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        struct TokenExchangeResponse: Codable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            let scope: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case scope
            }
        }

        let decoded = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        let expiresAt = decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: expiresAt
        )
    }
}
