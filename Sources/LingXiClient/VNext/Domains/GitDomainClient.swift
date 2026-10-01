import Foundation
import LingXiProtocol

/// Git RPC namespace 的客户端门面。
///
/// GUI 与 CLI 都只能通过这里动 Git：结构化参数、无 argv、身份字段必填（契约第十四、十六节）。
/// GUI 主动点击产生的写操作使用 `guiToolCallID()`，不伪装成 Agent Tool Call，也不复用 Agent 的 ID。
public struct GitDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    /// GUI 发起写操作时的调用身份。审计、cancelPending 与 mutation coordination 都靠它关联。
    public static func guiToolCallID() -> String { "gui:" + UUID().uuidString }

    // MARK: - Read

    public func status(workingDirectory: String? = nil) async throws -> GitStatusResult {
        let resp = try await transport.gitStatus(envelope: QueryEnvelope(payload: GitQueryRequest(workingDirectory: workingDirectory)))
        return resp.payload
    }

    /// 完整结构化请求：范围端点（baseReference / commitReference）与输出形态都由调用方声明。
    public func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        let resp = try await transport.gitDiff(envelope: QueryEnvelope(payload: request))
        return resp.payload
    }

    /// patch 与逐文件行数来自同一个 `git.diff`；只要统计时关掉 patch（契约第九节）。
    public func diff(
        paths: [String] = [],
        scope: GitDiffScope = .head,
        includePatch: Bool = true,
        includeFileStats: Bool = true,
        workingDirectory: String? = nil
    ) async throws -> GitDiffResult {
        try await diff(GitDiffRequest(paths: paths, scope: scope, includePatch: includePatch,
                                      includeFileStats: includeFileStats, workingDirectory: workingDirectory))
    }

    public func log(limit: Int? = nil, workingDirectory: String? = nil) async throws -> GitTextResult {
        let resp = try await transport.gitLog(envelope: QueryEnvelope(payload: GitQueryRequest(limit: limit, workingDirectory: workingDirectory)))
        return resp.payload
    }

    public func show(reference: String, workingDirectory: String? = nil) async throws -> GitTextResult {
        let resp = try await transport.gitShow(envelope: QueryEnvelope(payload: GitQueryRequest(reference: reference, workingDirectory: workingDirectory)))
        return resp.payload
    }

    public func branch(workingDirectory: String? = nil) async throws -> GitTextResult {
        let resp = try await transport.gitBranch(envelope: QueryEnvelope(payload: GitQueryRequest(workingDirectory: workingDirectory)))
        return resp.payload
    }

    // MARK: - Mutation

    /// `all == true` 对应"暂存全部"（`add -A`）；否则必须给出明确路径。
    public func add(paths: [String] = [], all: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        try await mutate(.add, GitMutationRequest(sessionID: sessionID, toolCallID: toolCallID, paths: paths, all: all, workingDirectory: workingDirectory))
    }

    /// `stagedOnly == true` 是"取消暂存"：不丢弃工作区内容，风险与 `add` 对称。
    public func restore(paths: [String], force: Bool = false, stagedOnly: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        try await mutate(.restore, GitMutationRequest(sessionID: sessionID, toolCallID: toolCallID, paths: paths, force: force, stagedOnly: stagedOnly, workingDirectory: workingDirectory))
    }

    public func checkout(reference: String, createBranch: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        try await mutate(.checkout, GitMutationRequest(sessionID: sessionID, toolCallID: toolCallID, reference: reference, createBranch: createBranch, workingDirectory: workingDirectory))
    }

    public func `switch`(branch: String, createBranch: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        try await mutate(.switch, GitMutationRequest(sessionID: sessionID, toolCallID: toolCallID, branch: branch, createBranch: createBranch, workingDirectory: workingDirectory))
    }

    public func commit(message: String, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        try await mutate(.commit, GitMutationRequest(sessionID: sessionID, toolCallID: toolCallID, message: message, workingDirectory: workingDirectory))
    }

    // MARK: - Remote Mutation / Sync（契约第二至四节）

    public func fetch(remote: String? = nil, prune: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        let req = GitRemoteRequest(sessionID: sessionID, toolCallID: toolCallID, remote: remote, prune: prune, workingDirectory: workingDirectory)
        return try await transport.gitFetch(envelope: CommandEnvelope(payload: req))
    }

    /// 只有 fast-forward 形态：分叉时返回 nonFastForward，由用户决定 merge 还是 rebase。
    public func pull(remote: String? = nil, branch: String? = nil, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        let req = GitRemoteRequest(sessionID: sessionID, toolCallID: toolCallID, remote: remote, branch: branch, workingDirectory: workingDirectory)
        return try await transport.gitPull(envelope: CommandEnvelope(payload: req))
    }

    /// 没有 upstream 时必须显式给出 remote 与 branch；Core 不猜推送目标。
    public func push(remote: String? = nil, branch: String? = nil, setUpstream: Bool = false, sessionID: SessionID? = nil, toolCallID: String = GitDomainClient.guiToolCallID(), workingDirectory: String? = nil) async throws -> CommandReceipt<GitMutationResult> {
        let req = GitRemoteRequest(sessionID: sessionID, toolCallID: toolCallID, remote: remote, branch: branch, setUpstream: setUpstream, workingDirectory: workingDirectory)
        return try await transport.gitPush(envelope: CommandEnvelope(payload: req))
    }

    private enum Action {
        case add, restore, checkout, `switch`, commit
    }

    private func mutate(_ action: Action, _ request: GitMutationRequest) async throws -> CommandReceipt<GitMutationResult> {
        switch action {
        case .add: return try await transport.gitAdd(envelope: CommandEnvelope(payload: request))
        case .restore: return try await transport.gitRestore(envelope: CommandEnvelope(payload: request))
        case .checkout: return try await transport.gitCheckout(envelope: CommandEnvelope(payload: request))
        case .switch: return try await transport.gitSwitch(envelope: CommandEnvelope(payload: request))
        case .commit: return try await transport.gitCommit(envelope: CommandEnvelope(payload: request))
        }
    }
}
