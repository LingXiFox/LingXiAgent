#if os(Windows)
import Foundation

public final class WindowsSecureStorageAdapter: PlatformSecureStorageProtocol, @unchecked Sendable {
    public init() {}

    public func generateSecureRandomBytes(count: Int) -> Data {
        // Windows CPRNG
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes)
    }

    public func secureFile(at url: URL) throws {
        // Windows 下文件权限保护由 ACL 维护，这里保证文件属性正常
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try? manager.setAttributes([:], ofItemAtPath: url.path)
        }
    }

    public func secureDirectory(at url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func deviceFingerprint() -> String {
        return ProcessInfo.processInfo.hostName
    }
}
#endif
