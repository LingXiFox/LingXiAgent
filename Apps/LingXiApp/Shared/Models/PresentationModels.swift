import Foundation
import SwiftUI
import Combine
import LingXiProtocol

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

// MARK: - Runtime Telemetry Presentation (P-Core, E-Core, Cache, Retrieval)

public struct RuntimeInspectorPresentation: Sendable, Equatable {
    public var pcoreNodes: Int
    public var pcoreEdges: Int
    public var ecoreHeat: Double // 0.0 - 1.0
    public var cacheHitRatio: Double // 0.0 - 1.0
    public var tokensPerSecond: Double
    public var retrievalWarmup: String
    public var activeMCPCount: Int
    public var activeBackgroundTasks: Int

    public init(
        pcoreNodes: Int = 1250,
        pcoreEdges: Int = 3480,
        ecoreHeat: Double = 0.42,
        cacheHitRatio: Double = 0.78,
        tokensPerSecond: Double = 54.2,
        retrievalWarmup: String = "ready",
        activeMCPCount: Int = 4,
        activeBackgroundTasks: Int = 0
    ) {
        self.pcoreNodes = pcoreNodes
        self.pcoreEdges = pcoreEdges
        self.ecoreHeat = ecoreHeat
        self.cacheHitRatio = cacheHitRatio
        self.tokensPerSecond = tokensPerSecond
        self.retrievalWarmup = retrievalWarmup
        self.activeMCPCount = activeMCPCount
        self.activeBackgroundTasks = activeBackgroundTasks
    }
}

// MARK: - Domain Presentation Models (ObservableObject isolated domains)

public final class SidebarPresentationModel: ObservableObject, @unchecked Sendable {
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

public final class ConversationPresentationModel: ObservableObject, @unchecked Sendable {
    @Published public var sessionID: String = ""
    @Published public var items: [TimelineItemPresentation] = []
    @Published public var isGenerating: Bool = false

    public init(sessionID: String = "", items: [TimelineItemPresentation] = []) {
        self.sessionID = sessionID
        self.items = items
    }

    public func appendOrUpdateStreamingChunk(chunk: String) {
        if let lastIndex = items.indices.last, case .assistant(let existing, _) = items[lastIndex].kind {
            items[lastIndex].kind = .assistant(content: existing + chunk, isStreaming: true)
        } else {
            items.append(TimelineItemPresentation(kind: .assistant(content: chunk, isStreaming: true)))
        }
    }

    public func finalizeStreaming() {
        if let lastIndex = items.indices.last, case .assistant(let text, _) = items[lastIndex].kind {
            items[lastIndex].kind = .assistant(content: text, isStreaming: false)
        }
        isGenerating = false
    }
}

public final class RuntimeInspectorPresentationModel: ObservableObject, @unchecked Sendable {
    @Published public var telemetry: RuntimeInspectorPresentation = RuntimeInspectorPresentation()
    @Published public var isExpanded: Bool = true

    public init(telemetry: RuntimeInspectorPresentation = RuntimeInspectorPresentation()) {
        self.telemetry = telemetry
    }
}

public final class ComposerModel: ObservableObject, @unchecked Sendable {
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
