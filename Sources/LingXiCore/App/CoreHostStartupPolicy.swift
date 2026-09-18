import Foundation

/// CoreHost 启动与环境沙箱策略 (CoreHostStartupPolicy)
/// 明确区分生产运行、轻量单元测试与集成测试环境，杜绝测试执行无序扫描真实宿主插件或发起外部网络请求。
public struct CoreHostStartupPolicy: Sendable, Codable, Equatable {
    public var discoverSkills: Bool
    public var discoverCommands: Bool
    public var discoverBinaryPlugins: Bool
    public var refreshRegistry: Bool
    public var startMCP: Bool
    public var allowNetwork: Bool
    public var allowExternalProcesses: Bool

    public init(
        discoverSkills: Bool,
        discoverCommands: Bool,
        discoverBinaryPlugins: Bool,
        refreshRegistry: Bool,
        startMCP: Bool,
        allowNetwork: Bool,
        allowExternalProcesses: Bool
    ) {
        self.discoverSkills = discoverSkills
        self.discoverCommands = discoverCommands
        self.discoverBinaryPlugins = discoverBinaryPlugins
        self.refreshRegistry = refreshRegistry
        self.startMCP = startMCP
        self.allowNetwork = allowNetwork
        self.allowExternalProcesses = allowExternalProcesses
    }

    /// 生产环境：全功能开放
    public static let production = CoreHostStartupPolicy(
        discoverSkills: true,
        discoverCommands: true,
        discoverBinaryPlugins: true,
        refreshRegistry: true,
        startMCP: true,
        allowNetwork: true,
        allowExternalProcesses: true
    )

    /// 单元测试环境：无副作用纯净沙箱（不发现外部二进制插件、不触发网络刷新、不执行真实外部进程）
    public static let unitTest = CoreHostStartupPolicy(
        discoverSkills: false,
        discoverCommands: false,
        discoverBinaryPlugins: false,
        refreshRegistry: false,
        startMCP: false,
        allowNetwork: false,
        allowExternalProcesses: false
    )

    /// 集成测试环境：允许内置命令与受控外部进程，但禁用外部插件与公网 Registry 刷新
    public static let integrationTest = CoreHostStartupPolicy(
        discoverSkills: true,
        discoverCommands: true,
        discoverBinaryPlugins: false,
        refreshRegistry: false,
        startMCP: false,
        allowNetwork: false,
        allowExternalProcesses: true
    )

    /// 当前环境的默认推荐策略：如果处于测试环境，自动降级为单元测试沙箱
    public static var defaultPolicy: CoreHostStartupPolicy {
        if ProcessInfo.processInfo.environment["LINGXI_TEST_MODE"] == "1" ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .unitTest
        }
        return .production
    }
}
