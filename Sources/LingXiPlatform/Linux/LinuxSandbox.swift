#if os(Linux) || canImport(Glibc)
import Foundation

public final class LinuxSandboxAdapter: PlatformSandboxProtocol, @unchecked Sendable {
    public init() {}

    private var bwrapPath: String? {
        ExecutableFinder.findExecutable(named: "bwrap")
    }

    public var capabilities: SandboxCapabilities {
        if bwrapPath != nil {
            return SandboxCapabilities(filesystemEnforced: true, networkEnforced: true, processIsolationEnforced: true)
        }
        return SandboxCapabilities(filesystemEnforced: false, networkEnforced: false, processIsolationEnforced: false)
    }

    public func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
        guard let bwrap = bwrapPath else {
            throw NSError(domain: "LingXiPlatform.Sandbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Linux 环境未安装 bubblewrap (bwrap)，无法建立安全沙箱隔离"])
        }

        var bwrapArgs: [String] = []

        // 1. 基础系统目录只读挂载
        let sysDirs = ["/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc"]
        for dir in sysDirs where FileManager.default.fileExists(atPath: dir) {
            bwrapArgs += ["--ro-bind", dir, dir]
        }

        // 2. 虚拟文件系统
        bwrapArgs += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]

        // 3. 网络隔离
        if case .deny = policy.network {
            bwrapArgs += ["--unshare-net"]
        }

        // 4. 工作区与只读目录
        let ws = policy.workspace.path
        if policy.filesystem == .workspaceReadWrite {
            bwrapArgs += ["--bind", ws, ws]
        } else {
            bwrapArgs += ["--ro-bind", ws, ws]
        }

        for ro in policy.readOnlyPaths {
            bwrapArgs += ["--ro-bind", ro.path, ro.path]
        }

        // 5. 工作目录与目标程序
        bwrapArgs += ["--chdir", ws, "--", executable] + arguments

        return ToolProcessInvocation(executable: bwrap, arguments: bwrapArgs)
    }
}
#endif
