import Foundation

/// 跨平台进程管理、寻址与生命周期清理协议
public protocol PlatformProcessProtocol: Sendable {
    /// 获取当前可执行文件自身的真实路径
    func currentExecutablePath() -> URL?

    /// 按照系统 PATH 与可执行后缀（如 Windows PATHEXT）动态寻找命令的绝对路径
    func resolveExecutable(named name: String, customSearchPaths: [String]?) -> String?

    /// 级联清理整棵子进程树，杜绝孤儿与僵尸后台进程泄漏
    func terminateProcessTree(pid: Int32, force: Bool)

    /// 从文件句柄非阻塞排空所有已就绪的缓冲区数据
    func nonblockingDrain(handle: FileHandle, chunkSize: Int) -> Data
}

public extension PlatformProcessProtocol {
    func nonblockingDrain(handle: FileHandle, chunkSize: Int = 64 * 1024) -> Data {
        handle.availableData
    }
}
