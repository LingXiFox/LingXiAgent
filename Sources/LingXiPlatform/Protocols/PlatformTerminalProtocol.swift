import Foundation

/// 跨平台终端与控制台低级模式抽象协议
public protocol PlatformTerminalProtocol: Sendable {
    /// 获取当前终端行数与列数
    func getTerminalDimensions() -> (columns: Int, rows: Int)?

    /// 将标准输入切换为 Raw Mode，返回用于恢复原模式的 opaque token
    func enableRawMode() throws -> Any?

    /// 使用之前保存的 token 恢复终端原始模式
    func restoreTerminalMode(token: Any?)

    /// 从标准输入读取一个 UTF-8 字节，支持超时等待（毫秒）
    func readByte(timeoutMilliseconds: Int32) -> UInt8?
}
