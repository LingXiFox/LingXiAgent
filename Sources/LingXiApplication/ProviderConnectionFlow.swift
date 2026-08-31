import Foundation
import LingXiClient
import LingXiProtocol

public enum ProviderConnectionCredentialKind: String, Sendable, Equatable {
    case apiKey, subscriptionKey, oauth, workloadIdentity
}

public enum ProviderConnectionState: Sendable, Equatable {
    case idle
    case selectingProduct
    case requestingCredential(ProviderConnectionCredentialKind)
    case requestingAccountFields([String])
    case requestingLocalEndpoint
    case authorizingOAuth
    case validating
    case creatingAccount
    case connected(ProviderAccountInfo)
    case failed
    case cancelled
}

public enum ProviderConnectionError: Error, Sendable, Equatable {
    case flowNotFound
    case productNotConnectable
    case invalidState
    case unsupportedCredentialFlow
}

public actor ProviderConnectionFlow {
    public let id: String
    public let product: ProviderProductSummary
    private let client: LingXiClient
    private var credentialRef: CredentialRef?
    private var accountFields: [String: String] = [:]
    private var localEndpoint: String?
    private var stateValue: ProviderConnectionState = .idle

    public init(id: String = UUID().uuidString, product: ProviderProductSummary, client: LingXiClient) {
        self.id = id
        self.product = product
        self.client = client
    }

    public var state: ProviderConnectionState { stateValue }

    @discardableResult
    public func begin() throws -> ProviderConnectionState {
        guard product.connectable, product.verificationStatus == .verified else {
            stateValue = .failed
            throw ProviderConnectionError.productNotConnectable
        }
        if product.requiresCredential {
            stateValue = .requestingCredential(product.type == .subscription ? .subscriptionKey : .apiKey)
        } else if product.requiresLocalEndpoint {
            stateValue = .requestingLocalEndpoint
        } else if !product.requiredAccountFields.isEmpty {
            stateValue = .requestingAccountFields(product.requiredAccountFields)
        } else {
            stateValue = .validating
        }
        return stateValue
    }

    @discardableResult
    public func submitCredential(_ secret: String) async throws -> ProviderConnectionState {
        guard case .requestingCredential = stateValue, !secret.isEmpty else { throw ProviderConnectionError.invalidState }
        do {
            credentialRef = try await client.storeProviderCredential(secret)
            if !product.requiredAccountFields.isEmpty {
                stateValue = .requestingAccountFields(product.requiredAccountFields)
            } else if product.requiresLocalEndpoint {
                stateValue = .requestingLocalEndpoint
            } else {
                stateValue = .validating
                try await createAccount()
            }
            return stateValue
        } catch {
            stateValue = .failed
            throw error
        }
    }

    @discardableResult
    public func submitAccountFields(_ fields: [String: String]) async throws -> ProviderConnectionState {
        guard case .requestingAccountFields = stateValue else { throw ProviderConnectionError.invalidState }
        accountFields = fields
        if product.requiresLocalEndpoint {
            stateValue = .requestingLocalEndpoint
        } else {
            stateValue = .validating
            try await createAccount()
        }
        return stateValue
    }

    @discardableResult
    public func submitLocalEndpoint(_ endpoint: String) async throws -> ProviderConnectionState {
        guard case .requestingLocalEndpoint = stateValue, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderConnectionError.invalidState }
        localEndpoint = endpoint
        stateValue = .validating
        try await createAccount()
        return stateValue
    }

    public func continueOAuth(_ result: OAuthAuthorizationResult) throws {
        stateValue = .failed
        throw ProviderConnectionError.unsupportedCredentialFlow
    }

    public func cancel() async {
        if case .connected = stateValue { return }
        if let credentialRef {
            try? await client.deleteProviderCredential(credentialRef)
            self.credentialRef = nil
        }
        stateValue = .cancelled
    }

    private func createAccount() async throws {
        stateValue = .creatingAccount
        let accountType = product.accountTypes.first(where: { $0 == .apiKey || $0 == .subscription || $0 == .localInstance || $0 == .anonymousLocal }) ?? product.accountTypes[0]
        let authentication: ProviderStoredAuthentication
        switch product.requestAuthentication {
        case nil, .some(.none), .some(.providerNative): authentication = .none
        case .some(.bearerToken), .some(.oauthAccessToken), .some(.workloadIdentityToken), .some(.gatewayToken): authentication = .bearer
        case .some(.apiKeyHeader), .some(.customHeaderSet): authentication = .header
        }
        do {
            let account = try await client.createProviderAccount(ProviderAccountCreateRequest(id: "provider-account-\(UUID().uuidString)", productID: product.id, displayName: product.displayName, accountType: accountType, credentialRef: credentialRef, endpoint: localEndpoint, authentication: authentication, headerName: product.requestAuthenticationHeaderName, fields: accountFields))
            stateValue = .connected(account)
        } catch {
            if let credentialRef { try? await client.deleteProviderCredential(credentialRef); self.credentialRef = nil }
            stateValue = .failed
            throw error
        }
    }
}

public actor ProviderConnectionService {
    private let client: LingXiClient
    private var flows: [String: ProviderConnectionFlow] = [:]

    public init(client: LingXiClient) { self.client = client }

    public func listConnectableProducts() async throws -> [ProviderProductSummary] {
        try await client.listProviderProducts().filter(\.connectable)
    }

    public func beginConnection(productID: String) async throws -> String {
        guard let product = try await listConnectableProducts().first(where: { $0.id == productID }) else { throw ProviderConnectionError.productNotConnectable }
        let flow = ProviderConnectionFlow(product: product, client: client)
        flows[flow.id] = flow
        _ = try await flow.begin()
        return flow.id
    }

    public func state(flowID: String) async throws -> ProviderConnectionState {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        return await flow.state
    }

    public func submitCredential(flowID: String, credential: String) async throws -> ProviderConnectionState {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        return try await flow.submitCredential(credential)
    }

    public func submitAccountFields(flowID: String, fields: [String: String]) async throws -> ProviderConnectionState {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        return try await flow.submitAccountFields(fields)
    }

    public func submitLocalEndpoint(flowID: String, endpoint: String) async throws -> ProviderConnectionState {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        return try await flow.submitLocalEndpoint(endpoint)
    }

    public func continueOAuth(flowID: String, callback: OAuthAuthorizationResult) async throws -> ProviderConnectionState {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        try await flow.continueOAuth(callback)
        return await flow.state
    }

    public func cancelConnection(flowID: String) async throws {
        guard let flow = flows[flowID] else { throw ProviderConnectionError.flowNotFound }
        await flow.cancel()
        flows.removeValue(forKey: flowID)
    }

    public func disconnect(accountID: String, deleteUnusedCredential: Bool = false) async throws -> ProviderDisconnectResult {
        try await client.disconnectProviderAccount(accountID, deleteUnusedCredential: deleteUnusedCredential)
    }

    public func accounts() async throws -> [ProviderAccountInfo] { try await client.listProviderAccounts() }
}
