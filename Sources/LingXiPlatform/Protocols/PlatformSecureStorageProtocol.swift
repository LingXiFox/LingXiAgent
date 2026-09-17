import Foundation

/// 跨平台密码学安全随机源与凭据存储隔离协议
public protocol PlatformSecureStorageProtocol: Sendable {
    /// 生成密码学安全的强随机字节流 (CPRNG)
    func generateSecureRandomBytes(count: Int) -> Data

    /// 对敏感文件施加严格的宿主隔离权限 (如 POSIX 0o600 / Windows 用户独占 ACL)
    func secureFile(at url: URL) throws

    /// 对机密存储目录施加严格隔离权限 (如 POSIX 0o700 / Windows 用户独占 ACL)
    func secureDirectory(at url: URL) throws

    /// 获取稳定的当前设备唯一指纹字符串（用于保险库本机绑定派生）
    func deviceFingerprint() -> String

    /// 读取系统特定凭据库（如 macOS Keychain），用于向后兼容单向迁移
    func readLegacyPlatformSecret(service: String, account: String) -> String?

    /// 从系统特定凭据库删除凭据
    func deleteLegacyPlatformSecret(service: String, account: String)
}

public extension PlatformSecureStorageProtocol {
    func readLegacyPlatformSecret(service: String, account: String) -> String? {
        nil
    }

    func deleteLegacyPlatformSecret(service: String, account: String) {}
}
