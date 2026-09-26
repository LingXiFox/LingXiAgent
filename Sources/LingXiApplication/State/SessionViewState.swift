import Foundation
import LingXiProtocol
import LingXiClient

/// 单个会话的产品级视图状态。
/// 汇聚 Timeline、Thinking、Assistant、Tool、HITL、Subagent 与 Context 投影。
public struct SessionViewState: Sendable, Equatable, Codable {
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

    // MARK: - Todos Projection
    public var todos: [TodoItemData]

    // MARK: - Context State
    public var contextState: ContextStateSnapshot?
    public var contextPolicy: ContextPolicySnapshot?
    public var contextCompacted: ContextCompactedSnapshot?
    public var isPaging: Bool

    // MARK: - Provider Request State
    public var activeProviderRequestID: ProviderRequestID?
    public var activeProviderRequestState: ProviderRequestState?
    public var activeProviderRequestDetail: String?
    public var activeProviderStatusCode: Int?

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
        self.todos = []
        self.contextState = nil
        self.contextPolicy = nil
        self.contextCompacted = nil
        self.isPaging = false
        self.activeProviderRequestID = nil
        self.activeProviderRequestState = nil
        self.activeProviderRequestDetail = nil
        self.activeProviderStatusCode = nil
        self.hasActiveError = false
        self.status = .ready
    }

    // MARK: - Coding
    //
    // The four derived lookups above are deliberately NOT part of the wire format:
    // `timelineIndexByID` is rebuilt from `timelineNodes` after decoding, and the three
    // `*IDByStream` maps are live-stream bookkeeping that only the reducers populate.
    // ID-keyed dictionaries are re-keyed to JSON objects on `rawValue` so remote
    // frontends never see Swift's flat `[key, value, key, value]` dictionary form.

    private enum CodingKeys: String, CodingKey {
        case sessionID, title, mode, createdAt, updatedAt
        case turns, turnOrder, activeTurnID, queuedTurns
        case runs, activeRootRunID, activeSubagentRunIDs
        case timelineNodes, committedNodes, activeCell
        case thinkingNodes, activeThinkingStepID
        case toolNodes, activeToolCallIDs
        case pendingInteractions, activeInteraction, permissionConfiguration
        case subagents, todos
        case contextState, contextPolicy, contextCompacted, isPaging
        case activeProviderRequestID, activeProviderRequestState
        case activeProviderRequestDetail, activeProviderStatusCode
        case hasActiveError, status, reasoningEffort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.mode = try c.decode(AgentMode.self, forKey: .mode)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.turns = try c.decodeIDMap(forKey: .turns) { TurnID($0) }
        self.turnOrder = try c.decode([TurnID].self, forKey: .turnOrder)
        self.activeTurnID = try c.decodeIfPresent(TurnID.self, forKey: .activeTurnID)
        self.queuedTurns = try c.decode([TurnID].self, forKey: .queuedTurns)
        self.runs = try c.decodeIDMap(forKey: .runs) { RunID($0) }
        self.activeRootRunID = try c.decodeIfPresent(RunID.self, forKey: .activeRootRunID)
        self.activeSubagentRunIDs = try c.decode(Set<RunID>.self, forKey: .activeSubagentRunIDs)
        self.timelineNodes = try c.decode([TimelineNode].self, forKey: .timelineNodes)
        self.committedNodes = try c.decode([TimelineNode].self, forKey: .committedNodes)
        self.activeCell = try c.decodeIfPresent(TimelineNode.self, forKey: .activeCell)
        self.thinkingNodes = try c.decodeIDMap(forKey: .thinkingNodes) { ModelStepID($0) }
        self.activeThinkingStepID = try c.decodeIfPresent(ModelStepID.self, forKey: .activeThinkingStepID)
        self.toolNodes = try c.decodeIDMap(forKey: .toolNodes) { ToolCallID($0) }
        self.activeToolCallIDs = try c.decode(Set<ToolCallID>.self, forKey: .activeToolCallIDs)
        self.pendingInteractions = try c.decode([InteractionSnapshot].self, forKey: .pendingInteractions)
        self.activeInteraction = try c.decodeIfPresent(InteractionSnapshot.self, forKey: .activeInteraction)
        self.permissionConfiguration = try c.decode(PermissionConfiguration.self, forKey: .permissionConfiguration)
        self.subagents = try c.decodeIDMap(forKey: .subagents) { RunID($0) }
        self.todos = try c.decode([TodoItemData].self, forKey: .todos)
        self.contextState = try c.decodeIfPresent(ContextStateSnapshot.self, forKey: .contextState)
        self.contextPolicy = try c.decodeIfPresent(ContextPolicySnapshot.self, forKey: .contextPolicy)
        self.contextCompacted = try c.decodeIfPresent(ContextCompactedSnapshot.self, forKey: .contextCompacted)
        self.isPaging = try c.decode(Bool.self, forKey: .isPaging)
        self.activeProviderRequestID = try c.decodeIfPresent(ProviderRequestID.self, forKey: .activeProviderRequestID)
        self.activeProviderRequestState = try c.decodeIfPresent(ProviderRequestState.self, forKey: .activeProviderRequestState)
        self.activeProviderRequestDetail = try c.decodeIfPresent(String.self, forKey: .activeProviderRequestDetail)
        self.activeProviderStatusCode = try c.decodeIfPresent(Int.self, forKey: .activeProviderStatusCode)
        self.hasActiveError = try c.decode(Bool.self, forKey: .hasActiveError)
        self.status = try c.decode(ProductRuntimeStatus.self, forKey: .status)
        self.reasoningEffort = try c.decode(ReasoningEffort.self, forKey: .reasoningEffort)
        // Derived caches: rebuilt so a decoded view state answers lookups exactly as a live one.
        self.timelineIndexByID = [:]
        self.messageIDByStream = [:]
        self.thinkingStepIDByStream = [:]
        self.toolCallIDByStream = [:]
        rebuildTimelineIndex()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(mode, forKey: .mode)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIDMap(turns, forKey: .turns, key: \.rawValue)
        try c.encode(turnOrder, forKey: .turnOrder)
        try c.encodeIfPresent(activeTurnID, forKey: .activeTurnID)
        try c.encode(queuedTurns, forKey: .queuedTurns)
        try c.encodeIDMap(runs, forKey: .runs, key: \.rawValue)
        try c.encodeIfPresent(activeRootRunID, forKey: .activeRootRunID)
        try c.encode(activeSubagentRunIDs, forKey: .activeSubagentRunIDs)
        try c.encode(timelineNodes, forKey: .timelineNodes)
        try c.encode(committedNodes, forKey: .committedNodes)
        try c.encodeIfPresent(activeCell, forKey: .activeCell)
        try c.encodeIDMap(thinkingNodes, forKey: .thinkingNodes, key: \.rawValue)
        try c.encodeIfPresent(activeThinkingStepID, forKey: .activeThinkingStepID)
        try c.encodeIDMap(toolNodes, forKey: .toolNodes, key: \.rawValue)
        try c.encode(activeToolCallIDs, forKey: .activeToolCallIDs)
        try c.encode(pendingInteractions, forKey: .pendingInteractions)
        try c.encodeIfPresent(activeInteraction, forKey: .activeInteraction)
        try c.encode(permissionConfiguration, forKey: .permissionConfiguration)
        try c.encodeIDMap(subagents, forKey: .subagents, key: \.rawValue)
        try c.encode(todos, forKey: .todos)
        try c.encodeIfPresent(contextState, forKey: .contextState)
        try c.encodeIfPresent(contextPolicy, forKey: .contextPolicy)
        try c.encodeIfPresent(contextCompacted, forKey: .contextCompacted)
        try c.encode(isPaging, forKey: .isPaging)
        try c.encodeIfPresent(activeProviderRequestID, forKey: .activeProviderRequestID)
        try c.encodeIfPresent(activeProviderRequestState, forKey: .activeProviderRequestState)
        try c.encodeIfPresent(activeProviderRequestDetail, forKey: .activeProviderRequestDetail)
        try c.encodeIfPresent(activeProviderStatusCode, forKey: .activeProviderStatusCode)
        try c.encode(hasActiveError, forKey: .hasActiveError)
        try c.encode(status, forKey: .status)
        try c.encode(reasoningEffort, forKey: .reasoningEffort)
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
        if let index = timelineIndexByID[id], index < timelineNodes.count, timelineNodes[index].id == id {
            mutate(&timelineNodes[index])
            return
        }
        if let idx = timelineNodes.firstIndex(where: { $0.id == id }) {
            timelineIndexByID[id] = idx
            mutate(&timelineNodes[idx])
        } else {
            timelineIndexByID.removeValue(forKey: id)
        }
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

    public mutating func removeNode(id: TimelineNodeID) {
        timelineIndexByID.removeValue(forKey: id)
        if let idx = timelineNodes.firstIndex(where: { $0.id == id }) {
            timelineNodes.remove(at: idx)
            rebuildTimelineIndex()
        }
        committedNodes.removeAll { $0.id == id }
        if activeCell?.id == id {
            activeCell = nil
        }
    }

    public mutating func rebuildTimelineIndex() {
        timelineIndexByID.removeAll(keepingCapacity: true)
        for (idx, n) in timelineNodes.enumerated() {
            timelineIndexByID[n.id] = idx
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

// MARK: - ID-keyed dictionary wire helpers

private extension KeyedEncodingContainer {
    /// Re-keys `[CanonicalID: Value]` into a JSON object keyed by the id's `rawValue`.
    /// Swift's default would emit a flat alternating `[key, value, key, value]` array.
    mutating func encodeIDMap<ID, Value: Encodable>(
        _ map: [ID: Value],
        forKey key: Key,
        key keyPath: KeyPath<ID, String>
    ) throws {
        var object = [String: Value]()
        object.reserveCapacity(map.count)
        for (id, value) in map { object[id[keyPath: keyPath]] = value }
        try encode(object, forKey: key)
    }
}

private extension KeyedDecodingContainer {
    func decodeIDMap<ID: Hashable, Value: Decodable>(
        forKey key: Key,
        makeID: (String) -> ID
    ) throws -> [ID: Value] {
        let object = try decode([String: Value].self, forKey: key)
        var map = [ID: Value]()
        map.reserveCapacity(object.count)
        for (raw, value) in object { map[makeID(raw)] = value }
        return map
    }
}
