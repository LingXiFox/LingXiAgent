#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine
import LingXiProtocol

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
    public let indexingState: String

    public init(
        name: String,
        rootBadge: String = "local",
        isRemote: Bool = false,
        gitBranch: String? = nil,
        indexingState: String = "ready"
    ) {
        self.name = name
        self.rootBadge = rootBadge
        self.isRemote = isRemote
        self.gitBranch = gitBranch
        self.indexingState = indexingState
    }
}

// MARK: - Timeline Item Presentation

public enum InteractionStatus: String, Sendable, Equatable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

public struct InteractionCardPresentation: Sendable, Equatable, Identifiable {
    public var id: String { interactionID }
    public let interactionID: String
    public let agentRunID: String
    public let toolName: String
    public let parametersSummary: String
    public var status: InteractionStatus

    public init(
        interactionID: String,
        agentRunID: String = "main",
        toolName: String,
        parametersSummary: String,
        status: InteractionStatus = .pending
    ) {
        self.interactionID = interactionID
        self.agentRunID = agentRunID
        self.toolName = toolName
        self.parametersSummary = parametersSummary
        self.status = status
    }
}

public enum TimelineItemKind: Sendable, Equatable {
    case user(content: String, attachments: [AttachmentPresentation])
    case thinking(content: String, isExpanded: Bool, durationSeconds: Double, tokenCount: Int)
    case assistant(content: String, isStreaming: Bool)
    case tool(callID: String, toolName: String, summary: String, status: String, output: String?)
    case interaction(card: InteractionCardPresentation)
    case diff(filePath: String, diffContent: String)
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

// MARK: - Legacy / Telemetry Diagnostic Presentation (Internal Testing & Compatibility)

public struct RuntimeInspectorPresentation: Sendable, Equatable {
    public var residentTokens: Int
    public var workingSetCapacity: Int
    public var contextWindowUsage: Double
    public var codebaseNodes: Int
    public var codebaseEdges: Int
    public var ecoreHeat: Double
    public var cacheHitRatio: Double
    public var tokensPerSecond: Double
    public var retrievalWarmup: String
    public var activeMCPCount: Int
    public var activeBackgroundTasks: Int

    public init(
        residentTokens: Int = 48200,
        workingSetCapacity: Int = 128000,
        contextWindowUsage: Double = 0.38,
        codebaseNodes: Int = 1250,
        codebaseEdges: Int = 3480,
        ecoreHeat: Double = 0.42,
        cacheHitRatio: Double = 0.78,
        tokensPerSecond: Double = 54.2,
        retrievalWarmup: String = "ready",
        activeMCPCount: Int = 4,
        activeBackgroundTasks: Int = 0
    ) {
        self.residentTokens = residentTokens
        self.workingSetCapacity = workingSetCapacity
        self.contextWindowUsage = contextWindowUsage
        self.codebaseNodes = codebaseNodes
        self.codebaseEdges = codebaseEdges
        self.ecoreHeat = ecoreHeat
        self.cacheHitRatio = cacheHitRatio
        self.tokensPerSecond = tokensPerSecond
        self.retrievalWarmup = retrievalWarmup
        self.activeMCPCount = activeMCPCount
        self.activeBackgroundTasks = activeBackgroundTasks
    }
}

// MARK: - High-Level Inspector Presentation (Aesthetic First: Context Health Gauge, Success Criteria, Artifacts)


public struct ContextHealthPresentation: Sendable, Equatable {
    public var usedTokens: Int
    public var maxTokens: Int
    public var healthPercentage: Double // 0.0 ~ 1.0

    public init(usedTokens: Int = 48_200, maxTokens: Int = 128_000) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.healthPercentage = maxTokens > 0 ? Double(usedTokens) / Double(maxTokens) : 0.0
    }

    public var formattedTokens: String {
        let usedK = Double(usedTokens) / 1000.0
        let maxK = Double(maxTokens) / 1000.0
        return String(format: "%.1fk / %.0fk", usedK, maxK)
    }
}

public enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case agent = "Agent"
    case tasks = "Tasks"
    case capabilities = "Capabilities"

    public var id: String { rawValue }
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
    @Published public var workspace: WorkspaceSummaryPresentation

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
    @Published public var contextHealth: ContextHealthPresentation = ContextHealthPresentation()
    @Published public var criteria: [SuccessCriterion] = []
    @Published public var artifacts: [TaskArtifact] = []
    @Published public var currentPreset: AgentPresetInfo = AgentPresetInfo(id: "build", name: "Builder", description: "Default Builder", mode: .build)
    @Published public var activeGrants: [CapabilityGrant] = []
    @Published public var traceEvents: [TraceEventItemPresentation] = []
    @Published public var isPresented: Bool = true

    public init() {}
}

@MainActor
public final class ComposerModel: ObservableObject {
    @Published public var text: String = ""
    @Published public var selectedMode: AgentRunMode = .build
    @Published public var attachments: [AttachmentPresentation] = []
    @Published public var isSubmitting: Bool = false

    public init(text: String = "", selectedMode: AgentRunMode = .build) {
        self.text = text
        self.selectedMode = selectedMode
    }

    public func clear() {
        text = ""
        attachments.removeAll()
        isSubmitting = false
    }
}
#endif
