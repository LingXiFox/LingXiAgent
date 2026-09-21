import Foundation

extension Data {
    /// 跨平台安全的数据文件写入方法
    /// 在 Windows 上避免使用 .atomic 以防止 ReplaceFile 引发的 Code 513 权限错误；
    /// 在 POSIX (Darwin, Linux) 上继续使用 .atomic 确保文件原子写入。
    public func writePlatformSafe(to url: URL) throws {
        #if os(Windows)
        try write(to: url, options: [])
        #else
        try write(to: url, options: .atomic)
        #endif
    }
}
