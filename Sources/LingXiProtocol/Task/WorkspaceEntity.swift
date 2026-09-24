import Foundation

/// 工作区隔离状态
public enum WorkspaceIsolationState: String, Sendable, Codable {
    case shared
    case copyOnWrite = "copy-on-write"
    case gitWorktree = "git-worktree"
}

/// 工作区类型
public enum WorkspaceKind: String, Sendable, Codable {
    case main
    case fork
    case ephemeral
}

/// 工作区实体
public struct WorkspaceEntity: Sendable, Codable, Equatable {
    public let workspaceID: WorkspaceID
    public let projectID: String
    public let kind: WorkspaceKind
    public let originWorkspaceID: WorkspaceID?
    public let rootBindingID: String?
    public let baseRevision: String?
    public let isolationState: WorkspaceIsolationState
    public let state: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        workspaceID: WorkspaceID = .generate(),
        projectID: String,
        kind: WorkspaceKind = .main,
        originWorkspaceID: WorkspaceID? = nil,
        rootBindingID: String? = nil,
        baseRevision: String? = nil,
        isolationState: WorkspaceIsolationState = .shared,
        state: String = "active",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.kind = kind
        self.originWorkspaceID = originWorkspaceID
        self.rootBindingID = rootBindingID
        self.baseRevision = baseRevision
        self.isolationState = isolationState
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
