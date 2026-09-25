import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// Unified authentication strategy decoupling auth from protocol adapters.
public protocol AuthStrategy: Sendable {
    func apply(to request: inout URLRequest) async throws
}

public struct NoAuthStrategy: AuthStrategy {
    public init() {}
    public func apply(to request: inout URLRequest) async throws {
        // No authentication required
    }
}

public struct APIKeyHeaderAuthStrategy: AuthStrategy {
    public let headerName: String
    public let key: String

    public init(headerName: String, key: String) {
        self.headerName = headerName
        self.key = key
    }

    public func apply(to request: inout URLRequest) async throws {
        request.setValue(key, forHTTPHeaderField: headerName)
    }
}

public struct BearerAuthStrategy: AuthStrategy {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public func apply(to request: inout URLRequest) async throws {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

public struct OAuthCredentialMetadata: Codable, Sendable, Equatable {
    public let providerID: String
    public let clientID: String
    public let scopes: [String]
    public let tokenEndpoint: String

    public init(providerID: String, clientID: String, scopes: [String] = [], tokenEndpoint: String) {
        self.providerID = providerID
        self.clientID = clientID
        self.scopes = scopes
        self.tokenEndpoint = tokenEndpoint
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// OAuth 认证生命周期状态
public enum OAuthAuthState: String, Sendable, Codable, Equatable {
    /// 令牌有效或刚自动刷新成功
    case valid
    /// 正在后台自动刷新令牌
    case refreshing
    /// 刷新遇到临时错误（网络抖动或服务端非 400/401 错误，凭据未被判定失效）
    case refreshFailedTransient
    /// 刷新端点明确返回 invalid_grant 或 RT 无效/缺失，凭据已彻底失效，必须重新认证
    case reauthenticationRequired
}

public enum OAuthRefreshError: Error, Sendable, LocalizedError, Equatable {
    case missingRefreshToken
    case invalidGrant(message: String)
    case networkOrServerError(statusCode: Int, message: String)
    case invalidEndpoint(String)

    public var isRevokedOrInvalidGrant: Bool {
        switch self {
        case .missingRefreshToken, .invalidGrant:
            return true
        case .networkOrServerError, .invalidEndpoint:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "OAuth Refresh Token 缺失，无法完成刷新，请重新登录"
        case .invalidGrant(let msg):
            return "OAuth 授权已被撤销或已失效 (\(msg))，请重新登录"
        case .networkOrServerError(let status, let msg):
            return "OAuth Token 刷新遇到临时网络或服务错误 (HTTP \(status): \(msg))"
        case .invalidEndpoint(let ep):
            return "无效的 OAuth Token 端点: \(ep)"
        }
    }
}

private final class ThreadSafeTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String

    init(_ token: String) {
        self.token = token
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func set(_ value: String) {
        lock.lock()
        token = value
        lock.unlock()
    }
}

public actor OAuthTokenRefresher {
    public let metadata: OAuthCredentialMetadata
    public private(set) var currentTokens: OAuthTokens
    public private(set) var authState: OAuthAuthState = .valid
    public private(set) var lastErrorMessage: String? = nil
    private let credentialStore: CredentialStore
    private let tokenRef: CredentialRef
    private var refreshTask: Task<String, Error>?
    public private(set) var refreshCallCount: Int = 0
    private let client: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private let tokenBox: ThreadSafeTokenBox

    nonisolated public var cachedAccessToken: String {
        tokenBox.get()
    }

    public init(
        metadata: OAuthCredentialMetadata,
        tokens: OAuthTokens,
        credentialStore: CredentialStore,
        tokenRef: CredentialRef,
        client: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.metadata = metadata
        self.currentTokens = tokens
        self.credentialStore = credentialStore
        self.tokenRef = tokenRef
        self.client = client
        self.tokenBox = ThreadSafeTokenBox(tokens.accessToken)
        if tokens.refreshToken == nil && (tokens.expiresAt != nil && tokens.expiresAt!.timeIntervalSinceNow <= 30) {
            self.authState = .reauthenticationRequired
            self.lastErrorMessage = "缺少 Refresh Token 且 Access Token 已过期"
        } else {
            self.authState = .valid
        }
    }

    public func updateTokensIfChanged(_ newTokens: OAuthTokens) {
        if newTokens.accessToken != currentTokens.accessToken || newTokens.refreshToken != currentTokens.refreshToken || newTokens.expiresAt != currentTokens.expiresAt {
            self.currentTokens = newTokens
            tokenBox.set(newTokens.accessToken)
            self.authState = .valid
            self.lastErrorMessage = nil
        }
    }

    public func markReauthenticationRequired(reason: String) {
        self.authState = .reauthenticationRequired
        self.lastErrorMessage = reason
    }

    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if authState == .reauthenticationRequired && !forceRefresh {
            throw OAuthRefreshError.invalidGrant(message: lastErrorMessage ?? "OAuth 授权已失效，请重新登录")
        }

        // Return active token if not forced and not expiring within 30 seconds
        if !forceRefresh {
            if let expiresAt = currentTokens.expiresAt {
                if expiresAt.timeIntervalSinceNow > 30 {
                    return currentTokens.accessToken
                }
            } else {
                // If no expiration provided and not forced, consider current token valid
                return currentTokens.accessToken
            }
        }

        guard let rt = currentTokens.refreshToken, !rt.isEmpty else {
            authState = .reauthenticationRequired
            lastErrorMessage = "缺少 Refresh Token"
            if forceRefresh {
                throw OAuthRefreshError.missingRefreshToken
            }
            return currentTokens.accessToken
        }

        // Mutex debounced refresh: reuse in-flight task across concurrent callers
        if let inFlight = refreshTask {
            return try await inFlight.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CoreError(code: .provider, message: "Refresher deallocated") }
            return try await self.executeRefresh()
        }
        refreshTask = task

        do {
            let result = try await task.value
            refreshTask = nil
            return result
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func executeRefresh() async throws -> String {
        refreshCallCount += 1
        guard let refreshToken = currentTokens.refreshToken, !refreshToken.isEmpty else {
            self.authState = .reauthenticationRequired
            self.lastErrorMessage = "缺少 Refresh Token"
            throw OAuthRefreshError.missingRefreshToken
        }
        guard let url = URL(string: metadata.tokenEndpoint) else {
            self.authState = .refreshFailedTransient
            self.lastErrorMessage = "无效的 token endpoint: \(metadata.tokenEndpoint)"
            throw OAuthRefreshError.invalidEndpoint(metadata.tokenEndpoint)
        }

        self.authState = .refreshing

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": metadata.clientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            if let client {
                (data, response) = try await client(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            self.authState = .refreshFailedTransient
            self.lastErrorMessage = error.localizedDescription
            throw OAuthRefreshError.networkOrServerError(statusCode: -1, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            self.authState = .refreshFailedTransient
            throw OAuthRefreshError.networkOrServerError(statusCode: -1, message: "非 HTTP 响应")
        }

        if !(200...299).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            let errorText: String
            var isInvalidGrant = false
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let errCode = (json["error"] as? String) ?? ""
                let errDesc = (json["error_description"] as? String) ?? (json["message"] as? String) ?? ""
                errorText = errDesc.isEmpty ? errCode : "\(errCode): \(errDesc)"
                if errCode == "invalid_grant" || errDesc.lowercased().contains("invalid_grant") || errDesc.lowercased().contains("revoked") || errDesc.lowercased().contains("expired token") {
                    isInvalidGrant = true
                }
            } else {
                errorText = bodyStr
                if bodyStr.lowercased().contains("invalid_grant") || bodyStr.lowercased().contains("revoked") {
                    isInvalidGrant = true
                }
            }

            if isInvalidGrant || (http.statusCode == 400 && errorText.contains("invalid_grant")) {
                self.authState = .reauthenticationRequired
                self.lastErrorMessage = errorText.isEmpty ? "invalid_grant" : errorText
                throw OAuthRefreshError.invalidGrant(message: self.lastErrorMessage!)
            } else {
                self.authState = .refreshFailedTransient
                self.lastErrorMessage = "HTTP \(http.statusCode) - \(errorText)"
                throw OAuthRefreshError.networkOrServerError(statusCode: http.statusCode, message: errorText)
            }
        }

        let json = try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
        var newTokens = currentTokens
        newTokens.accessToken = json.accessToken
        if let newRefreshToken = json.refreshToken, !newRefreshToken.isEmpty {
            newTokens.refreshToken = newRefreshToken // Token rotation
        }
        if let expiresIn = json.expiresIn {
            newTokens.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        currentTokens = newTokens
        tokenBox.set(newTokens.accessToken)
        self.authState = .valid
        self.lastErrorMessage = nil

        let serialized = try JSONEncoder().encode(newTokens)
        if let str = String(data: serialized, encoding: .utf8) {
            try await credentialStore.setSecret(str, for: tokenRef)
        }

        return newTokens.accessToken
    }

    private struct OAuthRefreshResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}

public struct OAuthAuthStrategy: AuthStrategy {
    public let refresher: OAuthTokenRefresher
    public let requestProfile: OAuthRequestProfile?

    public init(refresher: OAuthTokenRefresher, requestProfile: OAuthRequestProfile? = nil) {
        self.refresher = refresher
        self.requestProfile = requestProfile
    }

    public func apply(to request: inout URLRequest) async throws {
        let token = try await refresher.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        requestProfile?.apply(to: &request)
    }
}

