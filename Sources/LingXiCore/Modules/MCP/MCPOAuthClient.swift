import Foundation
import CryptoKit
import LingXiProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Loopback Callback Server

public final class LoopbackOAuthServer: @unchecked Sendable {
    private var serverSock: Int32 = -1
    public private(set) var port: UInt16 = 0
    private var isClosed = false
    private let lock = NSLock()

    public init(preferredPort: UInt16 = 54321) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw CoreError(code: .transport, message: "Failed to allocate socket for OAuth callback")
        }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = preferredPort.bigEndian

        var bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            // Port in use, bind to ephemeral port (0)
            addr.sin_port = 0
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0 else {
            close(sock)
            throw CoreError(code: .transport, message: "Failed to bind loopback socket for OAuth callback")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualAddr = sockaddr_in()
        withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: actualAddr.sin_port)
        self.serverSock = sock

        listen(sock, 1)
    }

    deinit {
        closeServer()
    }

    public func closeServer() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed && serverSock >= 0 {
            close(serverSock)
            serverSock = -1
            isClosed = true
        }
    }

    public func waitForCallback(expectedState: String, timeoutSeconds: Double = 180.0) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "Callback server deallocated"))
                    return
                }

                self.lock.lock()
                let sock = self.serverSock
                self.lock.unlock()

                guard sock >= 0 else {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "Socket already closed"))
                    return
                }

                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sock, $0, &clientLen)
                    }
                }

                guard clientSock >= 0 else {
                    continuation.resume(throwing: CoreError(code: .transport, message: "Failed to accept OAuth callback connection"))
                    return
                }

                var buf = [CChar](repeating: 0, count: 4096)
                let bytesRead = read(clientSock, &buf, 4095)
                guard bytesRead > 0 else {
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .transport, message: "Empty OAuth callback request"))
                    return
                }

                let uint8Bytes = buf.prefix(bytesRead).map { UInt8(bitPattern: $0) }
                let reqStr = String(decoding: uint8Bytes, as: UTF8.self)
                guard let firstLine = reqStr.components(separatedBy: "\r\n").first,
                      let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                      let comp = URLComponents(string: "http://127.0.0.1\(urlPart)") else {
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .toolArgumentInvalid, message: "Invalid callback HTTP request"))
                    return
                }

                let state = comp.queryItems?.first(where: { $0.name == "state" })?.value
                let code = comp.queryItems?.first(where: { $0.name == "code" })?.value
                let error = comp.queryItems?.first(where: { $0.name == "error" })?.value

                let responseHTML = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <!DOCTYPE html>
                <html>
                <head><title>LingXiAgent · 授权成功</title><meta charset="utf-8"></head>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; text-align: center; padding: 60px; background: #0f172a; color: #f8fafc;">
                  <div style="max-width: 480px; margin: 0 auto; background: #1e293b; padding: 40px; border-radius: 16px; box-shadow: 0 10px 25px rgba(0,0,0,0.5);">
                    <h1 style="color: #38bdf8; font-size: 26px; margin-bottom: 16px;">✓ 授权成功</h1>
                    <p style="color: #94a3b8; font-size: 15px; line-height: 1.6;">LingXiAgent 已成功截获 OAuth 凭据，您可以关闭此网页并返回终端继续使用。</p>
                  </div>
                </body>
                </html>
                """

                _ = responseHTML.withCString {
                    write(clientSock, $0, strlen($0))
                }
                close(clientSock)
                self.closeServer()

                if let error {
                    continuation.resume(throwing: CoreError(code: .permissionDenied, message: "OAuth authorization denied: \(error)"))
                    return
                }

                guard state == expectedState else {
                    continuation.resume(throwing: CoreError(code: .permissionDenied, message: "OAuth state mismatch (possible CSRF attack)"))
                    return
                }

                guard let finalCode = code, !finalCode.isEmpty else {
                    continuation.resume(throwing: CoreError(code: .toolArgumentInvalid, message: "Missing authorization code in callback"))
                    return
                }

                continuation.resume(returning: finalCode)
            }
        }
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

    /// Automatically opens a URL in the default browser on macOS
    public static func openURLInBrowser(_ url: URL) {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.absoluteString]
        try? proc.run()
        #endif
    }
}
