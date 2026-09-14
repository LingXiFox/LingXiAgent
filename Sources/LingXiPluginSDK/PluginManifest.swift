import Foundation
import LingXiProtocol

/// 插件安全能力声明。
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
