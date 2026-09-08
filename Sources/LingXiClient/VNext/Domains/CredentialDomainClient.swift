import Foundation
import LingXiProtocol

public struct CredentialDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list() async throws -> [CredentialRef] {
        let resp = try await transport.listCredentials(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func store(secret: String) async throws -> CommandReceipt<CredentialResult> {
        let req = StoreCredentialRequest(secret: secret)
        return try await transport.storeCredential(envelope: CommandEnvelope(payload: req))
    }

    public func delete(reference: CredentialRef) async throws -> CommandReceipt<VoidResult> {
        let req = DeleteCredentialRequest(reference: reference)
        return try await transport.deleteCredential(envelope: CommandEnvelope(payload: req))
    }

    public func status(reference: CredentialRef) async throws -> CredentialStatusInfo {
        let req = GetCredentialStatusRequest(reference: reference)
        let resp = try await transport.getCredentialStatus(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func test(reference: CredentialRef) async throws -> CommandReceipt<TestCredentialResult> {
        let req = TestCredentialRequest(reference: reference)
        return try await transport.testCredential(envelope: CommandEnvelope(payload: req))
    }
}
