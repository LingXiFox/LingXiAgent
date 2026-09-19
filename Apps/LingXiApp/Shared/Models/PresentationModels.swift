#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine

// MARK: - Attachment Presentation (抽象附件契约，杜绝直接暴露本地路径)

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

public enum TimelineItemKind: Sendable, Equatable {
    case user(content: String, attachments: [AttachmentPresentation])
    case thinking(content: String, isExpanded: Bool)
    case assistant(content: String, isStreaming: Bool)
    case tool(callID: String, toolName: String, summary: String, status: String)
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

// MARK: - Session Item Presentation

public struct SessionItemPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let lastUpdated: Date
    public let messageCount: Int
    public let mode: String
    public let isActive: Bool

    public init(
        id: String,
        title: String,
        lastUpdated: Date = Date(),
        messageCount: Int = 0,
        mode: String = "build",
        isActive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lastUpdated = lastUpdated
        self.messageCount = messageCount
        self.mode = mode
        self.isActive = isActive
    }
}

// MARK: - Runtime Telemetry Presentation (P-Core, E-Core, Codebase Graph, Cache, Retrieval)

public struct RuntimeInspectorPresentation: Sendable, Equatable {
    // P-Core: Resident Working Set (Token 预算与上下文窗口保留)
    public var residentTokens: Int
    public var workingSetCapacity: Int
    public var contextWindowUsage: Double // 0.0 - 1.0

    // Codebase Graph: 语义图谱独立结构
    public var codebaseNodes: Int
    public var codebaseEdges: Int

    // E-Core: 短时记忆与热度
    public var ecoreHeat: Double // 0.0 - 1.0

    // Provider & Cache
    public var cacheHitRatio: Double // 0.0 - 1.0
    public var tokensPerSecond: Double

    // Services
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

// MARK: - Domain Presentation Models (ObservableObject isolated domains on MainActor)

@MainActor
public final class SidebarPresentationModel: ObservableObject {
    @Published public var sessions: [SessionItemPresentation] = []
    @Published public var selectedSessionID: String?
    @Published public var workspace: WorkspaceSummaryPresentation

    public init(
        sessions: [SessionItemPresentation] = [],
        selectedSessionID: String? = nil,
        workspace: WorkspaceSummaryPresentation = WorkspaceSummaryPresentation(name: "LingXiAgent")
    ) {
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
        self.workspace = workspace
    }
}

@MainActor
public final class ConversationPresentationModel: ObservableObject {
    @Published public var sessionID: String = ""
    @Published public var items: [TimelineItemPresentation] = []
    @Published public var isGenerating: Bool = false

    private var streamingBuffer: String = ""
    private var lastCoalescedPublishTime: Date = Date.distantPast
    private let coalesceInterval: TimeInterval = 0.04 // 40ms 合批刷新阈值
    private var flushTask: Task<Void, Never>? = nil

    public init(sessionID: String = "", items: [TimelineItemPresentation] = []) {
        self.sessionID = sessionID
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
            // 启动 40ms 兜底定时器，流暂停时也能自动刷新已缓冲 token，绝不无限挂起 (Audit Round 10 Phase F)
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
    @Published public var telemetry: RuntimeInspectorPresentation = RuntimeInspectorPresentation()
    @Published public var isExpanded: Bool = true

    public init(telemetry: RuntimeInspectorPresentation = RuntimeInspectorPresentation()) {
        self.telemetry = telemetry
    }
}

@MainActor
public final class ComposerModel: ObservableObject {
    @Published public var text: String = ""
    @Published public var selectedMode: String = "build"
    @Published public var attachments: [AttachmentPresentation] = []
    @Published public var isSubmitting: Bool = false

    public init(text: String = "", selectedMode: String = "build") {
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
