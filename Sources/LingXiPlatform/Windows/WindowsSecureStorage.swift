#if os(Windows)
import Foundation
#if canImport(WinSDK)
import WinSDK
#endif

public final class WindowsSecureStorageAdapter: PlatformSecureStorageProtocol, @unchecked Sendable {
    public init() {}

    public func generateSecureRandomBytes(count: Int) -> Data {
        #if canImport(WinSDK)
        var bytes = [UInt8](repeating: 0, count: count)
        // 使用 Windows CNG BCryptGenRandom 生成真加密级安全随机数 (CPRNG)
        let status = BCryptGenRandom(nil, &bytes, ULONG(count), ULONG(BCRYPT_USE_SYSTEM_PREFERRED_RNG))
        if status == 0 {
            return Data(bytes)
        }
        #endif
        var fallback = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            fallback[i] = UInt8.random(in: .min ... .max)
        }
        return Data(fallback)
    }

    public func secureFile(at url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            #if canImport(WinSDK)
            _ = url.path.withCString(encodedAs: UTF16.self) { widePath in
                SetFileAttributesW(widePath, DWORD(FILE_ATTRIBUTE_NORMAL))
            }
            #else
            try? manager.setAttributes([:], ofItemAtPath: url.path)
            #endif
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
