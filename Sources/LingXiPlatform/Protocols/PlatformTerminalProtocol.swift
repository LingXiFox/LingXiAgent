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

    /// 判断标准输入是否连接到了交互式终端设备 (isatty)
    func isInteractive() -> Bool

    /// 在无回显模式下读取一行机密输入（密码/Token）
    func readSecretLine(prompt: String) -> String?

    /// 安装标准终端信号处理或控制事件拦截器
    func installSignalHandlers()
}

public extension PlatformTerminalProtocol {
    func isInteractive() -> Bool {
        false
    }

    func readSecretLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        return readLine(strippingNewline: true)
    }

    func installSignalHandlers() {}
}
