import Foundation
import LingXiProtocol

public struct ContextDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func getState(sessionID: SessionID) async throws -> ContextStateSnapshot {
        let req = GetContextStateRequest(sessionID: sessionID)
        let resp = try await transport.getContextState(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getPolicy() async throws -> ContextCachePolicySnapshot {
        let resp = try await transport.getContextPolicy(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func compact(sessionID: SessionID) async throws -> CommandReceipt<VoidResult> {
        let req = CompactContextRequest(sessionID: sessionID)
        return try await transport.compactContext(envelope: CommandEnvelope(payload: req))
    }

    public func search(sessionID: SessionID, query: String, limit: Int = 10) async throws -> [ContextSearchResultItem] {
        let req = SearchContextRequest(sessionID: sessionID, query: query, limit: limit)
        let resp = try await transport.searchContext(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getEntry(sessionID: SessionID, uri: String) async throws -> ContextEntryItem {
        let req = GetContextEntryRequest(sessionID: sessionID, uri: uri)
        let resp = try await transport.getContextEntry(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func updatePolicy(
        sessionID: SessionID? = nil,
        maxActiveTokens: Int? = nil,
        autoCompactionEnabled: Bool? = nil
    ) async throws -> CommandReceipt<ContextCachePolicySnapshot> {
        let req = UpdateContextPolicyRequest(sessionID: sessionID, maxActiveTokens: maxActiveTokens, autoCompactionEnabled: autoCompactionEnabled)
        return try await transport.updateContextPolicy(envelope: CommandEnvelope(payload: req))
    }
}
