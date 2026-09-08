import Foundation
import LingXiProtocol

public struct RunDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func cancelRun(sessionID: SessionID, runID: RunID, reason: String? = nil) async throws -> CommandReceipt<VoidResult> {
        let req = CancelRunRequest(sessionID: sessionID, runID: runID, reason: reason)
        return try await transport.cancelRun(envelope: CommandEnvelope(payload: req))
    }

    public func resumeRun(sessionID: SessionID, runID: RunID) async throws -> CommandReceipt<RunSnapshot> {
        let req = ResumeRunRequest(sessionID: sessionID, runID: runID)
        return try await transport.resumeRun(envelope: CommandEnvelope(payload: req))
    }

    public func getRun(sessionID: SessionID, runID: RunID) async throws -> RunSnapshot {
        let req = GetRunRequest(sessionID: sessionID, runID: runID)
        let resp = try await transport.getRun(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func listRuns(sessionID: SessionID, page: PageRequest = PageRequest()) async throws -> Page<RunSnapshot> {
        let req = ListRunsRequest(sessionID: sessionID, page: page)
        let resp = try await transport.listRuns(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getAgentTree(sessionID: SessionID) async throws -> AgentTreeNode {
        let req = GetAgentTreeRequest(sessionID: sessionID)
        let resp = try await transport.getAgentTree(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }
}
