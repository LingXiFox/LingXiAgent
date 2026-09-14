import Foundation

/// 插件顶层入口协议。
public protocol LingXiPlugin: Sendable {
    init()
    var manifest: PluginManifest { get }
    func activate(context: PluginContext) async throws
    func deactivate() async throws
}

public extension LingXiPlugin {
    func deactivate() async throws {}

    /// 标记 @main 的可执行入口
    static func main() async throws {
        let plugin = Self.init()
        let driver = PluginDriver(plugin: plugin)
        try await driver.runStdio()
    }
}
