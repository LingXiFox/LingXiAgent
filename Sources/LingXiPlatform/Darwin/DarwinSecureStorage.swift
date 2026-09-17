#if canImport(Darwin)
import Darwin
import Foundation
#if canImport(Security)
import Security
#endif

public final class DarwinSecureStorageAdapter: PlatformSecureStorageProtocol, @unchecked Sendable {
    public init() {}

    public func generateSecureRandomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        #endif
        // Fallback CPRNG
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    public func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func secureDirectory(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public func deviceFingerprint() -> String {
        // macOS: 获取硬件 UUID 或主机名
        var size: size_t = 0
        sysctlbyname("kern.uuid", nil, &size, nil, 0)
        if size > 0 {
            var uuid = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.uuid", &uuid, &size, nil, 0) == 0 {
                return uuid.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
            }
        }
        return ProcessInfo.processInfo.hostName
    }
}
#endif
