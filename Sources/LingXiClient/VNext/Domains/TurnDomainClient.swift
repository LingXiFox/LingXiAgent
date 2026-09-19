import Foundation
import LingXiProtocol

public struct TurnDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func submitTurn(
        sessionID: SessionID,
        input: UserInput,
        executionIntent: TurnExecutionIntent = TurnExecutionIntent()
    ) async throws -> CommandReceipt<SubmitTurnResult> {
        let req = SubmitTurnRequest(sessionID: sessionID, input: input, executionIntent: executionIntent)
        return try await transport.submitTurn(envelope: CommandEnvelope(payload: req))
    }

    public func submitTurn(
        envelope: CommandEnvelope<SubmitTurnRequest>
    ) async throws -> CommandReceipt<SubmitTurnResult> {
        return try await transport.submitTurn(envelope: envelope)
    }

    public func cancelTurn(sessionID: SessionID, turnID: TurnID) async throws -> CommandReceipt<VoidResult> {
        let req = CancelTurnRequest(sessionID: sessionID, turnID: turnID)
        return try await transport.cancelTurn(envelope: CommandEnvelope(payload: req))
    }

    public func cancelTurn(
        envelope: CommandEnvelope<CancelTurnRequest>
    ) async throws -> CommandReceipt<VoidResult> {
        return try await transport.cancelTurn(envelope: envelope)
    }

    public func getTurn(sessionID: SessionID, turnID: TurnID) async throws -> TurnSnapshot {
        let req = GetTurnRequest(sessionID: sessionID, turnID: turnID)
        let resp = try await transport.getTurn(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getTurn(
        envelope: QueryEnvelope<GetTurnRequest>
    ) async throws -> ResponseEnvelope<TurnSnapshot> {
        return try await transport.getTurn(envelope: envelope)
    }

    public func listTurns(sessionID: SessionID, page: PageRequest = PageRequest()) async throws -> Page<TurnSnapshot> {
        let req = ListTurnsRequest(sessionID: sessionID, page: page)
        let resp = try await transport.listTurns(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func listTurns(
        envelope: QueryEnvelope<ListTurnsRequest>
    ) async throws -> ResponseEnvelope<Page<TurnSnapshot>> {
        return try await transport.listTurns(envelope: envelope)
    }
}
