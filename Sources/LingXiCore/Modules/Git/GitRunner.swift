import Foundation
import LingXiPlatform
import LingXiProtocol

/// Git 操作的权威动作模型（契约第十五节的最终表面）。
///
/// 契约第十三节：Git 不建立第二套执行引擎。`GitAction` + 本文件的 argv 构造与风险分类
/// 是 Tool、RPC、GUI、TUI、CLI 共用的唯一路径；任何一边都不许自己拼 argv。
public enum GitAction: String, Codable, Sendable, CaseIterable {
    case status, diff, log, show, branch
    case add, restore, checkout, `switch`, commit
    case fetch, pull, push

    public var isMutation: Bool {
        switch self {
        case .status, .diff, .log, .show, .branch: return false
        default: return true
        }
    }
}

/// 结构化参数 → 现有 argv 构造。禁止调用方注入执行目录或仓库定位参数。
public struct GitRequest: Sendable, Equatable {
    public let action: GitAction
    public var paths: [String] = []
    public var reference: String?
    public var branch: String?
    public var message: String?
    public var limit: Int?
    /// 新分支创建（`branch -d` / `switch -c` / `commit --amend` 之类的显式开关，仍由 argv 构造决定，不接受裸 flag）。
    public var createBranch: Bool = false
    public var force: Bool = false
    /// `restore --staged`：只撤销暂存区，不动工作区。语义与丢弃改动不同，风险也不同。
    public var stagedOnly: Bool = false
    /// `add -A`：暂存整个工作区。空 paths 不等于"全部"，避免误把无参数读成全量操作。
    public var all: Bool = false
    /// 远程同步目标。缺省语义由各 action 自己定义：fetch/pull 退回当前 upstream（再退回 origin），
    /// push 不退让 —— 没有 upstream 时必须显式给出 remote 与 branch（契约第四节）。
    public var remote: String?
    /// `fetch --prune`：只由结构化开关控制，不接受裸 flag。
    public var prune: Bool = false
    /// `push -u`：建立/更新 upstream。第一版 push 只有安全形态，没有 force 与 refspec。
    public var setUpstream: Bool = false
    /// diff 的比较范围（契约第九节：worktree / staged，另加 head 覆盖"全部改动"这一常见展示口径）。
    public var diffScope: GitDiffScope = .worktree
    /// `--numstat` 形式：同一份结构化参数决定输出形态，不另开 `git.numstat` 接口。
    public var numstat: Bool = false
    /// `--name-status` 形式：与 numstat 同为 `git.diff` 的一种输出投影。
    public var nameStatusOnly: Bool = false
    /// 比较基点：`diff <base>...HEAD`。与 scope 互斥，由 argv 构造决定形态。
    public var baseReference: String?
    /// 单个提交：`diff <commit>^!`。
    public var commitReference: String?
    public var unifiedContextLines: Int?
    /// 工作区内相对工作目录；只允许工作区内部路径。
    public var workingDirectory: String?

    public init(action: GitAction, paths: [String] = [], reference: String? = nil, branch: String? = nil, message: String? = nil, limit: Int? = nil, createBranch: Bool = false, force: Bool = false, stagedOnly: Bool = false, all: Bool = false, remote: String? = nil, prune: Bool = false, setUpstream: Bool = false, diffScope: GitDiffScope = .worktree, numstat: Bool = false, nameStatusOnly: Bool = false, baseReference: String? = nil, commitReference: String? = nil, unifiedContextLines: Int? = nil, workingDirectory: String? = nil) {
        self.action = action
        self.paths = paths
        self.reference = reference
        self.branch = branch
        self.message = message
        self.limit = limit
        self.createBranch = createBranch
        self.force = force
        self.stagedOnly = stagedOnly
        self.all = all
        self.remote = remote
        self.prune = prune
        self.setUpstream = setUpstream
        self.diffScope = diffScope
        self.numstat = numstat
        self.nameStatusOnly = nameStatusOnly
        self.baseReference = baseReference
        self.commitReference = commitReference
        self.unifiedContextLines = unifiedContextLines
        self.workingDirectory = workingDirectory
    }

    /// 契约第十三节禁止的注入面：仓库定位与执行目录覆盖。
    /// `-c <key>=<value>` 不在禁止之列 —— Core 自己用它补 commit identity（不改变操作哪个仓库）。
    static let forbiddenArguments = ["-C", "--git-dir", "--work-tree", "--namespace"]

    public static func validateInjectionFree(_ values: [String]) throws {
        for value in values {
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if forbiddenArguments.contains(token) || forbiddenArguments.contains(where: { token.hasPrefix($0 + "=") }) {
                throw CoreError(code: .toolArgumentInvalid, message: "git 参数不得包含仓库定位或执行目录覆盖：\(token)")
            }
        }
    }

    /// 契约第十四节：RPC 只接受结构化参数，由 handler 转成现有 `GitAction` argv。
    /// 与 `GitTool` 共用同一份构造，不存在第二个 argv parser。
    public func argv() throws -> [String] {
        switch action {
        // `-uall`：未跟踪目录必须展开成逐文件计数，不能让 `new-directory/` 只算一条（契约第二十一节）。
        // 计数走 `GitRunner.status()` 的 porcelain v2（契约第二十二节），这里保持 Agent 可读的短格式。
        case .status: return ["status", "--short", "--untracked-files=all"]
        case .diff:
            // 范围端点是结构化字段：`<base>...HEAD` 与 `<commit>^!` 由这里拼，不接受裸 flag。
            let range: [String]
            if let commitReference {
                range = [try Self.revision(commitReference, "commitReference 不是合法 revision") + "^!"]
            } else if let baseReference {
                range = [try Self.revision(baseReference, "baseReference 不是合法 revision") + "...HEAD"]
            } else {
                range = diffScope.argvPrefix
            }
            var argv = ["diff", "--no-ext-diff", "--no-textconv"] + range
            if nameStatusOnly { return argv + ["--name-status"] + Self.pathspec(paths) }
            if numstat { argv.append("--numstat") }
            else { argv.append("-U" + String(max(0, unifiedContextLines ?? 3))) }
            return argv + Self.pathspec(paths)
        case .log: return ["log", "--oneline", "-n", String(min(max(limit ?? 10, 1), 100))]
        case .show: return ["show", try required(reference ?? "HEAD", "show 需要 reference")]
        case .branch:
            if let branch {
                // `branch -d/-D <name>`：删除分支是变更，列表不是。
                return force ? ["branch", "-D", branch] : ["branch", "-d", branch]
            }
            return ["branch", "--list"]
        case .add:
            if all { return ["add", "-A"] }
            let targets = try Self.require(paths, "add 需要明确路径，或 all = true")
            return ["add", "--"] + targets
        case .restore:
            let targets = try Self.require(paths, "restore 需要 paths")
            if stagedOnly { return ["restore", "--staged", "--"] + targets }
            if force { return ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + targets }
            return ["restore", "--"] + targets
        case .checkout:
            let target = try required(reference, "checkout 需要 reference")
            return createBranch ? ["checkout", "-b", target] : ["checkout", "--", target]
        case .switch:
            let target = try required(branch, "switch 需要 branch")
            return createBranch ? ["switch", "-c", target] : ["switch", target]
        case .commit:
            let body = try required(message, "commit 需要 message")
            return ["commit", "-m", body]
        case .fetch:
            var argv = ["fetch"]
            if let remote { argv.append(remote) }
            if prune { argv.append("--prune") }
            return argv
        case .pull:
            // 第一版只允许 fast-forward：不 merge、不 rebase、不 auto stash、不 force（契约第三节）。
            var argv = ["pull", "--ff-only"]
            if let remote { argv.append(remote) }
            if let branch { argv.append(branch) }
            return argv
        case .push:
            // 禁止 --force / --force-with-lease / 删除远程分支 / 任意 refspec / tag 全量推送。
            if setUpstream {
                let target = try required(remote, "push 建立 upstream 需要明确 remote")
                let branchName = try required(branch, "push 建立 upstream 需要明确 branch")
                return ["push", "-u", target, branchName]
            }
            var argv = ["push"]
            if let remote { argv.append(remote) }
            if let branch { argv.append(branch) }
            return argv
        }
    }

    private static func pathspec(_ paths: [String]) -> [String] {
        paths.isEmpty ? [] : ["--"] + paths
    }

    /// revision 必须是普通引用名：以 "-" 开头就是 flag，不接受。
    private static func revision(_ value: String, _ hint: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.contains(where: { $0 == "\0" || $0 == "\n" }) else {
            throw CoreError(code: .toolArgumentInvalid, message: hint)
        }
        return trimmed
    }

    private static func require(_ paths: [String], _ hint: String) throws -> [String] {
        guard !paths.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: hint) }
        return paths
    }

    private func required(_ value: String?, _ hint: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError(code: .toolArgumentInvalid, message: hint)
        }
        return value
    }
}

extension GitDiffScope {
    /// 范围 → git 原生参数。放在 Core 侧，协议层不携带 argv 知识。
    var argvPrefix: [String] {
        switch self {
        case .worktree: return []
        case .staged: return ["--staged"]
        case .head: return ["HEAD"]
        }
    }
}

/// 风险等级。权限引擎与 mutation coordinator 以此为前提，不允许各入口自行判断。
public enum GitRisk: String, Sendable, Equatable, Codable {
    case read, write, destructive, remoteWrite
}

/// 一个 Git 操作的完整风险判定：等级 + 需要的能力集合 + 是否需要网络。
/// 契约第十六节的最终风险模型是这里的唯一来源。
public struct GitOperationRisk: Sendable, Equatable {
    public let level: GitRisk
    public let capabilities: Set<ToolCapabilityKind>
    public let requiresNetwork: Bool

    public init(level: GitRisk, capabilities: Set<ToolCapabilityKind>, requiresNetwork: Bool) {
        self.level = level
        self.capabilities = capabilities
        self.requiresNetwork = requiresNetwork
    }
}

public enum GitRiskPolicy {
    /// 契约第十六节：
    /// status/diff/log/show/branch → repositoryRead
    /// fetch → repositoryWrite + network
    /// add/commit → repositoryWrite
    /// restore/checkout/switch → repositoryWrite + destructive
    /// pull → repositoryWrite + network + destructive
    /// push → repositoryRemoteWrite + network（本地已获写权限不得自动继承成远程写）
    public static func classify(for request: GitRequest) -> GitOperationRisk {
        switch request.action {
        case .status, .diff, .log, .show:
            return GitOperationRisk(level: .read, capabilities: [.repositoryRead], requiresNetwork: false)
        case .branch:
            // 列分支是读；删分支是破坏性本地写。
            guard request.branch != nil else {
                return GitOperationRisk(level: .read, capabilities: [.repositoryRead], requiresNetwork: false)
            }
            return GitOperationRisk(level: .destructive,
                                    capabilities: [.repositoryWrite, .destructive],
                                    requiresNetwork: false)
        case .add, .commit:
            return GitOperationRisk(level: .write, capabilities: [.repositoryWrite], requiresNetwork: false)
        case .restore where request.stagedOnly:
            // 取消暂存不丢内容，也不动 worktree 文件：风险与 add 对称。
            return GitOperationRisk(level: .write, capabilities: [.repositoryWrite], requiresNetwork: false)
        case .restore, .checkout, .switch:
            return GitOperationRisk(level: .destructive,
                                    capabilities: [.repositoryWrite, .destructive],
                                    requiresNetwork: false)
        case .fetch:
            return GitOperationRisk(level: .write,
                                    capabilities: [.repositoryWrite, .networkAccess],
                                    requiresNetwork: true)
        case .pull:
            return GitOperationRisk(level: .destructive,
                                    capabilities: [.repositoryWrite, .networkAccess, .destructive],
                                    requiresNetwork: true)
        case .push:
            return GitOperationRisk(level: .remoteWrite,
                                    capabilities: [.repositoryRemoteWrite, .networkAccess],
                                    requiresNetwork: true)
        }
    }

    public static func risk(for request: GitRequest) -> GitRisk { classify(for: request).level }

    /// 兼容旧调用点：只要能力集合。
    public static func capabilities(for request: GitRequest) -> Set<ToolCapabilityKind> {
        classify(for: request).capabilities
    }
}

/// Git 工作区变化的统一解析结果（契约第二十、二十一、二十二、八节）。
///
/// 一次 `git status --porcelain=v2 --branch --untracked-files=all` 就给出分支、upstream、
/// ahead/behind、四类计数与逐文件明细 —— 前端与 CLI 因此不需要再跑任何 git。
public struct GitWorkingTreeStatus: Sendable, Equatable {
    public let branch: String?
    public let headSHA: String?
    public let upstreamRemote: String?
    public let upstreamBranch: String?
    public let ahead: Int?
    public let behind: Int?
    /// 存在工作区变化的**唯一文件路径数**：同一路径 staged + unstaged 只算 1。
    public let dirtyPathCount: Int
    /// tracked 变更路径数（modified / added / deleted / renamed）。
    public let trackedChangeCount: Int
    /// `-uall` 展开后的未跟踪**文件**数，不是目录数。
    public let untrackedFileCount: Int
    public let conflictedFileCount: Int
    public let files: [GitFileChange]
    public var isDirty: Bool { dirtyPathCount > 0 }

    public init(
        branch: String? = nil,
        headSHA: String? = nil,
        upstreamRemote: String? = nil,
        upstreamBranch: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        dirtyPathCount: Int = 0,
        trackedChangeCount: Int = 0,
        untrackedFileCount: Int = 0,
        conflictedFileCount: Int = 0,
        files: [GitFileChange] = []
    ) {
        self.branch = branch
        self.headSHA = headSHA
        self.upstreamRemote = upstreamRemote
        self.upstreamBranch = upstreamBranch
        self.ahead = ahead
        self.behind = behind
        self.dirtyPathCount = dirtyPathCount
        self.trackedChangeCount = trackedChangeCount
        self.untrackedFileCount = untrackedFileCount
        self.conflictedFileCount = conflictedFileCount
        self.files = files
    }
}

public enum GitStatusParse {
    /// 去掉记录类型 + 固定字段后的整体即路径。
    private static func path(from fields: [String], skipping: Int) -> String {
        fields.dropFirst(skipping).joined(separator: " ")
    }

    /// `git status --porcelain=v2 --branch --untracked-files=all`。
    ///
    /// 所有计数都基于同一份解析后的 records，避免"行数为脏路径数"这种近似：
    /// porcelain v2 对每个路径只给一条 `1`/`2`/`u` 记录，索引位与工作区位分别在同一条里，
    /// 因此同一路径 staged + unstaged 天然只计一次。
    public static func workingTree(_ text: String) -> GitWorkingTreeStatus {
        var branch: String?
        var headSHA: String?
        var upstreamRemote: String?
        var upstreamBranch: String?
        var ahead: Int?
        var behind: Int?
        var tracked: Set<String> = []
        var untracked: Set<String> = []
        var conflicted: Set<String> = []
        var files: [GitFileChange] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("# branch.head ") {
                let name = line.dropFirst("# branch.head ".count).trimmingCharacters(in: .whitespaces)
                branch = name == "(detached)" ? nil : name
                continue
            }
            if line.hasPrefix("# branch.oid ") {
                let oid = line.dropFirst("# branch.oid ".count).trimmingCharacters(in: .whitespaces)
                headSHA = oid.hasPrefix("(") ? nil : oid
                continue
            }
            if line.hasPrefix("# branch.upstream ") {
                // "origin/main" → remote=origin, branch=main（remote 名本身可以含斜杠，按最后一个 / 切）
                let upstream = line.dropFirst("# branch.upstream ".count).trimmingCharacters(in: .whitespaces)
                if let separator = upstream.lastIndex(of: "/") {
                    upstreamRemote = String(upstream[..<separator])
                    upstreamBranch = String(upstream[upstream.index(after: separator)...])
                } else {
                    upstreamBranch = upstream
                }
                continue
            }
            if line.hasPrefix("# branch.ab ") {
                // "+<ahead> -<behind>"
                let parts = line.dropFirst("# branch.ab ".count).split(whereSeparator: \.isWhitespace).map(String.init)
                if parts.count == 2 {
                    ahead = Int(parts[0].dropFirst())
                    behind = Int(parts[1].dropFirst())
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let kind = fields.first else { continue }
            // 路径本身可以含空格，所以不能取"最后一个 token"：按记录类型跳过固定前缀字段，
            // 剩下的整体就是路径。git 只对控制字符/非 ASCII 做 C 引用，空格是原样输出的。
            switch kind {
            // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
            case "1" where fields.count >= 9:
                let target = Self.path(from: fields, skipping: 8)
                let codes = Self.statusCodes(fields[1])
                tracked.insert(target)
                files.append(GitFileChange(path: target, indexStatus: codes.index, worktreeStatus: codes.worktree,
                                           status: codes.index != " " ? codes.index : codes.worktree))
            // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
            case "u" where fields.count >= 11:
                let target = Self.path(from: fields, skipping: 10)
                let codes = Self.statusCodes(fields[1])
                conflicted.insert(target)
                files.append(GitFileChange(path: target, indexStatus: codes.index, worktreeStatus: codes.worktree,
                                           isConflicted: true, status: "U"))
            case "2" where fields.count >= 9:
                // <X><score><sep><path><sep><origPath>：重命名同时改动两个路径。
                let remainder = Self.path(from: fields, skipping: 8)
                let parts = remainder.split(whereSeparator: { $0 == "\t" || $0 == "\u{0}" || $0 == "\u{1}" }).map(String.init)
                let codes = Self.statusCodes(fields[1])
                let target = parts.first ?? ""
                let origin = parts.count > 1 ? parts[1] : nil
                if !target.isEmpty {
                    tracked.insert(target)
                    if let origin { tracked.insert(origin) }
                    files.append(GitFileChange(path: target, oldPath: origin, indexStatus: codes.index,
                                               worktreeStatus: codes.worktree, status: codes.index))
                }
            case "?" where fields.count >= 2:
                let target = Self.path(from: fields, skipping: 1)
                untracked.insert(target)
                files.append(GitFileChange(path: target, indexStatus: "?", worktreeStatus: "?",
                                           isUntracked: true, status: "?"))
            default:
                // `!` 是被忽略路径：契约第二十节明确不计入 dirtyPathCount。
                continue
            }
        }
        let dirty = tracked.union(untracked).union(conflicted)
        return GitWorkingTreeStatus(
            branch: branch,
            headSHA: headSHA,
            upstreamRemote: upstreamRemote,
            upstreamBranch: upstreamBranch,
            ahead: ahead,
            behind: behind,
            dirtyPathCount: dirty.count,
            trackedChangeCount: tracked.count,
            untrackedFileCount: untracked.count,
            conflictedFileCount: conflicted.count,
            files: files.sorted { $0.path < $1.path }
        )
    }

    private static func statusCodes(_ xy: String) -> (index: String, worktree: String) {
        let characters = Array(xy)
        return (String(characters.first ?? " "), String(characters.count > 1 ? characters[1] : " "))
    }

    /// `git diff --numstat`：每行 `<added>\t<deleted>\t<path>`，二进制两侧都是 "-"。
    public static func numstat(_ text: String) -> [String: (additions: Int?, deletions: Int?, binary: Bool)] {
        var result: [String: (additions: Int?, deletions: Int?, binary: Bool)] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3 else { continue }
            let path = Self.unquoted(columns[2])
            if columns[0] == "-" || columns[1] == "-" {
                result[path] = (nil, nil, true)
            } else {
                result[path] = (Int(columns[0]), Int(columns[1]), false)
            }
        }
        return result
    }

    /// `git diff --name-status`：`M<TAB>path`，重命名为 `R100<TAB>old<TAB>new`。
    public static func nameStatus(_ text: String) -> [(status: String, path: String, oldPath: String?)] {
        var result: [(status: String, path: String, oldPath: String?)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 2 else { continue }
            // 状态字母可能带相似度后缀，例如 R100 / C75。
            let status = columns[0].prefix(1).uppercased()
            if columns.count >= 3 {
                result.append((status, Self.unquoted(columns[2]), Self.unquoted(columns[1])))
            } else {
                result.append((status, Self.unquoted(columns[1]), nil))
            }
        }
        return result
    }

    /// status 与 diff 的行数合并成一份 files[]：以路径为键，diff 侧补 status 与行数。
    public static func merge(statusFiles: [GitFileChange], numstat: [String: (additions: Int?, deletions: Int?, binary: Bool)], nameStatus: [(status: String, path: String, oldPath: String?)]) -> [GitFileChange] {
        var byPath: [String: GitFileChange] = [:]
        for file in statusFiles { byPath[file.path] = file }
        for entry in nameStatus {
            var file = byPath[entry.path] ?? GitFileChange(
                path: entry.path,
                oldPath: entry.oldPath,
                indexStatus: entry.status,
                worktreeStatus: entry.status
            )
            if file.oldPath == nil { file.oldPath = entry.oldPath }
            file.status = entry.status
            if let stats = numstat[entry.path] {
                file.additions = stats.additions
                file.deletions = stats.deletions
                file.binary = stats.binary
            }
            byPath[entry.path] = file
        }
        for (path, stats) in numstat where byPath[path] == nil {
            var file = GitFileChange(path: path, indexStatus: "M", worktreeStatus: "M", status: "M")
            file.additions = stats.additions
            file.deletions = stats.deletions
            file.binary = stats.binary
            byPath[path] = file
        }
        // 未跟踪文件不出现在 diff 里，但行数对 UI 同样有意义：留 nil 而不是猜 0。
        return byPath.values.sorted { $0.path < $1.path }
    }

    /// git 对含特殊字符的路径做 C 引用（`"..."`）。这里只处理最常见的包裹，
    /// 不做完整八进制转义解码：解码错误会让路径与 files[] 对不上，宁可原样保留。
    private static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }
}

/// 唯一的 git 进程执行入口。
///
/// `GitTool`（Agent 侧）、`GitRPC`（RPC 侧）与 Worktree 管理都走这里；契约第十三节要求复用
/// argv 构造 / 风险分类 / mutation coordinator / permission engine，本文件是它们共同的落点。
public struct GitRunner: Sendable {
    public static let gitSearchPaths = [
        "/Library/Developer/CommandLineTools/usr/bin",
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ]

    public let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }

    /// 解析工作区内的执行目录。`workingDirectory` 只允许是工作区内部路径。
    public func directory(for workingDirectory: String?, profile: ExecutionProfile = .workspace) throws -> URL {
        let url = try workspace.resolve(workingDirectory ?? ".", profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError(code: .toolExecutionFailed, message: "git 工作目录不存在或不是目录: \(url.path)")
        }
        return url
    }

    public func resolveExecutable() throws -> String {
        guard let executable = LingXiPlatform.process.resolveExecutable(named: "git", customSearchPaths: Self.gitSearchPaths) else {
            throw CoreError(code: .gitError, message: "未找到可执行的 git 命令")
        }
        return executable
    }

    /// 结构化请求 → argv → 进程执行。返回 stdout；非零退出按 `gitError` 抛出，带上 git 自己的诊断。
    @discardableResult
    public func run(_ request: GitRequest) async throws -> GitRunResult {
        try GitRequest.validateInjectionFree([request.reference, request.branch, request.message, request.workingDirectory]
            .compactMap { $0 } + request.paths)
        let argv = try request.argv()
        return try await execute(argv, in: try directory(for: request.workingDirectory))
    }

    /// 供 worktree 等 plumbing 复用同一执行器；参数由调用方给出，但同样禁止仓库定位注入。
    @discardableResult
    public func execute(_ argv: [String], in directory: URL, timeoutMilliseconds: Int = 60_000) async throws -> GitRunResult {
        try GitRequest.validateInjectionFree(argv)
        let executable = try resolveExecutable()
        var environment = EnvironmentSanitizer.sanitized()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await runToolProcess(
            invocation: ToolProcessInvocation(executable: executable, arguments: argv),
            cwd: directory,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds,
            lifecycleTrace: ToolExecutionContext.lifecycleTrace
        )
        let output = GitRunResult(argv: argv, stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        guard result.exitCode == 0 else {
            throw CoreError(code: .gitError, message: "git \(argv.first ?? "") 失败：\(output.diagnostic)")
        }
        return output
    }

    public func status(in directory: URL? = nil) async throws -> GitWorkingTreeStatus {
        GitStatusParse.workingTree(try await execute(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all"],
            in: directory ?? workspace.url
        ).stdout)
    }

    /// 契约第十九节：main checkout root 只能用 `--git-common-dir` 推导。
    ///
    /// 不能用 `--show-toplevel`：在 linked worktree 里它返回的是**当前** worktree 的根，
    /// 于是 worktree 会被当成 main checkout，管理目录就放错了地方。
    public func mainCheckoutRoot() async throws -> URL {
        let commonDirectory = try await execute(["rev-parse", "--git-common-dir"], in: workspace.url).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonDirectory.isEmpty else {
            throw CoreError(code: .gitError, message: "无法解析 git common directory")
        }
        let commonURL = commonDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirectory)
            : workspace.url.appendingPathComponent(commonDirectory)
        let standardized = commonURL.standardizedFileURL
        // 主 worktree：common dir 就是 `<root>/.git`，去掉末段即得根目录。
        if standardized.lastPathComponent == ".git" {
            return standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        }
        // linked worktree：common dir 在 main checkout 的 `.git` 内部（例如
        // `<main>/.git`，或自定义布局下的 modules/x/.git）；以 git 自己的 `worktree list`
        // 首条为准 —— 它始终按 main worktree 排在第一。
        let listing = try await execute(["worktree", "list", "--porcelain"], in: workspace.url).stdout
        for line in listing.split(separator: "\n") where line.hasPrefix("worktree ") {
            let path = String(line.dropFirst("worktree ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        }
        throw CoreError(code: .gitError, message: "无法从 git common directory 推导 main checkout root")
    }
}

public struct GitRunResult: Sendable, Equatable {
    public let argv: [String]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(argv: [String], stdout: String, stderr: String, exitCode: Int32) {
        self.argv = argv
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var trimmedStdout: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var diagnostic: String {
        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return detail ?? "exit \(exitCode)"
    }
}
