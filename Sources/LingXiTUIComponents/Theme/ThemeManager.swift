import Foundation

/// 主题管理与运行时调度中枢 (ThemeManager)
public final class ThemeManager: @unchecked Sendable {
    public static let shared = ThemeManager()

    private var current: ThemeDefinition
    private var themes: [String: ThemeDefinition] = [:]
    private var observers: [(ThemeDefinition) -> Void] = []
    private let lock = NSLock()

    public init() {
        // 1. 初始化内置 6 套主题
        var initialDict: [String: ThemeDefinition] = [:]
        for t in BuiltinThemes.all {
            initialDict[t.id] = t
        }
        self.themes = initialDict

        // 2. 根据终端与系统外观自动决议首选主题
        let isLight = Self.detectTerminalIsLight()
        self.current = isLight ? BuiltinThemes.pearlFoxLight : BuiltinThemes.cyberFoxDark

        // 3. 扫描用户目录 (~/.lingxiagent/themes/*.json)
        loadUserThemes()
    }

    /// 获取当前生效的主题
    public var currentTheme: ThemeDefinition {
        lock.withLock { current }
    }

    /// 获取所有已注册主题列表
    public var availableThemes: [ThemeDefinition] {
        lock.withLock { Array(themes.values).sorted(by: { $0.id < $1.id }) }
    }

    /// 切换当前主题 (支持按 ID 或名称模糊匹配，如 "dark", "light", "catppuccin", "dracula")
    @discardableResult
    public func setTheme(by idOrQuery: String) -> Bool {
        let query = idOrQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return false }

        var matchedTheme: ThemeDefinition? = nil
        var callbacksToInvoke: [(ThemeDefinition) -> Void] = []

        lock.withLock {
            // 1. 精确匹配 ID
            if let exact = themes[query] {
                matchedTheme = exact
            } else if let hit = themes.values.first(where: {
                $0.id.lowercased() == query || $0.name.lowercased().contains(query)
            }) {
                matchedTheme = hit
            } else if query == "light" {
                matchedTheme = BuiltinThemes.pearlFoxLight
            } else if query == "dark" {
                matchedTheme = BuiltinThemes.cyberFoxDark
            }

            if let theme = matchedTheme {
                self.current = theme
                callbacksToInvoke = self.observers
            }
        }

        if let theme = matchedTheme {
            for cb in callbacksToInvoke {
                cb(theme)
            }
            return true
        }
        return false
    }

    /// 注册主题切换事件监听
    public func addObserver(_ callback: @escaping (ThemeDefinition) -> Void) {
        lock.withLock {
            observers.append(callback)
        }
    }

    /// 扫描并加载用户自定义主题 JSON 文件
    public func loadUserThemes(from directoryURL: URL? = nil) {
        let dir: URL
        if let directoryURL {
            dir = directoryURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            dir = home.appendingPathComponent(".lingxiagent/themes", isDirectory: true)
        }

        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file),
                  let theme = try? JSONDecoder().decode(ThemeDefinition.self, from: data) else {
                continue
            }
            lock.withLock {
                self.themes[theme.id] = theme
            }
        }
    }

    /// 探测终端是否为浅色模式 (Light Mode)
    public static func detectTerminalIsLight() -> Bool {
        let env = ProcessInfo.processInfo.environment

        // 1. 检查 COLORFGBG 环境变量 (格式如 "15;0" 或 "0;15"，后者为背景色码)
        if let colorfgbg = env["COLORFGBG"] {
            let parts = colorfgbg.split(separator: ";")
            if let last = parts.last, let bgCode = Int(last.trimmingCharacters(in: .whitespaces)) {
                // 传统 ANSI 中，背景代码 7 或 15 通常为浅色 (white/bright white)
                if bgCode == 7 || bgCode == 15 {
                    return true
                }
            }
        }

        // 2. 检查应用环境变量强制指定
        if let forceTheme = env["LINGXI_THEME"]?.lowercased() {
            if forceTheme == "light" || forceTheme.contains("light") {
                return true
            }
        }

        return false
    }
}
