import Foundation
import LingXiProtocol

public struct WorkspaceDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func get() async throws -> WorkspaceSummary {
        let resp = try await transport.getWorkspace(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func set(workspaceRoot: String) async throws -> CommandReceipt<WorkspaceSummary> {
        let req = SetWorkspaceRequest(workspaceRoot: workspaceRoot)
        return try await transport.setWorkspace(envelope: CommandEnvelope(payload: req))
    }

    public func summary() async throws -> WorkspaceSummary {
        let resp = try await transport.getWorkspaceSummary(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func diff() async throws -> WorkspaceDiffSummary {
        let resp = try await transport.getWorkspaceDiffSummary(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }
}
