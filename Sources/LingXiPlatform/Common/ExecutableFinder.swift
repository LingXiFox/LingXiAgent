import Foundation

/// 跨平台可执行文件与 CLI 命令查找器
public enum ExecutableFinder {
    /// Windows 默认的可执行文件扩展名列表
    public static let defaultWindowsExtensions = [".exe", ".cmd", ".bat", ".com"]

    /// 根据命令名称与自定义/系统路径寻找可执行文件的绝对路径
    public static func findExecutable(
        named name: String,
        customSearchPaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fileManager = FileManager.default

        // 1. 如果本身是绝对路径或相对路径，且已直接存在可执行文件
        let expanded = PathUtilities.expandingTilde(in: name)
        if (expanded.contains("/") || expanded.contains("\\")) && fileManager.isExecutableFile(atPath: expanded) {
            return expanded
        }

        // 2. 收集候选目录
        var searchDirs = customSearchPaths ?? []
        searchDirs.append(contentsOf: PathUtilities.systemPathDirectories(from: environment))

        // 3. 收集后缀扩展名
        #if os(Windows)
        let pathExtVar = environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD"
        let extensions = pathExtVar.split(separator: ";").map { $0.lowercased() }
        #else
        let extensions = [""]
        #endif

        for dir in searchDirs {
            let base = PathUtilities.expandingTilde(in: dir)
            for ext in extensions {
                let candidate: String
                if ext.isEmpty || expanded.lowercased().hasSuffix(ext) {
                    candidate = URL(fileURLWithPath: base).appendingPathComponent(expanded).path
                } else {
                    candidate = URL(fileURLWithPath: base).appendingPathComponent(expanded + ext).path
                }
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }
}
