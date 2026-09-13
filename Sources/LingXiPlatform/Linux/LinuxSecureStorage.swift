#if os(Linux) || canImport(Glibc)
import Foundation

public final class LinuxSecureStorageAdapter: PlatformSecureStorageProtocol, @unchecked Sendable {
    public init() {}

    public func generateSecureRandomBytes(count: Int) -> Data {
        if let handle = FileHandle(forReadingAtPath: "/dev/urandom") {
            let data = handle.readData(ofLength: count)
            try? handle.close()
            if data.count == count {
                return data
            }
        }
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    public func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func secureDirectory(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public func deviceFingerprint() -> String {
        // 读取 Linux machine-id
        for path in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let content = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                return content
            }
        }
        return ProcessInfo.processInfo.hostName
    }
}
#endif
