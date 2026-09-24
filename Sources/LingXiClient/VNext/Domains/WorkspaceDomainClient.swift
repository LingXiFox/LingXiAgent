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

    // MARK: - Worktree Operations (G10)

    public func createWorktree(name: String, baseRef: String? = nil) async throws -> CommandReceipt<WorkspaceWorktreeInfo> {
        let req = CreateWorktreeRequest(name: name, baseRef: baseRef)
        return try await transport.createWorktree(envelope: CommandEnvelope(payload: req))
    }

    public func listWorktrees() async throws -> [WorkspaceWorktreeInfo] {
        let resp = try await transport.listWorktrees(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func applyWorktree(worktreeID: String, commitMessage: String? = nil) async throws -> CommandReceipt<VoidResult> {
        let req = ApplyWorktreeRequest(worktreeID: worktreeID, commitMessage: commitMessage)
        return try await transport.applyWorktree(envelope: CommandEnvelope(payload: req))
    }

    public func discardWorktree(worktreeID: String, force: Bool = true) async throws -> CommandReceipt<VoidResult> {
        let req = DiscardWorktreeRequest(worktreeID: worktreeID, force: force)
        return try await transport.discardWorktree(envelope: CommandEnvelope(payload: req))
    }

    public func pruneWorktrees(force: Bool = false) async throws -> CommandReceipt<VoidResult> {
        let req = PruneWorktreesRequest(force: force)
        return try await transport.pruneWorktrees(envelope: CommandEnvelope(payload: req))
    }
}

