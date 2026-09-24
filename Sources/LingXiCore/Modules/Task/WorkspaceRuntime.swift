import Foundation
import LingXiProtocol

/// 工作区运行时 (WorkspaceRuntime)
public actor WorkspaceRuntime {
    private var workspaces: [WorkspaceID: WorkspaceEntity] = [:]

    public init() {}

    public func register(_ workspace: WorkspaceEntity) {
        workspaces[workspace.workspaceID] = workspace
    }

    public func get(_ id: WorkspaceID) -> WorkspaceEntity? {
        workspaces[id]
    }

    public func list(projectID: String? = nil) -> [WorkspaceEntity] {
        workspaces.values.filter { entity in
            if let projectID = projectID, entity.projectID != projectID { return false }
            return true
        }
    }

    public func fork(
        from originID: WorkspaceID,
        isolationState: WorkspaceIsolationState = .copyOnWrite
    ) throws -> WorkspaceEntity {
        guard let origin = workspaces[originID] else {
            throw CoreError(code: .workspaceNotFound, message: "Origin workspace not found: \(originID.rawValue)")
        }

        let forked = WorkspaceEntity(
            workspaceID: .generate(),
            projectID: origin.projectID,
            kind: .fork,
            originWorkspaceID: origin.workspaceID,
            rootBindingID: origin.rootBindingID,
            baseRevision: origin.baseRevision,
            isolationState: isolationState,
            state: "active"
        )
        workspaces[forked.workspaceID] = forked
        return forked
    }
}
