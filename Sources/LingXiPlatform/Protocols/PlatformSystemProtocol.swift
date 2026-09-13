import Foundation

/// 跨平台桌面与系统集成能力协议（浏览器调用、剪贴板交互、标准目录与系统信息）
public protocol PlatformSystemProtocol: Sendable {
    /// 打开系统默认浏览器访问指定 URL
    @discardableResult
    func openBrowser(at url: URL) -> Bool

    /// 将文本写入操作系统系统剪贴板
    @discardableResult
    func copyToClipboard(_ text: String) -> Bool

    /// 获取操作系统标准显示名称 (macOS / Linux / Windows)
    var osName: String { get }

    /// 获取底层 CPU 架构显示名称 (arm64 / x86_64 等)
    var archName: String { get }

    /// 获取标准配置主目录 (XDG / AppData / Application Support)
    var defaultConfigurationDirectory: URL { get }

    /// 获取标准运行时临时目录
    var defaultTemporaryDirectory: URL { get }
}
