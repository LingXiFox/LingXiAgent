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
            denyNetwork: policy.network == .deny
        )
        bwrapArgs += ["--", executable] + arguments
        return ToolProcessInvocation(executable: bwrap, arguments: bwrapArgs)
    }

    /// The bwrap argument family shared by `invocation` and the usability probe, so the probe
    /// always covers the real launch conditions instead of a cheaper approximation.
    private static func wrapArguments(
        workspace: URL,
        filesystem: SandboxFilesystemAccess,
        readOnlyPaths: [URL],
        denyNetwork: Bool
    ) -> [String] {
        var bwrapArgs: [String] = []

        // 1. 基础系统目录只读挂载
        for dir in systemReadOnlyDirectories where FileManager.default.fileExists(atPath: dir) {
            bwrapArgs += ["--ro-bind", dir, dir]
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
        for ro in readOnlyPaths {
            bwrapArgs += ["--ro-bind", ro.path, ro.path]
        }

        // 5. 工作目录
        bwrapArgs += ["--chdir", ws]
        return bwrapArgs
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
