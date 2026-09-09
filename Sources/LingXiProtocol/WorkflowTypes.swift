import Foundation

public struct WorkflowID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WorkflowTaskID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DecisionID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum WorkflowStatus: String, Sendable, Equatable, Codable {
    case pending, running, waitingForUser, completed, failed, cancelled, recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

public enum WorkflowTaskStatus: String, Sendable, Equatable, Codable {
    case pending, running, waitingForQuestion, waitingForPermission, waitingForDecision
    case completed, failed, cancelled, timedOut, blocked, recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .blocked: true
        default: false
        }
    }
}

public enum WorkflowTaskKind: String, Sendable, Equatable, Codable {
    case agent
    case decision
}

/// Immutable task definition. Agent input is explicit so sibling sessions never inherit each other's context.
public struct WorkflowTaskDefinition: Sendable, Equatable, Codable {
    public let id: WorkflowTaskID
    public let title: String?
    public let kind: WorkflowTaskKind
    public let task: String
    public let dependencies: [WorkflowTaskID]
    public let role: String?
    public let instructions: String?
    public let context: String?
    public let modelSelection: ModelSelection?
    public let executionProfile: SubagentExecutionProfile?

    public init(id: WorkflowTaskID, title: String? = nil, kind: WorkflowTaskKind = .agent, task: String, dependencies: [WorkflowTaskID] = [], role: String? = nil, instructions: String? = nil, context: String? = nil, modelSelection: ModelSelection? = nil, executionProfile: SubagentExecutionProfile? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.task = task
        self.dependencies = dependencies
        self.role = role
        self.instructions = instructions
        self.context = context
        self.modelSelection = modelSelection
        self.executionProfile = executionProfile
    }
}

public struct WorkflowTaskProvenance: Sendable, Equatable, Codable {
    public let parentSessionID: SessionID
    public let parentRunID: AgentRunID
    public let childSessionID: SessionID?
    public let childRunID: AgentRunID?

    public init(parentSessionID: SessionID, parentRunID: AgentRunID, childSessionID: SessionID? = nil, childRunID: AgentRunID? = nil) {
        self.parentSessionID = parentSessionID
        self.parentRunID = parentRunID
        self.childSessionID = childSessionID
        self.childRunID = childRunID
    }
}

public struct WorkflowCheckpoint: Sendable, Equatable, Codable {
    public let sequence: Int
    public let taskID: WorkflowTaskID?
    public let label: String
    public let createdAt: Date

    public init(sequence: Int, taskID: WorkflowTaskID? = nil, label: String, createdAt: Date = .now) {
        self.sequence = sequence
        self.taskID = taskID
        self.label = label
        self.createdAt = createdAt
    }
}

public struct DecisionRequest: Sendable, Equatable, Codable {
    public let decisionID: DecisionID
    public let question: String
    public let options: [String]
    public let originSessionID: SessionID
    public let originRunID: AgentRunID

    public init(decisionID: DecisionID, question: String, options: [String], originSessionID: SessionID, originRunID: AgentRunID) {
        self.decisionID = decisionID
        self.question = question
        self.options = options
        self.originSessionID = originSessionID
        self.originRunID = originRunID
    }
}

public enum WorkflowPendingInput: Sendable, Equatable, Codable {
    case question(QuestionRequest)
    case permission(PermissionRequest)
    case decision(DecisionRequest)
}

public struct WorkflowTaskState: Sendable, Equatable, Codable {
    public let definition: WorkflowTaskDefinition
    public let status: WorkflowTaskStatus
    public let provenance: WorkflowTaskProvenance?
    public let result: SubagentResult?
    public let pendingInput: WorkflowPendingInput?
    public let error: CoreError?

    public init(definition: WorkflowTaskDefinition, status: WorkflowTaskStatus = .pending, provenance: WorkflowTaskProvenance? = nil, result: SubagentResult? = nil, pendingInput: WorkflowPendingInput? = nil, error: CoreError? = nil) {
        self.definition = definition
        self.status = status
        self.provenance = provenance
        self.result = result
        self.pendingInput = pendingInput
        self.error = error
    }
}

/// Complete durable workflow fact. A checkpoint is committed with every state transition.
public struct WorkflowSnapshot: Sendable, Equatable, Codable {
    public let id: WorkflowID
    public let rootSessionID: SessionID
    public let rootRunID: AgentRunID
    public let status: WorkflowStatus
    public let tasks: [WorkflowTaskState]
    public let checkpoint: WorkflowCheckpoint
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: WorkflowID, rootSessionID: SessionID, rootRunID: AgentRunID, status: WorkflowStatus = .pending, tasks: [WorkflowTaskState], checkpoint: WorkflowCheckpoint = WorkflowCheckpoint(sequence: 0, label: "created"), createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.rootSessionID = rootSessionID
        self.rootRunID = rootRunID
        self.status = status
        self.tasks = tasks
        self.checkpoint = checkpoint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TodoItemData: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String // pending, in_progress, completed, failed
    public init(id: String, title: String, status: String = "pending") {
        self.id = id
        self.title = title
        self.status = status
    }
}

public final class TodoStore: @unchecked Sendable {
    public static let shared = TodoStore()
    private let lock = NSLock()
    private var todosBySession: [String: [TodoItemData]] = [:]
    private var fileTimestamps: [String: Date] = [:]
    private let storageDir: URL

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".lingxiagent/cache/todos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageDir = dir
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

