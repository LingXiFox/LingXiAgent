#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine
import LingXiProtocol
import LingXiApplication

// MARK: - Attachment Presentation

public struct AttachmentPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let mediaType: String
    public let byteCount: Int
    public let thumbnailSymbol: String
    public let isUploaded: Bool

    public init(
        id: String = UUID().uuidString,
        filename: String,
        mediaType: String,
        byteCount: Int,
        thumbnailSymbol: String = "doc.text",
        isUploaded: Bool = true
    ) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.thumbnailSymbol = thumbnailSymbol
        self.isUploaded = isUploaded
    }

    public var formattedSize: String {
        let kb = Double(byteCount) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

// MARK: - Workspace Presentation

public struct WorkspaceSummaryPresentation: Sendable, Equatable {
    public let name: String
    public let rootBadge: String
    public let isRemote: Bool
    public let gitBranch: String?
    public let worktreeBranch: String?
    public let indexingState: String

    public init(
        name: String,
        rootBadge: String = "local",
        isRemote: Bool = false,
        gitBranch: String? = nil,
        worktreeBranch: String? = nil,
        indexingState: String = "ready"
    ) {
        self.name = name
        self.rootBadge = rootBadge
        self.isRemote = isRemote
        self.gitBranch = gitBranch
        self.worktreeBranch = worktreeBranch
        self.indexingState = indexingState
    }
}

// MARK: - Timeline Item Presentation

public enum InteractionStatus: String, Sendable, Equatable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

/// What the agent is asking the user for.
public enum InteractionCardKind: String, Sendable, Equatable {
    case permission, question, decision
}

/// One pending or resolved human-in-the-loop request (permission, question or decision).
public struct InteractionCardPresentation: Sendable, Equatable, Identifiable {
    public var id: String { interactionID }
    public let interactionID: String
    public let agentRunID: String
    public var kind: InteractionCardKind
    /// Tool for a permission request; empty for questions.
    public let toolName: String
    /// Verbatim command / arguments for permissions; question text for questions.
    public let parametersSummary: String
    /// Target resource (path, host, process) of a permission request.
    public var resource: String
    /// Capability kinds the permission would grant (e.g. `processExecution`).
    public var capabilities: [String]
    public var options: [String]
    public var allowsMultiple: Bool
    public var allowsFreeText: Bool
    public var status: InteractionStatus

    public init(
        interactionID: String,
        agentRunID: String = "main",
        kind: InteractionCardKind = .permission,
        toolName: String,
        parametersSummary: String,
        resource: String = "",
        capabilities: [String] = [],
        options: [String] = [],
        allowsMultiple: Bool = false,
        allowsFreeText: Bool = false,
        status: InteractionStatus = .pending
    ) {
        self.interactionID = interactionID
        self.agentRunID = agentRunID
        self.kind = kind
        self.toolName = toolName
        self.parametersSummary = parametersSummary
        self.resource = resource
        self.capabilities = capabilities
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
        self.status = status
    }
}

/// One tool call and its result, aggregated under a single call ID.
public struct ToolCallPresentation: Sendable, Equatable {
    public let callID: String
    public let toolName: String
    /// Main argument in one line: path, command, pattern or URL.
    public var summary: String
    /// waiting / running / completed / failed / cancelled
    public var status: String
    /// Result summary or stdout tail, capped for display.
    public var output: String?
    public var stderr: String?
    public var durationMs: Double?
    public var exitCode: Int?
    public var workingDirectory: String?

    public init(callID: String, toolName: String, summary: String, status: String,
                output: String? = nil, stderr: String? = nil, durationMs: Double? = nil,
                exitCode: Int? = nil, workingDirectory: String? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.output = output
        self.stderr = stderr
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.workingDirectory = workingDirectory
    }
}

/// Subagent lifecycle marker in the main timeline (the full tree lives in the inspector).
public struct SubagentEventPresentation: Sendable, Equatable {
    public let runID: String
    public let parentRunID: String
    public var status: String
    public var terminalReason: String?

    public init(runID: String, parentRunID: String, status: String, terminalReason: String? = nil) {
        self.runID = runID
        self.parentRunID = parentRunID
        self.status = status
        self.terminalReason = terminalReason
    }
}

/// Runtime condition that affects the task: provider failure, retry, rate limit,
/// compaction, recovery. Routine metrics never become notices.
public struct NoticePresentation: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable { case info, warning, error }
    public let level: Level
    public let title: String
    public let message: String

    public init(level: Level, title: String, message: String) {
        self.level = level
        self.title = title
        self.message = message
    }
}

public enum TimelineItemKind: Sendable, Equatable {
    case user(content: String, attachments: [AttachmentPresentation], messageID: String? = nil, turnID: String? = nil, sessionID: String? = nil)
    case thinking(content: String, isExpanded: Bool, durationSeconds: Double, tokenCount: Int)
    case assistant(content: String, isStreaming: Bool)
    case tool(ToolCallPresentation)
    case interaction(card: InteractionCardPresentation)
    case diff(filePath: String, diffContent: String)
    case subagent(SubagentEventPresentation)
    case notice(NoticePresentation)
    case terminal(title: String, isSuccess: Bool, message: String)
}

public struct TimelineItemPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public var kind: TimelineItemKind

    public init(id: String = UUID().uuidString, timestamp: Date = Date(), kind: TimelineItemKind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }
}

// MARK: - Task Presentation (TaskCapsule Frontend Projection)

public enum TaskStageViewTab: String, Sendable, CaseIterable {
    case plan = "Plan"
    case actionFlow = "Action Flow"
    case report = "Final Report"

    /// 界面标签按规范第五章术语表取中文，rawValue 保持协议侧英文标识。
    public var displayName: String {
        switch self {
        case .plan: return "计划"
        case .actionFlow: return "执行"
        case .report: return "报告"
        }
    }
}

public struct TaskPresentation: Identifiable, Sendable, Equatable {
    public var id: String { taskID }
    public let taskID: String
    public var objective: String
    public var state: String // queued, running, paused, waiting, completed, failed
    public var criteria: [SuccessCriterion]
    public var artifacts: [TaskArtifact]
    public var worktreeBranch: String?
    public var report: TaskReport?
    public var plan: TaskPlan?

    public init(
        taskID: String = UUID().uuidString,
        objective: String,
        state: String = "running",
        criteria: [SuccessCriterion] = [],
        artifacts: [TaskArtifact] = [],
        worktreeBranch: String? = nil,
        report: TaskReport? = nil,
        plan: TaskPlan? = nil
    ) {
        self.taskID = taskID
        self.objective = objective
        self.state = state
        self.criteria = criteria
        self.artifacts = artifacts
        self.worktreeBranch = worktreeBranch
        self.report = report
        self.plan = plan
    }
}

// MARK: - Session Item Presentation

public struct SessionItemPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let lastUpdated: Date
    public var messageCount: Int
    public var mode: String
    public var isActive: Bool
    public var tasks: [TaskPresentation]

    public init(
        id: String,
        title: String,
        lastUpdated: Date = Date(),
        messageCount: Int = 0,
        mode: String = "build",
        isActive: Bool = false,
        tasks: [TaskPresentation] = []
    ) {
        self.id = id
        self.title = title
        self.lastUpdated = lastUpdated
        self.messageCount = messageCount
        self.mode = mode
        self.isActive = isActive
        self.tasks = tasks
    }
}

// MARK: - Directory Group Folder Presentation

public struct SessionFolderPresentation: Identifiable, Sendable, Equatable {
    public var id: String { folderName }
    public let folderName: String
    public var sessions: [SessionItemPresentation]

    public init(folderName: String, sessions: [SessionItemPresentation] = []) {
        self.folderName = folderName
        self.sessions = sessions
    }
}



public enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case core = "Core"
    case tasks = "Tasks"
    case agents = "Agents"
    case changes = "Changes"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: return "概览"
        case .core: return "Core"
        case .tasks: return "任务"
        case .agents: return "Agent"
        case .changes: return "变更"
        }
    }
}

public struct TraceEventItemPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let eventType: String
    public let module: String
    public let durationMs: Int
    public let status: String

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        eventType: String,
        module: String,
        durationMs: Int = 0,
        status: String = "ok"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.module = module
        self.durationMs = durationMs
        self.status = status
    }
}

// MARK: - Domain Presentation Models (ObservableObject)

@MainActor
public final class SidebarPresentationModel: ObservableObject {
    @Published public var folders: [SessionFolderPresentation] = []
    @Published public var selectedSessionID: String?
    @Published public var selectedTaskID: String?
    @Published public var searchText: String = ""
    @Published public var workspace: WorkspaceSummaryPresentation
    /// Floating navigator panel visibility (⌃⌘S).
    @Published public var isNavigatorVisible: Bool = true

    public init(
        folders: [SessionFolderPresentation] = [],
        selectedSessionID: String? = nil,
        selectedTaskID: String? = nil,
        workspace: WorkspaceSummaryPresentation = WorkspaceSummaryPresentation(name: "LingXiAgent")
    ) {
        self.folders = folders
        self.selectedSessionID = selectedSessionID
        self.selectedTaskID = selectedTaskID
        self.workspace = workspace
    }

    public var allSessions: [SessionItemPresentation] {
        folders.flatMap(\.sessions)
    }
}

@MainActor
public final class ConversationPresentationModel: ObservableObject {
    @Published public var sessionID: String = ""
    @Published public var activeTask: TaskPresentation?
    @Published public var stageTab: TaskStageViewTab = .actionFlow
    @Published public var items: [TimelineItemPresentation] = []
    @Published public var isGenerating: Bool = false

    private var streamingBuffer: String = ""
    private var lastCoalescedPublishTime: Date = Date.distantPast
    private let coalesceInterval: TimeInterval = 0.04
    private var flushTask: Task<Void, Never>? = nil

    public init(
        sessionID: String = "",
        activeTask: TaskPresentation? = nil,
        stageTab: TaskStageViewTab = .actionFlow,
        items: [TimelineItemPresentation] = []
    ) {
        self.sessionID = sessionID
        self.activeTask = activeTask
        self.stageTab = stageTab
        self.items = items
    }

    public func appendOrUpdateStreamingChunk(chunk: String) {
        streamingBuffer.append(chunk)
        let now = Date()
        if now.timeIntervalSince(lastCoalescedPublishTime) >= coalesceInterval {
            flushTask?.cancel()
            flushTask = nil
            flushStreamingBuffer()
            lastCoalescedPublishTime = now
        } else if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled, let self else { return }
                self.flushStreamingBuffer()
                self.lastCoalescedPublishTime = Date()
                self.flushTask = nil
            }
        }
    }

    public func flushStreamingBuffer() {
        flushTask?.cancel()
        flushTask = nil
        guard !streamingBuffer.isEmpty else { return }
        let flushedText = streamingBuffer
        streamingBuffer = ""
        if let lastIndex = items.indices.last, case .assistant(let existing, _) = items[lastIndex].kind {
            items[lastIndex].kind = .assistant(content: existing + flushedText, isStreaming: true)
        } else {
            items.append(TimelineItemPresentation(kind: .assistant(content: flushedText, isStreaming: true)))
        }
    }

    public func finalizeStreaming() {
        flushTask?.cancel()
        flushTask = nil
        flushStreamingBuffer()
        if let lastIndex = items.indices.last, case .assistant(let text, _) = items[lastIndex].kind {
            items[lastIndex].kind = .assistant(content: text, isStreaming: false)
        }
        isGenerating = false
    }
}

@MainActor
public final class RuntimeInspectorPresentationModel: ObservableObject {
    @Published public var selectedTab: InspectorTab = .overview
    /// Live runtime state; nil while no Core is connected (the inspector says so).
    @Published public var live: InspectorSnapshot?
    @Published public var traceEvents: [TraceEventItemPresentation] = []
    @Published public var isPresented: Bool = true

    public init() {}
}

/// Everything the inspector shows, taken from `ApplicationState` in one pass.
public struct InspectorSnapshot: Equatable, Sendable {
    // Overview
    public var status: ProductRuntimeStatus
    public var runStartedAt: Date?
    public var modelID: String?
    public var reasoning: String
    public var permission: String
    public var providerState: ProviderRequestState?
    public var providerDetail: String?
    public var lastMetrics: MessageMetrics?
    public var activeTools: [String]
    public var pendingInteraction: String?
    public var health: RuntimeHealth?
    // Core
    public var context: ContextStateSnapshot?
    public var contextPolicy: ContextPolicySnapshot?
    public var compaction: ContextCompactedSnapshot?
    // Tasks
    public var todos: [TodoItemData]
    public var workflows: [WorkflowSnapshot]
    public var backgroundTasks: [BackgroundTaskSnapshot]
    // Agents
    public var rootRun: RunSnapshot?
    public var subagents: [SubagentRowPresentation]
    // Changes
    public var changes: [FileChangePresentation]
    public var diffLoaded: Bool
    public var branch: String?
    public var workspaceRoot: String?

    public init(status: ProductRuntimeStatus = .disconnected, runStartedAt: Date? = nil, modelID: String? = nil,
                reasoning: String = "auto", permission: String = "", providerState: ProviderRequestState? = nil,
                providerDetail: String? = nil, lastMetrics: MessageMetrics? = nil, activeTools: [String] = [],
                pendingInteraction: String? = nil, health: RuntimeHealth? = nil,
                context: ContextStateSnapshot? = nil, contextPolicy: ContextPolicySnapshot? = nil,
                compaction: ContextCompactedSnapshot? = nil, todos: [TodoItemData] = [],
                workflows: [WorkflowSnapshot] = [], backgroundTasks: [BackgroundTaskSnapshot] = [],
                rootRun: RunSnapshot? = nil, subagents: [SubagentRowPresentation] = [],
                changes: [FileChangePresentation] = [], diffLoaded: Bool = false,
                branch: String? = nil, workspaceRoot: String? = nil) {
        self.status = status; self.runStartedAt = runStartedAt; self.modelID = modelID
        self.reasoning = reasoning; self.permission = permission; self.providerState = providerState
        self.providerDetail = providerDetail; self.lastMetrics = lastMetrics; self.activeTools = activeTools
        self.pendingInteraction = pendingInteraction; self.health = health
        self.context = context; self.contextPolicy = contextPolicy; self.compaction = compaction
        self.todos = todos; self.workflows = workflows; self.backgroundTasks = backgroundTasks
        self.rootRun = rootRun; self.subagents = subagents
        self.changes = changes; self.diffLoaded = diffLoaded; self.branch = branch; self.workspaceRoot = workspaceRoot
    }
}

public struct SubagentRowPresentation: Identifiable, Equatable, Sendable {
    public var id: String { runID }
    public let runID: String
    public let parentRunID: String
    public var status: String
    public var model: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var terminalReason: String?
}

@MainActor
public final class ComposerModel: ObservableObject {
    @Published public var text: String = ""
    @Published public var selectedMode: AgentRunMode = .build
    @Published public var reasoningEffort: ReasoningEffortLevel = .auto
    @Published public var permissionPreset: PermissionPreset = .askWorkspace
    @Published public var attachments: [AttachmentPresentation] = []
    @Published public var isSubmitting: Bool = false
    /// Models Core discovered; the picker lists configured ones only.
    @Published public var models: [ProviderModelInfo] = []
    @Published public var selectedModelID: String?
    /// Active goal set through `/goal`; nil when none.
    @Published public var goal: String?

    public init(text: String = "", selectedMode: AgentRunMode = .build) {
        self.text = text
        self.selectedMode = selectedMode
    }

    public func clear() {
        text = ""
        attachments.removeAll()
        isSubmitting = false
    }

    /// Reasoning levels the selected model can honour (all of them when unknown).
    public var availableReasoningLevels: [ReasoningEffortLevel] {
        guard let id = selectedModelID, let model = models.first(where: { $0.modelID == id }) else {
            return ReasoningEffortLevel.allCases
        }
        return model.reasoning ? ReasoningEffortLevel.allCases : [.auto, .off]
    }

    private var hasAppliedDefaults = false

    /// Seeds per-task controls from the global defaults once; later changes in
    /// the composer are the user's per-task choice and are not overwritten.
    public func applyDefaults(mode: AgentRunMode, reasoning: ReasoningEffortLevel, permission: PermissionPreset) {
        guard !hasAppliedDefaults else { return }
        hasAppliedDefaults = true
        selectedMode = mode
        reasoningEffort = reasoning
        permissionPreset = permission
    }
}
#endif
