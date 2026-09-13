#if os(Windows)
import Foundation

public final class WindowsSandboxAdapter: PlatformSandboxProtocol, @unchecked Sendable {
    public init() {}

    public var capabilities: SandboxCapabilities {
        // Windows 默认上报轻量环境限制能力
        SandboxCapabilities(filesystemEnforced: false, networkEnforced: false, processIsolationEnforced: false)
    }

    public func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
        // Windows 上直接调度命令，并透明上报沙箱能力
        ToolProcessInvocation(executable: executable, arguments: arguments)
    }
}
#endif
