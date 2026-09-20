import Foundation

/// 跨平台路径与环境变量辅助工具
public enum PathUtilities {
    /// Build a directory URL that is always safe for `Process.currentDirectoryURL`.
    ///
    /// Once a process's own working directory is deleted, `currentDirectoryPath` returns an
    /// empty string and `URL(fileURLWithPath:)` degrades to the relative URL "./". Foundation
    /// then rejects the assignment with an NSInvalidArgumentException that Swift cannot catch,
    /// aborting the whole host. Fall back to the temporary directory instead.
    public static func workingDirectoryURL(for path: String) -> URL {
        let candidate = URL(fileURLWithPath: path.isEmpty ? NSTemporaryDirectory() : path, isDirectory: true)
        return candidate.isFileURL ? candidate : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

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
            #if os(Windows)
            let separator = "\\"
            let cleanHome = (home.hasSuffix("/") || home.hasSuffix("\\")) ? String(home.dropLast()) : home
            let cleanSub = sub.replacingOccurrences(of: "/", with: separator)
            return "\(cleanHome)\(separator)\(cleanSub)"
            #else
            return URL(fileURLWithPath: home).appendingPathComponent(sub).path
            #endif
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
