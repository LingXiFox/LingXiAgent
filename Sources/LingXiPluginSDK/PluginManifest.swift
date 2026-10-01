import Foundation

/// 插件安全能力声明。
///
/// 能力是权限申请,与协议兼容是两件事:后者由握手里的 `ipcVersion` 判定
/// (见 `PluginIPC`),不要拿 `minimumCoreVersion` 字符串代替版本协商。
public enum PluginCapability: String, Codable, Sendable, CaseIterable {
    case projectRead
    case projectWrite
    case processExecution
    case networkAccess
}

/// 插件元数据与权限声明。
public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String?
    public let capabilities: Set<PluginCapability>
    /// 人类可读的最低宿主版本提示。协议兼容不看它,看 `PluginHandshakeResult.ipcVersion`。
    public let minimumCoreVersion: String?

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        author: String? = nil,
        capabilities: Set<PluginCapability> = [],
        minimumCoreVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.capabilities = capabilities
        self.minimumCoreVersion = minimumCoreVersion
    }
}
