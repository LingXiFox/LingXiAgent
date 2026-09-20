#if os(Windows)
import Foundation
import WinSDK

public final class WindowsSystemAdapter: PlatformSystemProtocol, @unchecked Sendable {
    public init() {}

    public var osName: String { "Windows" }

    public var archName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "x86"
        #endif
    }

    public var defaultConfigurationDirectory: URL {
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData).appendingPathComponent("LingXiAgent")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent")
    }

    public var defaultTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    @discardableResult
    public func openBrowser(at url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "start", "", url.absoluteString]
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
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\clip.exe")
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
        let wName = name.utf16.map { WCHAR($0) } + [0]
        let wValue = value.utf16.map { WCHAR($0) } + [0]
        wName.withUnsafeBufferPointer { namePtr in
            wValue.withUnsafeBufferPointer { valPtr in
                _ = SetEnvironmentVariableW(namePtr.baseAddress, valPtr.baseAddress)
            }
        }
    }

    public func unsetEnvironmentVariable(_ name: String) {
        let wName = name.utf16.map { WCHAR($0) } + [0]
        wName.withUnsafeBufferPointer { namePtr in
            _ = SetEnvironmentVariableW(namePtr.baseAddress, nil)
        }
    }
}
#endif

