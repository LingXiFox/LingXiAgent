#if canImport(Darwin)
import Darwin
import Foundation

public final class DarwinSystemAdapter: PlatformSystemProtocol, @unchecked Sendable {
    public init() {}

    public var osName: String { "macOS" }

    public var archName: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public var defaultConfigurationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent")
    }

    public var defaultTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    @discardableResult
    public func openBrowser(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func getEnvironmentVariable(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    public func setEnvironmentVariable(_ name: String, value: String) {
        Darwin.setenv(name, value, 1)
    }

    public func unsetEnvironmentVariable(_ name: String) {
        Darwin.unsetenv(name)
    }
}
#endif
