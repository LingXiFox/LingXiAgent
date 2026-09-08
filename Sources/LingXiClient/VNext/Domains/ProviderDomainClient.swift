import Foundation
import LingXiProtocol

public struct ProviderDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list() async throws -> [ProviderAccountInfo] {
        let resp = try await transport.listProviders(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func status() async throws -> ProviderStatus {
        let resp = try await transport.getProviderStatus(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func get(providerID: String) async throws -> ProviderAccountInfo {
        let req = GetProviderRequest(providerID: providerID)
        let resp = try await transport.getProvider(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func test(providerID: String) async throws -> CommandReceipt<TestProviderResult> {
        let req = TestProviderRequest(providerID: providerID)
        return try await transport.testProvider(envelope: CommandEnvelope(payload: req))
    }

    public func configure(
        providerID: String,
        accountID: String,
        displayName: String? = nil,
        endpointURL: String? = nil,
        credentialReference: CredentialRef? = nil
    ) async throws -> CommandReceipt<ProviderAccountInfo> {
        let req = ConfigureProviderRequest(
            providerID: providerID,
            accountID: accountID,
            displayName: displayName,
            endpointURL: endpointURL,
            credentialReference: credentialReference
        )
        return try await transport.configureProvider(envelope: CommandEnvelope(payload: req))
    }

    public func remove(accountID: String) async throws -> CommandReceipt<VoidResult> {
        let req = RemoveProviderRequest(accountID: accountID)
        return try await transport.removeProvider(envelope: CommandEnvelope(payload: req))
    }

    public func reload() async throws -> CommandReceipt<VoidResult> {
        try await transport.reloadProviders(envelope: CommandEnvelope(payload: VoidResult()))
    }
}
