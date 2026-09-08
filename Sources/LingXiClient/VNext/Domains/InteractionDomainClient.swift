import Foundation
import LingXiProtocol

public struct InteractionDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func listPending(sessionID: SessionID) async throws -> [InteractionSnapshot] {
        let req = ListInteractionsRequest(sessionID: sessionID)
        let resp = try await transport.listPendingInteractions(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func resolve(sessionID: SessionID, interactionID: InteractionID, resolution: InteractionResolution) async throws -> CommandReceipt<VoidResult> {
        let req = ResolveInteractionRequest(sessionID: sessionID, interactionID: interactionID, resolution: resolution)
        return try await transport.resolveInteraction(envelope: CommandEnvelope(payload: req))
    }
}
