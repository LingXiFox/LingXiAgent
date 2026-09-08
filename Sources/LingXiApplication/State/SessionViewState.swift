import Foundation
import LingXiProtocol
import LingXiClient

/// 单个会话的产品级视图状态。
/// 汇聚 Timeline、Thinking、Assistant、Tool、HITL、Subagent 与 Context 投影。
public struct SessionViewState: Sendable, Equatable {
    public var sessionID: SessionID
    public var title: String?
    public var mode: AgentMode
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Turns & Runs
    public var turns: [TurnID: TurnSnapshot]
    public var turnOrder: [TurnID]
    public var activeTurnID: TurnID?
    public var queuedTurns: [TurnID]

    public var runs: [RunID: RunSnapshot]
    public var activeRootRunID: RunID?
    public var activeSubagentRunIDs: Set<RunID>

    // MARK: - Timeline Projection (Strict Semantic Order)
    public var timelineNodes: [TimelineNode]
    public var committedNodes: [TimelineNode]
    public var activeCell: TimelineNode?
    private var timelineIndexByID: [TimelineNodeID: Int]
    var messageIDByStream: [StreamID: MessageID]
    var thinkingStepIDByStream: [StreamID: ModelStepID]
    var toolCallIDByStream: [StreamID: ToolCallID]

    // MARK: - Thinking Projection
    public var thinkingNodes: [ModelStepID: ThinkingNode]
    public var activeThinkingStepID: ModelStepID?

    // MARK: - Tool Lifecycle Projection
    public var toolNodes: [ToolCallID: ToolNode]
    public var activeToolCallIDs: Set<ToolCallID>

    // MARK: - Human-In-The-Loop (HITL)
    public var pendingInteractions: [InteractionSnapshot]
    public var activeInteraction: InteractionSnapshot?
    public var permissionConfiguration: PermissionConfiguration

    // MARK: - Subagent Projection
    public var subagents: [RunID: SubagentNode]

    // MARK: - Context State
    public var contextState: ContextStateSnapshot?
    public var contextPolicy: ContextPolicySnapshot?
    public var contextCompacted: ContextCompactedSnapshot?
    public var isPaging: Bool

    // MARK: - Provider Request State
    public var activeProviderRequestID: ProviderRequestID?
    public var activeProviderRequestState: ProviderRequestState?

    // MARK: - Status
    public var hasActiveError: Bool
    public var status: ProductRuntimeStatus
    public var reasoningEffort: ReasoningEffort

    public init(
        sessionID: SessionID,
        title: String? = nil,
        mode: AgentMode = .build,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        reasoningEffort: ReasoningEffort = .auto
    ) {
        self.sessionID = sessionID
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reasoningEffort = reasoningEffort
        self.turns = [:]
        self.turnOrder = []
        self.activeTurnID = nil
        self.queuedTurns = []
        self.runs = [:]
        self.activeRootRunID = nil
        self.activeSubagentRunIDs = []
        self.timelineNodes = []
        self.committedNodes = []
        self.activeCell = nil
        self.timelineIndexByID = [:]
        self.messageIDByStream = [:]
        self.thinkingStepIDByStream = [:]
        self.toolCallIDByStream = [:]
        self.thinkingNodes = [:]
        self.activeThinkingStepID = nil
        self.toolNodes = [:]
        self.activeToolCallIDs = []
        self.pendingInteractions = []
        self.activeInteraction = nil
        self.permissionConfiguration = .askWorkspace
        self.subagents = [:]
        self.contextState = nil
        self.contextPolicy = nil
        self.contextCompacted = nil
        self.isPaging = false
        self.activeProviderRequestID = nil
        self.activeProviderRequestState = nil
        self.hasActiveError = false
        self.status = .ready
    }

    // MARK: - Timeline Helpers
    public func node(for id: TimelineNodeID) -> TimelineNode? {
        guard let index = timelineIndexByID[id], index < timelineNodes.count else { return nil }
        return timelineNodes[index]
    }

    public mutating func appendNode(_ node: TimelineNode) {
        if let existingIndex = timelineIndexByID[node.id] {
            timelineNodes[existingIndex] = node
        } else {
            timelineIndexByID[node.id] = timelineNodes.count
            timelineNodes.append(node)
        }
    }

    public mutating func updateNode(id: TimelineNodeID, mutate: (inout TimelineNode) -> Void) {
        guard let index = timelineIndexByID[id], index < timelineNodes.count else { return }
        mutate(&timelineNodes[index])
    }

    public mutating func updateActiveCell(_ node: TimelineNode) {
        self.activeCell = node
        appendNode(node)
    }

    public mutating func commitActiveCell() {
        guard let cell = activeCell else { return }
        appendCommittedNode(cell)
        activeCell = nil
    }

    public mutating func appendCommittedNode(_ node: TimelineNode) {
        appendNode(node)
        if let cIdx = committedNodes.firstIndex(where: { $0.id == node.id }) {
            committedNodes[cIdx] = node
        } else {
            committedNodes.append(node)
        }
        if activeCell?.id == node.id {
            activeCell = nil
        }
    }

    public mutating func recalculateStatus(connectionState: ConnectionState) {
        let hasRunningTools = toolNodes.values.contains {
            switch $0.phase {
            case .requested, .waitingPermission, .scheduled, .running: true
            case .completed, .failed, .cancelled: false
            }
        }
        let hasThinking = activeThinkingStepID.map { thinkingNodes[$0]?.isStreaming == true || thinkingNodes[$0]?.isComplete == false } ?? false
        self.status = ProductStatusProjector.projectStatus(
            connectionState: connectionState,
            activeInteraction: activeInteraction,
            pendingInteractions: pendingInteractions,
            providerRequestState: activeProviderRequestState,
            activeSubagentsCount: activeSubagentRunIDs.count,
            hasRunningTools: hasRunningTools,
            hasActiveThinking: hasThinking,
            isPaging: isPaging,
            hasActiveError: hasActiveError
        )
    }
}
