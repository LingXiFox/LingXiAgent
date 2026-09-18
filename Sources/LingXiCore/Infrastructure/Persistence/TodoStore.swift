import Foundation
import LingXiPlatform
import LingXiProtocol

/// TodoStore: Core/Persistence 内部的待办事项权威存储。
/// 彻底移出 Protocol 层，禁止作为跨进程隐式文件 side channel 使用。
/// 数据通过 Core 发布权威 SessionSnapshot / 事件流传输给 Application 与 TUI。
public final class TodoStore: @unchecked Sendable {
    public static var shared: TodoStore = TodoStore()
    private let lock = NSLock()
    private var todosBySession: [String: [TodoItemData]] = [:]
    private var fileTimestamps: [String: Date] = [:]
    private let storageDir: URL

    public static func configureShared(storageDir: URL) {
        shared = TodoStore(storageDir: storageDir)
    }

    public init(storageDir: URL? = nil) {
        if let storageDir {
            self.storageDir = storageDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dir = home.appendingPathComponent(".lingxiagent/cache/todos", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageDir = dir
        }
    }

    private func fileURL(for sessionID: String) -> URL {
        let safe = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sessionID
        return storageDir.appendingPathComponent("todos_\(safe).json")
    }

    private func loadFromFileIfNeeded(sessionID: String) {
        let url = fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return }
        if let cachedDate = fileTimestamps[sessionID], cachedDate > modDate {
            return
        }
        if let data = try? Data(contentsOf: url),
           let items = try? JSONDecoder().decode([TodoItemData].self, from: data) {
            todosBySession[sessionID] = items
            fileTimestamps[sessionID] = modDate
        }
    }

    private func persistToFile(sessionID: String, items: [TodoItemData]) {
        let url = fileURL(for: sessionID)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
            fileTimestamps[sessionID] = Date()
        }
    }

    public func getTodos(for sessionID: String) -> [TodoItemData] {
        lock.lock()
        defer { lock.unlock() }
        loadFromFileIfNeeded(sessionID: sessionID)
        let list = todosBySession[sessionID] ?? []
        if !list.isEmpty { return list }
        if sessionID != "default" {
            loadFromFileIfNeeded(sessionID: "default")
            return todosBySession["default"] ?? []
        }
        return []
    }

    public func addTodo(_ item: TodoItemData, for sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        loadFromFileIfNeeded(sessionID: sessionID)
        var list = todosBySession[sessionID] ?? []
        if let idx = list.firstIndex(where: { $0.id == item.id }) {
            list[idx] = item
        } else {
            list.append(item)
        }
        todosBySession[sessionID] = list
        persistToFile(sessionID: sessionID, items: list)
    }

    public func updateTodo(id: String, status: String, title: String?, for sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadFromFileIfNeeded(sessionID: sessionID)
        var list = todosBySession[sessionID] ?? []
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        let current = list[idx]
        list[idx] = TodoItemData(id: current.id, title: title ?? current.title, status: status)
        todosBySession[sessionID] = list
        persistToFile(sessionID: sessionID, items: list)
        return true
    }

    public func clear(for sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        todosBySession.removeValue(forKey: sessionID)
        let url = fileURL(for: sessionID)
        try? FileManager.default.removeItem(at: url)
        fileTimestamps.removeValue(forKey: sessionID)
    }
}
