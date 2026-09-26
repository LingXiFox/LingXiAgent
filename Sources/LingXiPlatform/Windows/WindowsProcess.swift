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
            "\(sysRoot)\\System32\\WindowsPowerShell\\v1.0",
            #"C:\Program Files\Git\bin"#,
            #"C:\Program Files\Git\usr\bin"#,
            #"C:\Program Files (x86)\Git\bin"#,
            #"C:\Program Files (x86)\Git\usr\bin"#
        ]
        var searchPaths = customSearchPaths ?? []
        searchPaths.append(contentsOf: defaultPaths)
        return ExecutableFinder.findExecutable(named: name, customSearchPaths: searchPaths)
    }

    public func terminateProcessTree(pid: Int32, force: Bool) {
        guard pid > 0 else { return }
        // taskkill /T kills the target *and its subtree*, so a target that resolves to this process
        // destroys the caller. The Darwin and Linux adapters already refuse to signal their own
        // process; Windows had no such check.
        if pid == Int32(bitPattern: GetCurrentProcessId()) { return }
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

    /// Read whatever the pipe buffer already holds without ever blocking the calling thread.
    /// `PeekNamedPipe` is the only non-blocking query an anonymous pipe supports, so a handle
    /// that is not a pipe (a console, a closed end) reports failure and drains nothing.
    public func nonblockingDrain(handle: PlatformPipeHandle, chunkSize: Int = 64 * 1024) -> Data {
        let pipe = handle.win32Handle
        var pending = DWORD(0)
        guard PeekNamedPipe(pipe, nil, 0, nil, &pending, nil) != 0, pending > 0 else { return Data() }
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while accumulated.count < Int(pending) {
            var obtained = DWORD(0)
            guard ReadFile(pipe, &chunk, DWORD(chunk.count), &obtained, nil) != 0, obtained > 0 else { break }
            accumulated.append(contentsOf: chunk[0..<Int(obtained)])
        }
        return accumulated
    }

    public func readAvailable(handle: PlatformPipeHandle) -> Data {
        let pipe = handle.win32Handle
        var pending = DWORD(0)
        guard PeekNamedPipe(pipe, nil, 0, nil, &pending, nil) != 0, pending > 0 else { return Data() }
        var chunk = [UInt8](repeating: 0, count: min(Int(pending), 4096))
        var obtained = DWORD(0)
        guard ReadFile(pipe, &chunk, DWORD(chunk.count), &obtained, nil) != 0, obtained > 0 else { return Data() }
        return Data(chunk[0..<Int(obtained)])
    }
}
#endif
