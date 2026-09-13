#if canImport(Darwin)
import Darwin
import Foundation

public final class DarwinSandboxAdapter: PlatformSandboxProtocol, @unchecked Sendable {
    public init() {}

    public var capabilities: SandboxCapabilities {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            return SandboxCapabilities(filesystemEnforced: true, networkEnforced: true, processIsolationEnforced: false)
        }
        return SandboxCapabilities(filesystemEnforced: false, networkEnforced: false, processIsolationEnforced: false)
    }

    public func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw NSError(domain: "LingXiPlatform.Sandbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS 缺少 /usr/bin/sandbox-exec"])
        }
        let workspace = policy.workspace
        let roots = Set([
            workspace.path,
            workspace.resolvingSymlinksInPath().path,
            workspace.path.replacingOccurrences(of: "/private/var/", with: "/var/"),
            workspace.path.replacingOccurrences(of: "/var/", with: "/private/var/")
        ]).sorted().map { root in
            let path = escapeSandboxString(root)
            let read = "(allow file-read* (subpath \"\(path)\"))"
            return policy.filesystem == .workspaceReadWrite ? read + "\n(allow file-write* (subpath \"\(path)\"))" : read
        }.joined(separator: "\n")

        let readOnlyRoots = Set(policy.readOnlyPaths.map(\.path)).sorted().map { root in
            "(allow file-read* (subpath \"\(escapeSandboxString(root))\"))"
        }.joined(separator: "\n")

        let processRules = policy.allowSubprocesses ? "(allow process-exec)\n(allow process-fork)" : ""
        let trustedRoots = ["/usr/lib", "/System/Library", "/Applications/Xcode.app", "/Applications/Xcode-beta.app", "/Library/Developer", "/opt/homebrew"]
            .map { "(allow file-read* (subpath \"\(escapeSandboxString($0))\"))" }
            .joined(separator: "\n")

        let profile = """
        (version 1)
        (deny default)
        (import \"system.sb\")
        (deny network*)
        \(processRules)
        (allow signal (target self))
        (allow file-read-metadata (subpath \"/\"))
        \(roots)
        \(readOnlyRoots)
        (allow file-read* (literal \"\(escapeSandboxString(executable))\"))
        (allow file-read* (literal \"/bin/sh\"))
        (allow file-read* (literal \"/private/var/select/sh\"))
        \(trustedRoots)
        """
        return ToolProcessInvocation(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + arguments)
    }

    private func escapeSandboxString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
#endif
