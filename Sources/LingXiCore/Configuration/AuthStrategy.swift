import Foundation
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

public actor OAuthTokenRefresher {
    public let metadata: OAuthCredentialMetadata
    public private(set) var currentTokens: OAuthTokens
    private let credentialStore: CredentialStore
    private let tokenRef: CredentialRef
    private var refreshTask: Task<String, Error>?
    public private(set) var refreshCallCount: Int = 0
    private let client: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?

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
    }

    public func validAccessToken() async throws -> String {
        // Return active token if not expiring within 30 seconds
        if let expiresAt = currentTokens.expiresAt, expiresAt.timeIntervalSinceNow > 30 {
            return currentTokens.accessToken
        }
        guard currentTokens.refreshToken != nil else {
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
        guard let refreshToken = currentTokens.refreshToken else {
            throw CoreError(code: .provider, message: "No refresh token available for OAuth refresh")
        }
        guard let url = URL(string: metadata.tokenEndpoint) else {
            throw CoreError(code: .provider, message: "Invalid token endpoint: \(metadata.tokenEndpoint)")
        }

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
        if let client {
            (data, response) = try await client(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CoreError(code: .provider, message: "OAuth token refresh failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
        var newTokens = currentTokens
        newTokens.accessToken = json.accessToken
        if let newRefreshToken = json.refreshToken {
            newTokens.refreshToken = newRefreshToken // Token rotation
        }
        if let expiresIn = json.expiresIn {
            newTokens.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        currentTokens = newTokens

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

