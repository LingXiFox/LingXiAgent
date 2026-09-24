import Foundation
import LingXiProtocol

public struct AgentPresetDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list() async throws -> [AgentPresetInfo] {
        let resp = try await transport.listAgentPresets(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func listRuns(sessionID: SessionID, runID: RunID) async throws -> [AgentRunDetail] {
        let req = GetRunRequest(sessionID: sessionID, runID: runID)
        let resp = try await transport.listAgentRuns(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

}
