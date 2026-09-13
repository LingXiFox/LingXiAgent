#if canImport(Darwin)
import Darwin
import Foundation

public final class DarwinProcessAdapter: PlatformProcessProtocol, @unchecked Sendable {
    public init() {}

    public func currentExecutablePath() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    public func resolveExecutable(named name: String, customSearchPaths: [String]?) -> String? {
        let defaultPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var searchPaths = customSearchPaths ?? []
        searchPaths.append(contentsOf: defaultPaths)
        return ExecutableFinder.findExecutable(named: name, customSearchPaths: searchPaths)
    }

    public func terminateProcessTree(pid: Int32, force: Bool) {
        guard pid > 1 else { return }
        let sig = force ? SIGKILL : SIGTERM
        // 尝试向进程组发送信号以清理子进程树
        let pgid = getpgid(pid)
        if pgid > 0 {
            _ = Darwin.kill(-pgid, sig)
        }
        _ = Darwin.kill(pid, sig)
    }
}
#endif
