#if os(Windows)
import Foundation
import WinSDK

public final class WindowsProcessAdapter: PlatformProcessProtocol, @unchecked Sendable {
    public init() {}

    public func currentExecutablePath() -> URL? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decodingCString: buffer, as: UTF16.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    public func resolveExecutable(named name: String, customSearchPaths: [String]?) -> String? {
        let env = ProcessInfo.processInfo.environment
        let sysRoot = env["SystemRoot"] ?? "C:\\Windows"
        let defaultPaths = [
            "\(sysRoot)\\System32",
            sysRoot,
            "\(sysRoot)\\System32\\WindowsPowerShell\\v1.0"
        ]
        var searchPaths = customSearchPaths ?? []
        searchPaths.append(contentsOf: defaultPaths)
        return ExecutableFinder.findExecutable(named: name, customSearchPaths: searchPaths)
    }

    public func terminateProcessTree(pid: Int32, force: Bool) {
        guard pid > 0 else { return }
        // Windows 上使用 taskkill /T /PID 能够级联杀灭整棵子进程树，force 为 true 时加入 /F 强制终止
        let taskkill = Process()
        taskkill.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\taskkill.exe")
        var arguments = ["/T", "/PID", String(pid)]
        if force {
            arguments.insert("/F", at: 0)
        }
        taskkill.arguments = arguments
        try? taskkill.run()
        taskkill.waitUntilExit()
    }
}
#endif
