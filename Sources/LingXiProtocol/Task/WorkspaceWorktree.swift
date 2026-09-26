import Foundation

/// Worktree 隔离至今没有任何 Runtime 实现。契约必须明确报「不可用」，
/// 不能返回伪造的 branch 与 `/tmp/<name>` 路径让前端显示成功。
public let lingxiWorktreeUnsupportedMessage = "Worktree 管理尚未由 Runtime 实现，不能假装创建成功。"

/// 工作区 Worktree 元数据
public struct WorkspaceWorktreeInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public let branch: String
    public let path: String
    public var isActive: Bool
    public let baseCommit: String?
    public let createdAt: Date

    public init(
        id: String,
        branch: String,
        path: String,
        isActive: Bool = true,
        baseCommit: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.branch = branch
        self.path = path
        self.isActive = isActive
        self.baseCommit = baseCommit
        self.createdAt = createdAt
    }
}

/// 创建 Worktree 请求
public struct CreateWorktreeRequest: Sendable, Codable, Equatable {
    public let name: String
    public let baseRef: String?

    public init(name: String, baseRef: String? = nil) {
        self.name = name
        self.baseRef = baseRef
    }
}

/// 合并/应用 Worktree 请求
public struct ApplyWorktreeRequest: Sendable, Codable, Equatable {
    public let worktreeID: String
    public let commitMessage: String?

    public init(worktreeID: String, commitMessage: String? = nil) {
        self.worktreeID = worktreeID
        self.commitMessage = commitMessage
    }
}

/// 丢弃 Worktree 请求
public struct DiscardWorktreeRequest: Sendable, Codable, Equatable {
    public let worktreeID: String
    public let force: Bool

    public init(worktreeID: String, force: Bool = true) {
        self.worktreeID = worktreeID
        self.force = force
    }
}

/// 修剪孤立 Worktrees 请求
public struct PruneWorktreesRequest: Sendable, Codable, Equatable {
    public let force: Bool

    public init(force: Bool = false) {
        self.force = force
    }
}
