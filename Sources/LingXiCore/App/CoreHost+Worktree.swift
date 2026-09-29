import Foundation
import LingXiPlatform
import LingXiProtocol

// Isolated execution environments backed by `git worktree`.
//
// A managed worktree lives under `<dataRoot>/worktrees/<repo>-<hash>/<name>`
// on branch `lingxi/<name>`, so it never shows up in the repository's own
// status. Applying squashes the branch into the main worktree as uncommitted
// changes — the user reviews and commits them there — then removes the
// worktree. Nothing is merged or committed on the main branch behind their back.

extension CoreHost {
    static let worktreeBranchPrefix = "lingxi/"

    public func createWorktree(envelope: CommandEnvelope<CreateWorktreeRequest>) async throws -> CommandReceipt<WorkspaceWorktreeInfo> {
        let name = envelope.payload.name.trimmingCharacters(in: .whitespaces)
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw CoreError(code: .toolArgumentInvalid, message: "Worktree 名称只能包含字母、数字、点、下划线和连字符")
        }
        let repo = try await worktreeRepository()
        let path = repo.managedRoot.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Worktree \(name) 已存在")
        }
        try FileManager.default.createDirectory(at: repo.managedRoot, withIntermediateDirectories: true)
        let base = envelope.payload.baseRef?.trimmingCharacters(in: .whitespaces)
        try await git(["worktree", "add", "-b", Self.worktreeBranchPrefix + name, path.path,
                       (base?.isEmpty == false ? base! : "HEAD")], in: repo.mainRoot)
        guard let info = try await managedWorktrees(repo).first(where: { $0.id == name }) else {
            throw CoreError(code: .commandFailed, message: "Worktree 已创建但无法读取其状态")
        }
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: info)
    }

    public func listWorktrees(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[WorkspaceWorktreeInfo]> {
        // Not a git repository: there is nothing to isolate, which is a real empty list.
        guard let repo = try? await worktreeRepository() else {
            return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision, payload: [])
        }
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                payload: try await managedWorktrees(repo))
    }

    public func applyWorktree(envelope: CommandEnvelope<ApplyWorktreeRequest>) async throws -> CommandReceipt<VoidResult> {
        let repo = try await worktreeRepository()
        let worktree = try await requireManagedWorktree(envelope.payload.worktreeID, repo)
        let path = URL(fileURLWithPath: worktree.path)

        // Uncommitted work in the worktree becomes one commit on its branch.
        if !(try await git(["status", "--porcelain"], in: path)).isEmpty {
            try await git(["add", "-A"], in: path)
            let message = envelope.payload.commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            try await git(identityArguments(in: path) + ["commit", "-m",
                          message?.isEmpty == false ? message! : "LingXi worktree \(worktree.id)"], in: path)
        }
        // Squash into the main worktree as staged changes, for the user to commit.
        try await git(["merge", "--squash", worktree.branch], in: repo.mainRoot)
        try await git(["worktree", "remove", "--force", worktree.path], in: repo.mainRoot)
        try await git(["branch", "-D", worktree.branch], in: repo.mainRoot)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    public func discardWorktree(envelope: CommandEnvelope<DiscardWorktreeRequest>) async throws -> CommandReceipt<VoidResult> {
        let repo = try await worktreeRepository()
        let worktree = try await requireManagedWorktree(envelope.payload.worktreeID, repo)
        try await git(["worktree", "remove"] + (envelope.payload.force ? ["--force"] : []) + [worktree.path],
                      in: repo.mainRoot)
        try await git(["branch", "-D", worktree.branch], in: repo.mainRoot)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    public func pruneWorktrees(envelope: CommandEnvelope<PruneWorktreesRequest>) async throws -> CommandReceipt<VoidResult> {
        let repo = try await worktreeRepository()
        try await git(["worktree", "prune"] + (envelope.payload.force ? ["--expire", "now"] : []), in: repo.mainRoot)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    // MARK: - Repository

    struct WorktreeRepository {
        /// The repository's main worktree (the user's checkout).
        let mainRoot: URL
        /// Where LingXi keeps this repository's managed worktrees.
        let managedRoot: URL
    }

    private func worktreeRepository() async throws -> WorktreeRepository {
        let listing = try await git(["worktree", "list", "--porcelain"], in: workspaceURL)
        guard let first = Self.parseWorktreeListing(listing).first else {
            throw CoreError(code: .toolArgumentInvalid, message: "当前工作区不是 Git 仓库，无法使用独立 Worktree")
        }
        let mainRoot = URL(fileURLWithPath: first.path).standardizedFileURL
        let dataRoot = try requireConfigurationStore().dataRoot
        let folder = "\(mainRoot.lastPathComponent)-\(Self.stableHash(mainRoot.path))"
        return WorktreeRepository(mainRoot: mainRoot,
                                  managedRoot: dataRoot.appendingPathComponent("worktrees").appendingPathComponent(folder))
    }

    private func managedWorktrees(_ repo: WorktreeRepository) async throws -> [WorkspaceWorktreeInfo] {
        let listing = try await git(["worktree", "list", "--porcelain"], in: repo.mainRoot)
        let mainHead = try? await git(["rev-parse", "HEAD"], in: repo.mainRoot)
        // git reports real paths (/private/var/…); compare against the resolved root.
        let prefix = repo.managedRoot.resolvingSymlinksInPath().path + "/"
        var result: [WorkspaceWorktreeInfo] = []
        for entry in Self.parseWorktreeListing(listing)
        where URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path.hasPrefix(prefix)
            || entry.path.hasPrefix(repo.managedRoot.path + "/") {
            let url = URL(fileURLWithPath: entry.path)
            let branch = entry.branch ?? entry.head ?? ""
            var base: String?
            if let mainHead, !branch.isEmpty {
                base = try? await git(["merge-base", mainHead, branch], in: repo.mainRoot)
            }
            let created = (try? FileManager.default.attributesOfItem(atPath: entry.path)[.creationDate] as? Date) ?? nil
            result.append(WorkspaceWorktreeInfo(
                id: url.lastPathComponent,
                branch: branch,
                path: entry.path,
                isActive: !entry.prunable && FileManager.default.fileExists(atPath: entry.path),
                baseCommit: base,
                createdAt: created ?? .now))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func requireManagedWorktree(_ id: String, _ repo: WorktreeRepository) async throws -> WorkspaceWorktreeInfo {
        guard let worktree = try await managedWorktrees(repo).first(where: { $0.id == id }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Worktree \(id) 不存在")
        }
        guard worktree.branch.hasPrefix(Self.worktreeBranchPrefix) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Worktree \(id) 不在 LingXi 管理的分支上")
        }
        return worktree
    }

    struct WorktreeListingEntry {
        var path: String
        var head: String?
        var branch: String?
        var prunable = false
    }

    /// Parses `git worktree list --porcelain`: blank-line separated records.
    static func parseWorktreeListing(_ text: String) -> [WorktreeListingEntry] {
        var entries: [WorktreeListingEntry] = []
        var current: WorktreeListingEntry?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeListingEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line.hasPrefix("prunable") {
                current?.prunable = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// FNV-1a, stable across launches and platforms (unlike `hashValue`).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(String(hash, radix: 16).prefix(8))
    }

    /// A commit needs an identity; fall back to a local one only when the
    /// user has none configured, never overriding theirs.
    private func identityArguments(in directory: URL) async throws -> [String] {
        let email = (try? await git(["config", "user.email"], in: directory)) ?? ""
        return email.isEmpty ? ["-c", "user.name=LingXi", "-c", "user.email=lingxi@localhost"] : []
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        guard let executable = LingXiPlatform.process.resolveExecutable(
            named: "git", customSearchPaths: ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]) else {
            throw CoreError(code: .toolNotFound, message: "找不到 git")
        }
        var environment = EnvironmentSanitizer.sanitized()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await runToolProcess(
            invocation: ToolProcessInvocation(executable: executable, arguments: arguments),
            cwd: directory, environment: environment, timeoutMilliseconds: 60_000)
        guard result.exitCode == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.exitCode)"
            throw CoreError(code: .commandFailed, message: "git \(arguments.first ?? "") 失败：\(detail)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
