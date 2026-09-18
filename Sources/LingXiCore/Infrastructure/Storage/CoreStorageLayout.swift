import Foundation

/// Core 唯一权威存储布局 (CoreStorageLayout)
/// 严格收敛 CoreHost 及其所属所有子系统（Persistence, Sessions, E-Core, Todo, EventLog, Content, GraphCache 等）的磁盘根目录。
/// 彻底根除语义存储各自回退真实 HOME (~/.lingxiagent) 导致的数据分裂、测试污染与多实例数据串扰。
public struct CoreStorageLayout: Sendable, Equatable {
    public let root: URL

    public var configuration: URL { root.appendingPathComponent("config.json", isDirectory: false) }
    public var persistence: URL {
        let catalog = root.appendingPathComponent("catalog.sqlite")
        let legacyDB = root.appendingPathComponent("lingxiagent.db")
        if FileManager.default.fileExists(atPath: catalog.path) || FileManager.default.fileExists(atPath: legacyDB.path) {
            return root
        }
        return root.appendingPathComponent("persistence", isDirectory: true)
    }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var ecore: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var todos: URL { root.appendingPathComponent("cache/todos", isDirectory: true) }
    public var eventLog: URL { root.appendingPathComponent("events", isDirectory: true) }
    public var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var graphCache: URL { root.appendingPathComponent("cache/graph", isDirectory: true) }
    public var providerCache: URL { root.appendingPathComponent("cache/providers", isDirectory: true) }

    public init(root: URL) {
        self.root = root
    }

    /// 生产环境默认存储布局 (~/.lingxiagent)
    public static var production: CoreStorageLayout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CoreStorageLayout(root: home.appendingPathComponent(".lingxiagent", isDirectory: true))
    }

    /// 当前活跃存储布局：优先读取环境变量 LINGXI_STORAGE_ROOT，否则回退至 production
    public static var current: CoreStorageLayout {
        if let custom = ProcessInfo.processInfo.environment["LINGXI_STORAGE_ROOT"], !custom.isEmpty {
            return CoreStorageLayout(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return production
    }

    /// 测试环境沙箱存储布局（完全与宿主用户目录隔离，测试结束可整体安全销毁）
    public static func temporarySandbox(named: String = UUID().uuidString) -> CoreStorageLayout {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-\(named)", isDirectory: true)
        return CoreStorageLayout(root: temp)
    }

    /// 确保所有必要子目录在磁盘上创建
    public func ensureDirectoriesExist() throws {
        let fileManager = FileManager.default
        let dirs = [persistence, sessions, todos, eventLog, content, cache, graphCache, providerCache]
        for dir in dirs {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
