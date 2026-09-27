#if os(Linux) || canImport(Glibc)
import Foundation

public final class LinuxSandboxAdapter: PlatformSandboxProtocol, @unchecked Sendable {
    public init() {}

    private var bwrapPath: String? {
        ExecutableFinder.findExecutable(named: "bwrap")
    }

    public var capabilities: SandboxCapabilities {
        let probe = Self.launchProbe.valueOrProbe {
            guard let bwrap = self.bwrapPath else { return (filesystem: false, network: false) }
            return (
                filesystem: Self.launch(bwrap: bwrap, denyNetwork: false),
                network: Self.launch(bwrap: bwrap, denyNetwork: true)
            )
        }
        // Callers gate on `filesystemEnforced` and then build an invocation for the default policy,
        // which denies network. A bwrap that cannot create a usable network namespace still mounts
        // read-only bind trees successfully, so reporting filesystem enforcement alone would let the
        // caller produce an invocation that dies on `RTM_NEWADDR`. Enforceability therefore means
        // "the invocation we are about to build actually launches".
        let enforced = probe.filesystem && probe.network
        return SandboxCapabilities(
            filesystemEnforced: enforced,
            networkEnforced: probe.network,
            processIsolationEnforced: enforced
        )
    }

    public func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
        guard let bwrap = bwrapPath else {
            throw NSError(domain: "LingXiPlatform.Sandbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Linux 环境未安装 bubblewrap (bwrap)，无法建立安全沙箱隔离"])
        }
        // Callers no longer pre-empt this decision, so the throw for an unusable bwrap lives here:
        // a half-installed bubblewrap must not silently produce an invocation that dies at launch.
        guard capabilities.filesystemEnforced else {
            throw NSError(domain: "LingXiPlatform.Sandbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "bubblewrap 已安装但在当前环境无法建立沙箱（用户命名空间或网络隔离不可用），无法安全执行命令"])
        }
        var bwrapArgs = Self.wrapArguments(
            workspace: policy.workspace,
            filesystem: policy.filesystem,
            readOnlyPaths: policy.readOnlyPaths,
            denyNetwork: policy.network == .deny,
            workingDirectory: policy.workingDirectory,
            executable: executable
        )
        bwrapArgs += ["--", executable] + arguments
        return ToolProcessInvocation(executable: bwrap, arguments: bwrapArgs)
    }

    /// The bwrap argument family shared by `invocation` and the usability probe, so the probe
    /// always covers the real launch conditions instead of a cheaper approximation.
    /// Internal rather than private so the mount set is assertable without a working bubblewrap:
    /// the probe needs user namespaces, which container runners are not guaranteed to have.
    static func wrapArguments(
        workspace: URL,
        filesystem: SandboxFilesystemAccess,
        readOnlyPaths: [URL],
        denyNetwork: Bool,
        workingDirectory: URL? = nil,
        executable: String = "/bin/true"
    ) -> [String] {
        var bwrapArgs: [String] = []
        var mountedPrefixes: [String] = []

        // 1. 基础系统目录只读挂载
        for dir in systemReadOnlyDirectories where FileManager.default.fileExists(atPath: dir) {
            bwrapArgs += ["--ro-bind", dir, dir]
            mountedPrefixes.append(dir)
        }

        // 2. 虚拟文件系统
        bwrapArgs += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]

        // 3. 网络隔离
        if denyNetwork {
            bwrapArgs += ["--unshare-net"]
        }

        // 4. 工作区与只读目录
        let ws = workspace.path
        if filesystem == .workspaceReadWrite {
            bwrapArgs += ["--bind", ws, ws]
        } else {
            bwrapArgs += ["--ro-bind", ws, ws]
        }
        mountedPrefixes.append(ws)
        for ro in readOnlyPaths {
            bwrapArgs += ["--ro-bind", ro.path, ro.path]
            mountedPrefixes.append(ro.path)
        }

        // 5. 被要求执行的那个程序本身。它经常不在上面的挂载集合里：用户级前缀（~/local/usr/bin）、
        //    Homebrew 式 /opt 前缀、venv 里的解释器都算。命名空间内不存在的路径不是「权限不足」而是
        //    「根本不存在」，bwrap 于是以 execvp ... No such file or directory 退出 1 —— 而 1 恰好是
        //    ripgrep 表示「无匹配」的退出码，一次坏掉的沙箱因此会伪装成一次空搜索结果。bwrap 会自己
        //    创建挂载点的父目录，所以只需绑定叶子目录，且只读：能被执行不等于能被改写。
        let programDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        if !mountedPrefixes.contains(where: { isSelfOrDescendant(programDirectory, of: $0) }) {
            bwrapArgs += ["--ro-bind", programDirectory, programDirectory]
        }

        // 6. 工作目录
        let childCwd = childWorkingDirectory(in: workspace, requested: workingDirectory)
        bwrapArgs += ["--chdir", childCwd.path]
        return bwrapArgs
    }

    private static func isSelfOrDescendant(_ path: String, of prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// bwrap replaces the child's working directory, so a caller that asked to run somewhere
    /// inside the workspace has to say so here or the command silently starts at the workspace
    /// root and reports paths relative to there. Anything outside the bound workspace does not
    /// exist inside the namespace, so it falls back to the workspace root.
    private static func childWorkingDirectory(in workspace: URL, requested: URL?) -> URL {
        guard let requested else { return workspace }
        let root = workspace.path
        let directory = requested.path
        return (directory == root || directory.hasPrefix(root + "/")) ? requested : workspace
    }

    private static let systemReadOnlyDirectories = ["/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc"]

    private static func launch(bwrap: String, denyNetwork: Bool) -> Bool {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-sandbox-probe-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        var arguments = wrapArguments(
            workspace: workspace,
            filesystem: .workspaceReadWrite,
            readOnlyPaths: [],
            denyNetwork: denyNetwork
        )
        arguments += ["--", "/bin/true"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bwrap)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if finished.wait(timeout: .now() + .seconds(10)) == .timedOut {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            return false
        }
        return process.terminationStatus == 0
    }

    private final class LaunchProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (filesystem: Bool, network: Bool)?

        func valueOrProbe(_ probe: () -> (filesystem: Bool, network: Bool)) -> (filesystem: Bool, network: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if let result { return result }
            let probed = probe()
            result = probed
            return probed
        }
    }

    private static let launchProbe = LaunchProbe()
}
#endif
