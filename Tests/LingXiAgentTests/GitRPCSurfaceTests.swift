import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

/// 契约第十三至二十二节：Git RPC 面的一致性、注入防线、写操作串行化与身份、
/// dirtyPathCount 口径、`-uall` 展开、main checkout root 推导。
struct GitRPCSurfaceTests {
    private static func run(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PortableFixture.git())
        process.arguments = arguments
        process.currentDirectoryURL = root
        var stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) 失败")
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-git-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.run(["init", "-b", "main"], in: root)
        try Self.run(["config", "user.email", "test@example.com"], in: root)
        try Self.run(["config", "user.name", "LingXi Test"], in: root)
        try "seed\n".write(to: root.appending(path: "tracked.txt"), atomically: false, encoding: .utf8)
        try Self.run(["add", "tracked.txt"], in: root)
        try Self.run(["commit", "-m", "seed"], in: root)
        return root
    }

    private static func host(over root: URL) async throws -> (CoreHost, LingXiClientVNext) {
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        let client = try await LingXiClientVNext(transport: InProcessTransport(service: host))
        return (host, client)
    }

    // MARK: - 第十七节：声明一致性

    /// RPC 存在、feature 已广播、transport 已实现、server 已分派 —— 四者必须同时成立。
    @Test("Every git RPC method is declared, dispatched, forwarded and advertised together")
    func gitNamespaceIsConsistent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        let protocolSource = try source("Sources/LingXiProtocol/ProtocolService.swift")
        let serverSource = try source("Sources/LingXiCore/App/VNextStdioCoreServer.swift")
        let stdioSource = try source("Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift")
        let inProcessSource = try source("Sources/LingXiClient/VNext/Transport/InProcessTransport.swift")
        let featureSource = try source("Sources/LingXiProtocol/ProtocolVersion.swift")

        let methods: [(name: String, request: String)] = [
            ("git.status", "GitQueryRequest"), ("git.diff", "GitQueryRequest"), ("git.log", "GitQueryRequest"),
            ("git.show", "GitQueryRequest"), ("git.branch", "GitQueryRequest"),
            ("git.add", "GitMutationRequest"), ("git.restore", "GitMutationRequest"), ("git.checkout", "GitMutationRequest"),
            ("git.switch", "GitMutationRequest"), ("git.commit", "GitMutationRequest"),
            ("git.fetch", "GitRemoteRequest"), ("git.pull", "GitRemoteRequest"), ("git.push", "GitRemoteRequest"),
        ]
        let camel: [String: String] = [
            "git.status": "gitStatus", "git.diff": "gitDiff", "git.log": "gitLog", "git.show": "gitShow",
            "git.branch": "gitBranch", "git.add": "gitAdd", "git.restore": "gitRestore",
            "git.checkout": "gitCheckout", "git.switch": "gitSwitch", "git.commit": "gitCommit",
            "git.fetch": "gitFetch", "git.pull": "gitPull", "git.push": "gitPush",
        ]
        for (method, request) in methods {
            let handler = camel[method]!
            #expect(protocolSource.contains("func \(handler)(envelope:"), "\(method) 必须在协议里声明")
            let dispatchNeedle = "case \"" + method + "\""
            #expect(serverSource.contains(dispatchNeedle), "\(method) 必须由 stdio server 分派")
            let wireNeedle = "\"" + method + "\""
            #expect(stdioSource.contains(wireNeedle), "\(method) 必须由 stdio transport 真实发送，不能靠默认实现")
            #expect(inProcessSource.contains("service.\(handler)(envelope:"), "\(method) 必须由 InProcessTransport 转发给 Core")
            #expect(protocolSource.contains(request), "\(request) 必须存在")
        }

        // feature 声明 + Core 真实广播。广播值必须由 CoreHost 自己写出来：§12 之后
        // RuntimeCapabilities 不再有 `knownFeatures` 默认参数，"构造一个默认对象看看有什么"
        // 已经不再是"这个 Runtime 支持什么"的证据。
        #expect(featureSource.contains("case gitRPC = \"git.rpc\""))
        #expect(ProtocolFeature.knownFeatures.contains(.gitRPC))
        let advertised = try Self.coreHostAdvertisedFeatures()
        #expect(advertised.contains(".gitRPC"), "git RPC 已接线，CoreHost 必须广播 .gitRPC")
        #expect(advertised.contains(".gitRemoteSync"), "远程 git 已接线，CoreHost 必须广播 .gitRemoteSync")
    }

    /// The literal feature list CoreHost passes to `RuntimeCapabilities`.
    static func coreHostAdvertisedFeatures() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LingXiCore/App/CoreHost.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "supportedFeatures:"),
              let open = source[start.lowerBound...].firstIndex(of: "["),
              let close = source[open...].firstIndex(of: "]") else {
            Issue.record("CoreHost 未显式写出 supportedFeatures: [...] —— 广播不允许来自默认值")
            return ""
        }
        return String(source[open...close])
    }

    /// 契约第十八节：Git 写不允许有 transport 默认实现 —— 有默认实现就等于允许某条 transport 静默绕过。
    @Test("The git RPC surface has no protocol default implementations")
    func gitMethodsAreNotDefaultImplemented() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("Sources/LingXiProtocol/ProtocolService.swift"), encoding: .utf8)
        let lines = service.split(separator: "\n").map(String.init)
        var inDefaultBlock = false
        let gitResolveNeedle = "named: " + #"\""# + "git" + #"\""#
        let gitPathNeedle = #"\"/usr/bin/git\""#
        var offenders: [String] = []
        for line in lines {
            if line.contains("public extension LingXiProtocolService") || line.contains("extension LingXiProtocolService") { inDefaultBlock = true }
            if inDefaultBlock, line.contains("func git") { offenders.append(line.trimmingCharacters(in: .whitespaces)) }
            if inDefaultBlock, line == "}" { inDefaultBlock = false }
        }
        #expect(offenders.isEmpty, "Git RPC 不得有默认实现：\(offenders)")
    }

    // MARK: - 第十六节：身份

    @Test("GUI-origin mutations carry a gui: identity instead of an Agent tool call ID")
    func guiIdentityFormat() {
        let id = GitDomainClient.guiToolCallID()
        #expect(id.hasPrefix("gui:"))
        #expect(id != GitDomainClient.guiToolCallID(), "每次点击必须是独立身份，不能复用")
    }

    @Test("A git write without identity is rejected before touching the repository")
    func mutationRequiresIdentity() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        try "untracked\n".write(to: root.appending(path: "new.txt"), atomically: false, encoding: .utf8)
        await #expect(throws: CoreError.self) {
            _ = try await client.git.add(paths: ["new.txt"], toolCallID: "   ")
        }
        // 被拒绝的写没有动 index。
        let status = try await client.git.status()
        #expect(status.untrackedFileCount == 1)
    }

    // MARK: - 第十三节：注入防线

    @Test("RPC and tool paths both refuse repository-location arguments")
    func rejectsRepositoryLocationInjection() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = GitRunner(workspace: try WorkspaceRoot(path: root.path))
        // argv 由结构化参数生成，所以注入只可能来自 paths；这里必须由执行层挡住。
        await #expect(throws: CoreError.self) {
            _ = try await runner.run(GitRequest(action: .diff, paths: ["--git-dir", "/tmp/elsewhere/.git"]))
        }
        await #expect(throws: CoreError.self) {
            _ = try await runner.execute(["-C", root.path, "status"], in: root)
        }
        await #expect(throws: CoreError.self) {
            _ = try await runner.execute(["--work-tree=/tmp"], in: root)
        }
        let ok = try await runner.execute(["status", "--short"], in: root)
        #expect(ok.exitCode == 0)
    }

    // MARK: - 第二十、二十一、二十二节：计数口径

    @Test("dirtyPathCount dedups staged+unstaged and expands untracked directories")
    func dirtyPathCountSemantics() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        // 同一个路径既有 staged 又有 unstaged 变化：只能算 1。
        try "staged\n".write(to: root.appending(path: "tracked.txt"), atomically: false, encoding: .utf8)
        try Self.run(["add", "tracked.txt"], in: root)
        try "staged-then-more\n".write(to: root.appending(path: "tracked.txt"), atomically: false, encoding: .utf8)

        // 未跟踪目录必须展开成逐文件计数，而不是整个目录算 1。
        let nested = root.appending(path: "new-directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["a.swift", "b.swift", "c.swift"] {
            try "x\n".write(to: nested.appending(path: name), atomically: false, encoding: .utf8)
        }

        let status = try await client.git.status()
        #expect(status.untrackedFileCount == 3, "-uall 下目录内的每个文件都要单独计数")
        #expect(status.trackedChangeCount == 1, "同一路径 staged + unstaged 只算一条 tracked 变更")
        #expect(status.dirtyPathCount == 4, "dirtyPathCount = 唯一路径数：tracked 1 + untracked 3")
        #expect(status.conflictedFileCount == 0)
        #expect(status.isDirty)

        // 兼容周期内 changedFileCount 与 dirtyPathCount 同值（GUI 只读 dirtyPathCount）。
        let summary = await host.getWorkspaceSummary()
        #expect(summary.changedFileCount == status.dirtyPathCount)
        #expect(summary.dirtyPathCount == status.dirtyPathCount)
        #expect(summary.untrackedFileCount == 3)
        #expect(summary.trackedChangeCount == 1)
        #expect(summary.conflictedFileCount == 0)
        #expect(summary.gitBranch == "main")
    }

    @Test("Ignored paths never enter the dirty count")
    func ignoredPathsStayOutOfCounts() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        try "build/\n".write(to: root.appending(path: ".gitignore"), atomically: false, encoding: .utf8)
        let build = root.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "artifact\n".write(to: build.appending(path: "out.txt"), atomically: false, encoding: .utf8)
        try Self.run(["add", ".gitignore"], in: root)

        let status = try await client.git.status()
        // .gitignore 是唯一的未跟踪→已跟踪变化；build/out.txt 被忽略，不计入。
        #expect(status.untrackedFileCount == 0, "ignored 路径不得出现在未跟踪计数里")
        #expect(status.trackedChangeCount == 1)
        #expect(status.dirtyPathCount == 1)
    }

    // MARK: - 第十五节：写操作统一走 mutation coordinator

    @Test("Git writes go through the shared mutation coordinator and return its revision")
    func writesFlowThroughCoordinator() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        try "work\n".write(to: root.appending(path: "work.txt"), atomically: false, encoding: .utf8)
        let added = try #require((try await client.git.add(paths: ["work.txt"], toolCallID: "call-add-1")).result)
        #expect(added.action == "add")
        #expect(added.risk == "write")
        #expect(added.mutationRevision > 0, "写操作必须留下 coordinator 修订号")

        let committed = try #require((try await client.git.commit(message: "add work", toolCallID: "call-commit-1")).result)
        #expect(committed.action == "commit")
        #expect(committed.mutationRevision >= added.mutationRevision)

        // 真实副作用：工作区回到干净状态，且 git log 多了一条。
        let after = try await client.git.status()
        #expect(!after.isDirty)
        let log = try await client.git.log(limit: 5)
        #expect(log.text.contains("add work"))
        #expect(log.argv == ["log", "--oneline", "-n", "5"], "argv 由结构化参数生成，不接受裸参数")
    }

    @Test("Read RPCs return the same shape across five methods")
    func readSurfaceWorks() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        try "changed\n".write(to: root.appending(path: "tracked.txt"), atomically: false, encoding: .utf8)
        let diff = try await client.git.diff()
        #expect(diff.patch?.contains("changed") == true)
        #expect(diff.files.contains { $0.path == "tracked.txt" && ($0.additions ?? 0) >= 1 })

        let show = try await client.git.show(reference: "HEAD")
        #expect(show.text.contains("seed"))

        let branch = try await client.git.branch()
        #expect(branch.text.contains("main"))

        let log = try await client.git.log(limit: 1)
        #expect(log.text.contains("seed"))

        let status = try await client.git.status()
        #expect(status.dirtyPathCount == 1)
    }

    // MARK: - 第十九节：main checkout root

    @Test("mainCheckoutRoot resolves the main checkout from a linked worktree")
    func mainCheckoutRootFromLinkedWorktree() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = FileManager.default.temporaryDirectory.appending(path: "lx-git-linked-\(UUID().uuidString)")
        try Self.run(["worktree", "add", linked.path, "-b", "linked-branch"], in: root)
        defer {
            _ = try? Self.run(["worktree", "remove", "--force", linked.path], in: root)
            try? FileManager.default.removeItem(at: root)
        }

        let runner = GitRunner(workspace: try WorkspaceRoot(path: linked.path))
        let main = try await runner.mainCheckoutRoot()
        let expectedMain = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
            .standardizedFileURL
        #expect(main.standardizedFileURL.path == expectedMain.path,
                "linked worktree 里必须解出 main checkout，而不是当前 worktree")
        #expect(main.standardizedFileURL.path != URL(fileURLWithPath: linked.path).resolvingSymlinksInPath().standardizedFileURL.path)

        // 当前 worktree 的 toplevel 确实与 main 不同，证明这条测试有牙齿。
        let toplevel = try await runner.execute(["rev-parse", "--show-toplevel"], in: linked).trimmedStdout
        #expect(URL(fileURLWithPath: toplevel).resolvingSymlinksInPath().path != main.standardizedFileURL.path)
    }

    /// 契约第十一、十二节：生产代码里唯一允许启动 git 的位置是 Core 的 Git executor。
    /// 白名单已经清零 —— 这条门禁现在只允许 GitRunner 一个文件，任何新增站点都必须先改契约。
    @Test("Only the Core Git executor may spawn git")
    func gitSpawnSitesStayOnTheExecutor() throws {
        let allowed: Set<String> = ["Sources/LingXiCore/Modules/Git/GitRunner.swift"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let quote = "\""
        let resolveNeedle = "named: " + quote + "git" + quote
        let pathNeedle = quote + "/usr/bin/git" + quote
        var offenders: [String] = []
        for directory in ["Sources", "Apps"] {
            guard let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard text.contains(resolveNeedle) || text.contains(pathNeedle) else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if !allowed.contains(relative) { offenders.append(relative) }
            }
        }
        #expect(offenders.isEmpty,
                "git 进程只能由 GitRunner 启动；前端 / CLI / TUI 一律经 Git RPC 或 GitService：\(offenders)")
    }

    /// 契约第十二节：Apps / Client / TUI / CLI 这些前端层不得出现 git 进程调用。
    @Test("Frontend layers contain no git process invocation")
    func frontendsCarryNoGitInvocation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let layers = ["Apps", "Sources/LingXiClient", "Sources/LingXiTUI", "Sources/LingXiTUIComponents",
                      "Sources/LingXiApplication", "Sources/LingXiWebUI"]
        let markers = ["Process()", "NSTask", "/usr/bin/git", "named: \"git\""]
        var offenders: [String] = []
        for layer in layers {
            guard let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(layer),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                // 只有 git 相关标记才算违规；前端合法的进程管理（terminal、sidecar）不在此列。
                if markers.contains(where: { text.contains($0) }) && (text.contains("/usr/bin/git") || text.contains("named: \"git\"")) {
                    offenders.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
        }
        #expect(offenders.isEmpty, "前端层不得直接执行 git：\(offenders)")
    }

    /// GUI 不得再自己执行 Git 写操作，也不再从文本里数脏文件（契约第十五、二十节）。
    @Test("The macOS front end performs no Git work locally")
    func frontEndDoesNotMutateGitLocally() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pane = try String(
            contentsOf: root.appendingPathComponent("Apps/macOS/FrontendKit/Components/WarmToolPane.swift"),
            encoding: .utf8
        )
        #expect(!pane.contains("Process()"), "Git 面板不得再启动任何进程")
        // 面板里的每一次 git 读写都是 client.git.* —— 写操作走 `$0.git.*`（client 由 mutate 注入）。
        for call in ["client.git.status()", "client.git.log(", "client.git.diff(",
                     "$0.git.add(", "$0.git.restore(", "$0.git.commit(",
                     "$0.git.fetch(", "$0.git.pull(", "$0.git.push("] {
            #expect(pane.contains(call), "面板应经 \(call) 走 RPC")
        }
        #expect(pane.contains("dirtyPathCount"), "徽标只认 dirtyPathCount（契约第二十节）")
        #expect(pane.contains("git.files"), "文件列表来自 git.status 的 files[]，不再解析 --short 文本")
    }

    // MARK: - 第十六节：最终风险模型

    @Test("Each action maps to the frozen capability set")
    func riskModelMatchesTheFrozenTable() {
        func capabilities(_ action: GitAction, _ mutate: (inout GitRequest) -> Void = { _ in }) -> Set<ToolCapabilityKind> {
            var request = GitRequest(action: action)
            mutate(&request)
            return GitRiskPolicy.capabilities(for: request)
        }
        #expect(capabilities(.status) == [.repositoryRead])
        #expect(capabilities(.diff) == [.repositoryRead])
        #expect(capabilities(.log) == [.repositoryRead])
        #expect(capabilities(.show) == [.repositoryRead])
        #expect(capabilities(.branch) == [.repositoryRead])
        #expect(capabilities(.branch) != [.repositoryWrite, .destructive])
        // 分支删除是破坏性本地写：同一个 action 由参数分档。
        #expect(GitRiskPolicy.classify(for: { var r = GitRequest(action: .branch); r.branch = "old"; return r }()).capabilities
                .contains(.destructive))
        #expect(capabilities(.add) == [.repositoryWrite])
        #expect(capabilities(.commit) == [.repositoryWrite])
        #expect(capabilities(.restore) == [.repositoryWrite, .destructive])
        #expect(capabilities(.checkout) == [.repositoryWrite, .destructive])
        #expect(capabilities(.switch) == [.repositoryWrite, .destructive])
        // 取消暂存不丢内容：与 add 对称，不带 destructive。
        #expect(capabilities(.restore) { $0.stagedOnly = true } == [.repositoryWrite])
        // fetch 会写远端引用与 FETCH_HEAD，因此不是纯只读。
        #expect(capabilities(.fetch) == [.repositoryWrite, .networkAccess])
        #expect(capabilities(.pull) == [.repositoryWrite, .networkAccess, .destructive])
        // push 改的是外部仓库：需要独立的远程写能力，本地写权限不自动继承。
        #expect(capabilities(.push) == [.repositoryRemoteWrite, .networkAccess])
        #expect(!capabilities(.push).contains(.repositoryWrite))
        #expect(GitRiskPolicy.classify(for: GitRequest(action: .push)).requiresNetwork)
        #expect(!GitRiskPolicy.classify(for: GitRequest(action: .status)).requiresNetwork)
    }

    /// 结构化字段必须真的落到权威动作模型上：漏掉一个字段，RPC 就会静默改变语义。
    @Test("Every structured mutation field reaches the authoritative request")
    func mutationRequestMapsEveryField() {
        let request = GitMutationRequest(
            sessionID: SessionID("s1"),
            toolCallID: "call-1",
            paths: ["a.txt"],
            reference: "HEAD~1",
            branch: "feature",
            message: "msg",
            remote: "origin",
            prune: true,
            setUpstream: true,
            createBranch: true,
            force: true,
            stagedOnly: true,
            all: true,
            workingDirectory: "sub"
        )
        let mapped = request.gitRequest(action: .push)
        #expect(mapped.paths == ["a.txt"])
        #expect(mapped.reference == "HEAD~1")
        #expect(mapped.branch == "feature")
        #expect(mapped.message == "msg")
        #expect(mapped.remote == "origin")
        #expect(mapped.prune)
        #expect(mapped.setUpstream)
        #expect(mapped.createBranch)
        #expect(mapped.force)
        #expect(mapped.stagedOnly)
        #expect(mapped.all)
        #expect(mapped.workingDirectory == "sub")
    }

    @Test("argv builders accept only the frozen structured forms")
    func remoteArgvIsStructured() throws {
        var fetch = GitRequest(action: .fetch, remote: "origin", prune: true)
        #expect(try fetch.argv() == ["fetch", "origin", "--prune"])
        var pull = GitRequest(action: .pull, branch: "main", remote: "origin")
        // 只允许 fast-forward：不 merge、不 rebase、不 auto stash、不 force。
        #expect(try pull.argv() == ["pull", "--ff-only", "origin", "main"])
        var push = GitRequest(action: .push)
        #expect(try push.argv() == ["push"])
        push.remote = "origin"; push.branch = "main"; push.setUpstream = true
        #expect(try push.argv() == ["push", "-u", "origin", "main"])
        // force / refspec / 镜像 / tag 全量都不在结构里，也无法从参数拼出来。
        for forbidden in ["--force", "--force-with-lease", "--mirror", "--tags", "+refs/"] {
            var rogue = GitRequest(action: .push, remote: forbidden)
            #expect(throws: Never.self) { try rogue.argv() }
            rogue = GitRequest(action: .push, branch: forbidden, remote: "origin")
            let argv = (try? rogue.argv()) ?? []
            #expect(!argv.contains(where: { $0.hasPrefix("-") && $0 != forbidden }), "参数值不得被当成 flag：\(argv)")
        }
    }

    // MARK: - 远程同步（本地文件 remote，不需要网络）

    private func makeRemotePair() throws -> (origin: URL, work: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "lx-git-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let origin = base.appending(path: "origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try Self.run(["init", "-b", "main"], in: origin)
        try Self.run(["config", "user.email", "t@example.com"], in: origin)
        try Self.run(["config", "user.name", "T"], in: origin)
        try "v1\n".write(to: origin.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try Self.run(["add", "file.txt"], in: origin)
        try Self.run(["commit", "-m", "first"], in: origin)
        let work = base.appending(path: "work")
        try Self.run(["clone", origin.path, work.path, "--origin", "origin"], in: base)
        try Self.run(["config", "user.email", "t@example.com"], in: work)
        try Self.run(["config", "user.name", "T"], in: work)
        return (origin, work)
    }

    @Test("fetch updates remote refs and reports the divergence to the client")
    func fetchReflectsRemoteProgress() async throws {
        let pair = try makeRemotePair()
        defer { try? FileManager.default.removeItem(at: pair.origin.deletingLastPathComponent()) }
        // 上游再推进一个提交
        try "v2\n".write(to: pair.origin.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try Self.run(["commit", "-am", "second"], in: pair.origin)

        let (host, client) = try await Self.host(over: pair.work)
        defer { await host.shutdown() }

        let before = try await client.git.status()
        #expect(before.behind == 0, "fetch 之前看不到远端进度")

        let receipt = try #require((try await client.git.fetch(toolCallID: "call-fetch-1")).result)
        #expect(receipt.action == "fetch")
        #expect(receipt.risk == "write")
        #expect(receipt.mutationRevision > 0, "fetch 也必须经过 mutation coordinator")

        let after = try await client.git.status()
        #expect(after.behind == 1, "fetch 之后 behind 如实反映远端领先 1 个提交")
        #expect(after.ahead == 0)
        #expect(after.upstreamRemote == "origin")
        #expect(after.upstreamBranch == "main")
    }

    @Test("pull fast-forwards when the histories allow it")
    func pullFastForwards() async throws {
        let pair = try makeRemotePair()
        defer { try? FileManager.default.removeItem(at: pair.origin.deletingLastPathComponent()) }
        try "v2\n".write(to: pair.origin.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try Self.run(["commit", "-am", "second"], in: pair.origin)

        let (host, client) = try await Self.host(over: pair.work)
        defer { await host.shutdown() }

        _ = try await client.git.pull(toolCallID: "gui:" + UUID().uuidString)
        let content = try String(contentsOf: pair.work.appending(path: "file.txt"), encoding: .utf8)
        #expect(content == "v2\n", "fast-forward 后工作区内容与远端一致")
        let status = try await client.git.status()
        #expect(status.behind == 0)
        #expect(!status.isDirty)
    }

    @Test("A diverged pull fails as nonFastForward instead of merging or stashing")
    func divergedPullIsStructuredError() async throws {
        let pair = try makeRemotePair()
        defer { try? FileManager.default.removeItem(at: pair.origin.deletingLastPathComponent()) }
        try "remote\n".write(to: pair.origin.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try Self.run(["commit", "-am", "remote"], in: pair.origin)
        try "local\n".write(to: pair.work.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try Self.run(["commit", "-am", "local"], in: pair.work)

        let (host, client) = try await Self.host(over: pair.work)
        defer { await host.shutdown() }

        await #expect(throws: CoreError.self) {
            _ = try await client.git.pull(toolCallID: "call-pull-1")
        }
        // 没有偷偷 merge：HEAD 仍只有本地那一条提交，工作区内容未被改写。
        let log = try await client.git.log(limit: 10)
        #expect(!log.text.contains("Merge"))
        #expect(try String(contentsOf: pair.work.appending(path: "file.txt"), encoding: .utf8) == "local\n")
        // 也没有自动 stash：本地改动仍在。
        let status = try await client.git.status()
        #expect(status.ahead == 1 && status.behind == 1)
    }

    @Test("push refuses to guess a target when the branch has no upstream")
    func pushDoesNotGuessTarget() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lx-git-push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bare = base.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try Self.run(["init", "--bare", bare.path], in: base)
        let work = base.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Self.run(["init", "-b", "main"], in: work)
        try Self.run(["config", "user.email", "t@example.com"], in: work)
        try Self.run(["config", "user.name", "T"], in: work)
        // 有一个叫 origin 的已配置 remote，但当前分支从未推送过 → 没有 upstream。
        try Self.run(["remote", "add", "origin", bare.path], in: work)
        try "x\n".write(to: work.appending(path: "a.txt"), atomically: false, encoding: .utf8)

        let (host, client) = try await Self.host(over: work)
        defer { await host.shutdown() }
        _ = try await client.git.add(all: true, toolCallID: "call-a")
        _ = try await client.git.commit(message: "local only", toolCallID: "call-c")

        // 裸 push：没有 upstream 就必须失败，而不是猜一个远端。
        await #expect(throws: CoreError.self) {
            _ = try await client.git.push(toolCallID: "call-p")
        }
        // 只给一半目标也不行。
        await #expect(throws: CoreError.self) {
            _ = try await client.git.push(remote: "origin", toolCallID: "call-p0")
        }
        // 把 remote 写成裸 URL 并要求建立 upstream：Core 不代为添加 remote，直接拒绝。
        await #expect(throws: CoreError.self) {
            _ = try await client.git.push(remote: bare.path, branch: "main", setUpstream: true, toolCallID: "call-p1")
        }

        // 显式给出已配置的 remote 与 branch 才允许推送。
        let receipt = try #require((try await client.git.push(remote: "origin", branch: "main", setUpstream: true, toolCallID: "call-p2")).result)
        #expect(receipt.risk == "remoteWrite")
        let pushed = try Self.run(["rev-parse", "main"], in: bare).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pushed.count >= 7, "远端必须真的收到该分支")
        // upstream 已记录：再 push 不需要重复指定目标。
        let again = try #require((try await client.git.push(toolCallID: "call-p3")).result)
        #expect(again.risk == "remoteWrite")
    }

    // MARK: - 未跟踪文件的 file stats（契约固定语义）

    private func makeUntrackedRepository() throws -> URL {
        let root = try Self.makeRepository()
        // 同时存在 tracked 改动与未跟踪文件：两套 stats 来源必须共存且互不覆盖。
        try "one\ntwo\n".write(to: root.appending(path: "tracked.txt"), atomically: false, encoding: .utf8)
        try "one\ntwo\nthree\n".write(to: root.appending(path: "fresh.txt"), atomically: false, encoding: .utf8)
        // 含空格路径：迁移前这条靠前端 `diff --no-index` 才成立。
        try "a\nb\n".write(to: root.appending(path: "new file.txt"), atomically: false, encoding: .utf8)
        try "".write(to: root.appending(path: "empty.txt"), atomically: false, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0xFF]).write(to: root.appending(path: "blob.bin"))
        return root
    }

    @Test("Untracked files carry the frozen stats through git.diff")
    func untrackedFileStats() async throws {
        let root = try makeUntrackedRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        let result = try await client.git.diff(scope: .head, includePatch: true)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        // 文本未跟踪：additions = 行数，deletions = 0，binary = false。
        let fresh = try #require(byPath["fresh.txt"])
        #expect(fresh.isUntracked)
        #expect(fresh.additions == 3)
        #expect(fresh.deletions == 0)
        #expect(!fresh.binary)

        // 含空格路径必须完整出现在 files[] 里。
        let spaced = try #require(byPath["new file.txt"])
        #expect(spaced.additions == 2)
        #expect(spaced.deletions == 0)

        // 空文件是 0 行，不是 nil。
        #expect(byPath["empty.txt"]?.additions == 0)
        // 二进制：nil / nil / true。
        let binary = try #require(byPath["blob.bin"])
        #expect(binary.additions == nil)
        #expect(binary.deletions == nil)
        #expect(binary.binary)

        // tracked 变更仍走 numstat 语义，两套来源互不覆盖。
        let tracked = try #require(byPath["tracked.txt"])
        #expect(!tracked.isUntracked)
        #expect(tracked.additions == 2)
        #expect(tracked.deletions == 1)
    }

    @Test("Staged diffs exclude untracked files")
    func stagedScopeExcludesUntracked() async throws {
        let root = try makeUntrackedRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.run(["add", "fresh.txt"], in: root)
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }

        let staged = try await client.git.diff(scope: .staged)
        let paths = Set(staged.files.map(\.path))
        #expect(paths.contains("fresh.txt"), "已暂存的新文件本身就是 tracked 变更，必须出现")
        #expect(!paths.contains("new file.txt"), "仍未跟踪的文件不属于已暂存范围")
        #expect(!paths.contains("blob.bin"))
        // 工作区口径才带未跟踪文件。
        let worktree = try await client.git.diff(scope: .worktree)
        #expect(Set(worktree.files.map(\.path)).contains("new file.txt"))
    }

    @Test("Unstatsable files leave nil and never fail the diff")
    func untrackedStatsAreFailOpen() async throws {
        // 超大：跳过统计，不报错。
        let huge = Data(repeating: 0x61, count: GitService.untrackedStatsByteLimit + 1)
        #expect(GitService.lines(ofUntrackedFile: huge) == (nil, nil, false))
        // 非法 UTF-8 但没有 NUL：编码无法可靠判定 → nil，且不冒充二进制。
        let notUTF8 = Data([0xFF, 0xFE, 0x41])
        #expect(GitService.lines(ofUntrackedFile: notUTF8) == (nil, nil, false))
        // NUL 在嗅探窗口内才算二进制。
        #expect(GitService.lines(ofUntrackedFile: Data([0x41, 0x00, 0x42])) == (nil, nil, true))
        // 末尾缺换行仍然是一行；CRLF 不额外制造行。
        #expect(GitService.lines(ofUntrackedFile: Data("a\nb".utf8)) == (2, 0, false))
        #expect(GitService.lines(ofUntrackedFile: Data("a\r\nb\r\n".utf8)) == (2, 0, false))
        #expect(GitService.lines(ofUntrackedFile: Data()) == (0, 0, false))

        // 读不到的文件（这里用被忽略之外、统计阶段失败的路径）不得让整个 git.diff 失败。
        let root = try makeUntrackedRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, client) = try await Self.host(over: root)
        defer { await host.shutdown() }
        let result = try await client.git.diff(GitDiffRequest(scope: .head, includePatch: false, includeFileStats: true))
        #expect(result.patch == nil)
        #expect(!result.files.isEmpty)
    }

    /// 契约第十一节：行数只在 Core 里算。前端不得为了统计去读文件。
    @Test("The front end never reads files to compute stats")
    func frontEndDoesNotCountLinesItself() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pane = try String(
            contentsOf: root.appendingPathComponent("Apps/macOS/FrontendKit/Components/WarmToolPane.swift"),
            encoding: .utf8
        )
        #expect(!pane.contains("contents(atPath:"), "文件内容读取属于 Core")
        #expect(!pane.contains("count(of: \"\\n\")") && !pane.contains("split(separator: \"\\n\").count"),
                "前端不得自己数行")
        #expect(!pane.contains("--no-index"), "不允许用 git diff --no-index 绕开结构化 file stats")
    }

    @Test("Porcelain parsing is the single source for every count")
    func porcelainRecordsDriveCounts() {
        let sample = [
            "# branch.oid abc123",
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aa11 bb22 Sources/A.swift",
            "1 M. N... 100644 100644 100644 aa11 cc33 Sources/B.swift",
            "2 R. N... 100644 100644 100644 dd44 ee55 R100\u{1}Sources/New.swift\u{1}Sources/Old.swift",
            "? Docs/Untracked.md",
            "! Ignored/Output.txt",
            "u UU. N... 100644 100644 100644 100644 ff66 000000 111111 Sources/Conflict.swift",
        ].joined(separator: "\n")
        let parsed = GitStatusParse.workingTree(sample)
        // rename 的两个路径都是真实变化，各自计入；ignored 被排除。
        #expect(parsed.trackedChangeCount == 4, "3 条普通 tracked + rename 的两个路径 = 4")
        #expect(parsed.untrackedFileCount == 1)
        #expect(parsed.conflictedFileCount == 1)
        #expect(parsed.dirtyPathCount == 6)
        #expect(parsed.branch == "main")
    }
}
