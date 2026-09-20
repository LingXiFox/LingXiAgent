#if os(Linux) || canImport(Glibc)
import Foundation

public final class LinuxSystemAdapter: PlatformSystemProtocol, @unchecked Sendable {
    public init() {}

    public var osName: String { "Linux" }

    public var archName: String {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public var defaultConfigurationDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("lingxiagent")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lingxiagent")
    }

    public var defaultTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    @discardableResult
    public func openBrowser(at url: URL) -> Bool {
        guard let xdgOpen = ExecutableFinder.findExecutable(named: "xdg-open") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdgOpen)
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func copyToClipboard(_ text: String) -> Bool {
        // 依次尝试 wl-copy, xclip, xsel
        let candidates: [(cmd: String, args: [String])] = [
            ("wl-copy", []),
            ("xclip", ["-selection", "clipboard"]),
            ("xsel", ["--clipboard", "--input"])
        ]
        for candidate in candidates {
            if let exe = ExecutableFinder.findExecutable(named: candidate.cmd) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = candidate.args
                let pipe = Pipe()
                process.standardInput = pipe
                do {
                    try process.run()
                    try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                    try pipe.fileHandleForWriting.close()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        return true
                    }
                } catch {
                    continue
                }
            }
        }
        return false
    }

    public func getEnvironmentVariable(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    public func setEnvironmentVariable(_ name: String, value: String) {
        #if canImport(Glibc)
        Glibc.setenv(name, value, 1)
        #elseif canImport(Musl)
        Musl.setenv(name, value, 1)
        #endif
    }

    public func unsetEnvironmentVariable(_ name: String) {
        #if canImport(Glibc)
        Glibc.unsetenv(name)
        #elseif canImport(Musl)
        Musl.unsetenv(name)
        #endif
    }
}
#endif
