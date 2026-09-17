import Foundation

/// 跨平台路径与环境变量辅助工具
public enum PathUtilities {
    /// 平台特定的 PATH 环境变量条目分隔符（POSIX 为 ":"，Windows 为 ";"）
    public static var pathListSeparator: Character {
        #if os(Windows)
        return ";"
        #else
        return ":"
        #endif
    }

    /// 获取解析后的 PATH 搜索目录列表
    public static func systemPathDirectories(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let pathVar = environment["PATH"] ?? ""
        return pathVar.split(separator: pathListSeparator).map(String.init).filter { !$0.isEmpty }
    }

    /// 跨平台展开路径中的波浪号 ~
    public static func expandingTilde(in path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home: String
        #if os(Windows)
        home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        #else
        home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        #endif
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            let sub = String(path.dropFirst(2))
            return URL(fileURLWithPath: home).appendingPathComponent(sub).path
        }
        return path
    }

    /// 跨平台判断路径是否为绝对路径（POSIX 以 / 开头，Windows 以盘符驱动器如 C:\ 或 UNC \\ 开头）
    public static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\\\") { return true }
        if path.count >= 3 {
            let chars = Array(path)
            if chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/") {
                return true
            }
        }
        return false
    }
}
