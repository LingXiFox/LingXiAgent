import Foundation
import LingXiProtocol

/// Core 侧唯一的 Git service。
///
/// RPC handler、与 Core 同进程的 CLI 都调用这一份实现（契约第十节：CLI 允许直接调用同一个
/// GitService，不要求为了形式主义走 loopback RPC，但禁止自己 Process git / 自己拼 argv）。
/// 写操作不在这里落权限与串行化：那属于调用方的编排（CoreHost 的 RPC handler），
/// 由 `ToolMutationCoordinator` + `PermissionEngine` 负责（契约第十五、十六节）。
public struct GitService: Sendable {
    public let runner: GitRunner

    public init(workspace: WorkspaceRoot) { self.runner = GitRunner(workspace: workspace) }
    public init(runner: GitRunner) { self.runner = runner }

    // MARK: - Read

    /// `git.status`：一次 porcelain v2 调用给出分支、upstream、ahead/behind、四类计数与逐文件明细。
    /// 未跟踪目录按 `-uall` 展开，因此 files[] 与计数同口径，前端不需要再数一遍（契约第八、二十一节）。
    public func status(workingDirectory: String? = nil) async throws -> GitStatusResult {
        let directory = try runner.directory(for: workingDirectory)
        let porcelain = try await runner.execute(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all"],
            in: directory
        ).stdout
        let parsed = GitStatusParse.workingTree(porcelain)
        let mainRoot = try? await runner.mainCheckoutRoot()
        return GitStatusResult(
            branchName: parsed.branch,
            headSHA: parsed.headSHA,
            upstreamRemote: parsed.upstreamRemote,
            upstreamBranch: parsed.upstreamBranch,
            ahead: parsed.ahead,
            behind: parsed.behind,
            dirtyPathCount: parsed.dirtyPathCount,
            trackedChangeCount: parsed.trackedChangeCount,
            untrackedFileCount: parsed.untrackedFileCount,
            conflictedFileCount: parsed.conflictedFileCount,
            isDirty: parsed.isDirty,
            files: parsed.files,
            mainCheckoutRoot: mainRoot?.path
        )
    }

    /// `git.diff`：patch 与逐文件行数来自同一范围（scope），因此数字描述的正是屏幕上那份 patch。
    /// 只要统计时 `includePatch = false`；仍然是同一个 RPC，不存在 `git.numstat`（契约第九节）。
    public func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        let directory = try runner.directory(for: request.workingDirectory)
        let base = GitRequest(
            action: .diff,
            paths: request.paths,
            diffScope: request.scope,
            baseReference: request.baseReference,
            commitReference: request.commitReference,
            unifiedContextLines: request.contextLines
        )
        var executedArgv: [String] = []
        var patch: String?
        if request.includePatch {
            let patchRequest = base
            let argv = try patchRequest.argv()
            executedArgv = argv
            patch = try await runner.execute(argv, in: directory).stdout
        }
        guard request.includeFileStats else {
            return GitDiffResult(patch: patch, files: [], argv: executedArgv)
        }
        let statsRequest = GitRequest(
            action: .diff,
            paths: request.paths,
            diffScope: request.scope,
            numstat: true,
            baseReference: request.baseReference,
            commitReference: request.commitReference
        )
        let nameRequest = GitRequest(
            action: .diff,
            paths: request.paths,
            diffScope: request.scope,
            nameStatusOnly: true,
            baseReference: request.baseReference,
            commitReference: request.commitReference
        )
        let numstatArgv = try statsRequest.argv()
        let nameArgv = try nameRequest.argv()
        if executedArgv.isEmpty { executedArgv = numstatArgv }
        let numstat = GitStatusParse.numstat(try await runner.execute(numstatArgv, in: directory).stdout)
        let names = GitStatusParse.nameStatus(try await runner.execute(nameArgv, in: directory).stdout)
        var files = GitStatusParse.merge(statusFiles: [], numstat: numstat, nameStatus: names)
        if request.includeFileStats, request.scope.includesUntrackedFiles {
            files = mergingUntrackedStats(files, await untrackedFileStats(in: directory, requestedPaths: request.paths))
        }
        return GitDiffResult(patch: patch, files: files, argv: executedArgv)
    }

    /// 未跟踪文件的 file stats。
    ///
    /// 契约固定语义：文本文件 additions = 文件行数、deletions = 0、binary = false；
    /// 二进制文件 additions/deletions = nil、binary = true。行数由 Core 读文件得出 ——
    /// 前端不得自己数，也不得用 `git diff --no-index`，因此这里不起新 git 形态、不加白名单。
    ///
    /// 一律不抛：超大文件、读不到、编码无法可靠判定 → stats 为 nil，整个 `git.diff` 不失败。
    private func untrackedFileStats(in directory: URL, requestedPaths: [String]) async -> [GitFileChange] {
        let porcelain = try? await runner.execute(
            ["status", "--porcelain=v2", "--untracked-files=all"], in: directory
        ).stdout
        guard let porcelain else { return [] }
        let untracked = GitStatusParse.workingTree(porcelain).files.filter { $0.isUntracked }
        guard !untracked.isEmpty else { return [] }
        // porcelain 路径相对当前 worktree 顶层，而不是相对本次调用的工作目录。
        let toplevelString = try? await runner.execute(["rev-parse", "--show-toplevel"], in: directory).trimmedStdout
        guard let toplevelString, !toplevelString.isEmpty else { return [] }
        let toplevel = URL(fileURLWithPath: toplevelString)
        let wanted = requestedPaths.map { GitService.normalizeRelative($0) }

        return untracked.compactMap { entry -> GitFileChange? in
            var file = entry
            let relative = GitService.normalizeRelative(entry.path)
            if !wanted.isEmpty, !wanted.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") || $0.hasPrefix(relative) }) {
                return nil
            }
            let url = toplevel.appendingPathComponent(relative)
            // 只统计工作区里真实存在的文件；符号链接目标缺失等情况一律留 nil。
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > GitService.untrackedStatsByteLimit {
                return file
            }
            guard let data = FileManager.default.contents(atPath: url.path) else { return file }
            let stats = GitService.lines(ofUntrackedFile: data)
            file.additions = stats.additions
            file.deletions = stats.deletions
            file.binary = stats.binary
            return file
        }
    }

    private func mergingUntrackedStats(_ tracked: [GitFileChange], _ untracked: [GitFileChange]) -> [GitFileChange] {
        guard !untracked.isEmpty else { return tracked }
        var byPath = Dictionary(uniqueKeysWithValues: tracked.map { ($0.path, $0) })
        for file in untracked where byPath[file.path] == nil {
            byPath[file.path] = file
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    static let untrackedStatsByteLimit = 4 * 1_024 * 1_024
    /// git 自身的二进制判定也是"前 8000 字节内有无 NUL"，这里保持同一口径。
    static let binarySniffWindow = 8_000

    /// 行数 = 换行符数量 + 末尾无换行时的最后一行。空文件 0 行。
    static func lines(ofUntrackedFile data: Data) -> (additions: Int?, deletions: Int?, binary: Bool) {
        guard data.count <= untrackedStatsByteLimit else { return (nil, nil, false) }
        let bytes = [UInt8](data)
        let window = bytes.prefix(binarySniffWindow)
        if window.contains(0) { return (nil, nil, true) }
        guard String(data: data, encoding: .utf8) != nil else { return (nil, nil, false) }
        if bytes.isEmpty { return (0, 0, false) }
        var lines = 0
        var trailingContent = false
        for byte in bytes {
            if byte == 0x0A { lines += 1; trailingContent = false }
            else { trailingContent = true }
        }
        if trailingContent { lines += 1 }
        return (lines, 0, false)
    }

    private static func normalizeRelative(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value = String(value.dropFirst(2)) }
        return value
    }

    public func log(limit: Int? = nil, workingDirectory: String? = nil) async throws -> GitTextResult {
        try await text(GitRequest(action: .log, limit: limit, workingDirectory: workingDirectory))
    }

    public func show(reference: String, workingDirectory: String? = nil) async throws -> GitTextResult {
        try await text(GitRequest(action: .show, reference: reference, workingDirectory: workingDirectory))
    }

    /// 分支列表。删除分支是写操作，不走这个读入口。
    public func branch(workingDirectory: String? = nil) async throws -> GitTextResult {
        try await text(GitRequest(action: .branch, workingDirectory: workingDirectory))
    }

    private func text(_ request: GitRequest) async throws -> GitTextResult {
        let argv = try request.argv()
        let result = try await runner.execute(argv, in: try runner.directory(for: request.workingDirectory))
        return GitTextResult(text: result.stdout, argv: argv)
    }

    // MARK: - Mutation 参数补全

    /// 远程动作的默认目标补全（契约第二、三节）：
    /// fetch / pull 缺 remote 时用当前分支 upstream 的 remote，没有则 origin；
    /// pull 缺 branch 时用当前分支；push 不在此补全 —— 没有 upstream 就不猜（契约第四节）。
    public func resolved(_ request: GitRequest) async throws -> GitRequest {
        var request = request
        switch request.action {
        case .fetch:
            if request.remote == nil { request.remote = try await defaultRemote() }
        case .pull:
            if request.remote == nil { request.remote = try await defaultRemote() }
            if request.branch == nil { request.branch = try await currentBranch() }
        default:
            break
        }
        return request
    }

    private func defaultRemote() async throws -> String {
        if let upstream = try? await runner.execute(["rev-parse", "--abbrev-ref", "@{upstream}"],
                                                   in: runner.directory(for: nil)).trimmedStdout,
           let separator = upstream.lastIndex(of: "/") {
            let remote = String(upstream[..<separator])
            if !remote.isEmpty { return remote }
        }
        return "origin"
    }

    private func currentBranch() async throws -> String? {
        let branch = try? await runner.execute(["rev-parse", "--abbrev-ref", "HEAD"],
                                              in: runner.directory(for: nil)).trimmedStdout
        guard let branch, !branch.isEmpty, branch != "HEAD" else { return nil }
        return branch
    }

    /// push 的前置校验：没有 upstream 又没有显式给出 remote 与 branch，就失败，不猜目标（契约第四节）。
    public func validatePush(_ request: GitRequest) async throws {
        guard request.action == .push else { return }
        if request.setUpstream {
            guard request.remote != nil, request.branch != nil else {
                throw CoreError(code: .toolArgumentInvalid, message: "建立 upstream 必须同时明确 remote 与 branch")
            }
            // `-u` 只能记录到已配置的 remote 名下：git 不接受把 upstream 指向一个裸 URL。
            // Core 不代替用户新增 remote，因此这里直接拒绝，而不是悄悄改仓库配置。
            let name = request.remote!.trimmingCharacters(in: .whitespacesAndNewlines)
            let remotes = try await runner.execute(["remote"], in: try runner.directory(for: request.workingDirectory)).stdout
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard remotes.contains(name) else {
                throw CoreError(
                    code: .toolArgumentInvalid,
                    message: "setUpstream 需要已配置的 remote 名：\(name) 不在 remote 列表里（Core 不代为添加 remote）"
                )
            }
            return
        }
        if request.remote != nil, request.branch != nil { return }
        let upstream = try? await runner.execute(["rev-parse", "--abbrev-ref", "@{upstream}"],
                                                 in: try runner.directory(for: request.workingDirectory)).trimmedStdout
        guard let upstream, !upstream.isEmpty, upstream.contains("/") else {
            throw CoreError(
                code: .toolArgumentInvalid,
                message: "当前分支没有 upstream：push 需要显式 remote 与 branch，或 setUpstream = true（Core 不猜测推送目标）"
            )
        }
    }

    // MARK: - Mutation 执行

    /// 结构化写操作的实际执行。调用方必须已经拿到权限并完成串行化；
    /// 这个函数存在只为让 CLI / RPC / Tool 共用同一份 argv 构造与进程执行。
    @discardableResult
    public func execute(_ request: GitRequest) async throws -> GitRunResult {
        let argv = try request.argv()
        return try await runner.execute(argv, in: try runner.directory(for: request.workingDirectory))
    }
}
