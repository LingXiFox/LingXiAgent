import Foundation
import LingXiProtocol

/// 表示时间线节点的单次结构或数据演进。
public struct TimelineNodeChange: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case append
        case update
        case finalize
        case remove
        case reset
    }

    public let nodeID: TimelineNodeID
    public let kind: Kind

    public init(nodeID: TimelineNodeID, kind: Kind) {
        self.nodeID = nodeID
        self.kind = kind
    }
}

/// 应用程序状态变更集（Domain-specific Invalidation ChangeSet）。
/// 精确标示哪些产品域和时间线节点在本次 mutation 中发生了改变，
/// 允许 UI 前端以最小代价局部刷新，而不需要全量扫描与重新投影。
public struct ApplicationChangeSet: Sendable, Equatable {
    public var sessionChanged: Bool
    public var transcriptStructureChanged: Bool
    public var transcriptNodesChanged: Set<TimelineNodeID>
    public var nodeChanges: [TimelineNodeChange]
    public var contextChanged: Bool
    public var extensionsChanged: Bool
    public var workflowChanged: Bool
    public var backgroundTasksChanged: Bool
    public var providerStatusChanged: Bool
    public var layoutRelevantChanged: Bool
    public var statusChanged: Bool
    public var interactionChanged: Bool
    public var inputChanged: Bool

    public init(
        sessionChanged: Bool = false,
        transcriptStructureChanged: Bool = false,
        transcriptNodesChanged: Set<TimelineNodeID> = [],
        nodeChanges: [TimelineNodeChange] = [],
        contextChanged: Bool = false,
        extensionsChanged: Bool = false,
        workflowChanged: Bool = false,
        backgroundTasksChanged: Bool = false,
        providerStatusChanged: Bool = false,
        layoutRelevantChanged: Bool = false,
        statusChanged: Bool = false,
        interactionChanged: Bool = false,
        inputChanged: Bool = false
    ) {
        self.sessionChanged = sessionChanged
        self.transcriptStructureChanged = transcriptStructureChanged
        self.transcriptNodesChanged = transcriptNodesChanged
        self.nodeChanges = nodeChanges
        self.contextChanged = contextChanged
        self.extensionsChanged = extensionsChanged
        self.workflowChanged = workflowChanged
        self.backgroundTasksChanged = backgroundTasksChanged
        self.providerStatusChanged = providerStatusChanged
        self.layoutRelevantChanged = layoutRelevantChanged
        self.statusChanged = statusChanged
        self.interactionChanged = interactionChanged
        self.inputChanged = inputChanged
    }

    /// 空变更集
    public static var empty: ApplicationChangeSet {
        ApplicationChangeSet()
    }

    /// 判断变更集是否没有任何域变更
    public var isEmpty: Bool {
        !sessionChanged &&
        !transcriptStructureChanged &&
        transcriptNodesChanged.isEmpty &&
        nodeChanges.isEmpty &&
        !contextChanged &&
        !extensionsChanged &&
        !workflowChanged &&
        !backgroundTasksChanged &&
        !providerStatusChanged &&
        !layoutRelevantChanged &&
        !statusChanged &&
        !interactionChanged &&
        !inputChanged
    }

    /// 全量重置或快照同步时的变更集
    public static var fullSnapshot: ApplicationChangeSet {
        ApplicationChangeSet(
            sessionChanged: true,
            transcriptStructureChanged: true,
            transcriptNodesChanged: [],
            nodeChanges: [],
            contextChanged: true,
            extensionsChanged: true,
            workflowChanged: true,
            backgroundTasksChanged: true,
            providerStatusChanged: true,
            layoutRelevantChanged: true,
            statusChanged: true,
            interactionChanged: true,
            inputChanged: true
        )
    }

    public mutating func merge(with other: ApplicationChangeSet) {
        if other.sessionChanged { sessionChanged = true }
        if other.transcriptStructureChanged { transcriptStructureChanged = true }
        transcriptNodesChanged.formUnion(other.transcriptNodesChanged)
        nodeChanges.append(contentsOf: other.nodeChanges)
        if other.contextChanged { contextChanged = true }
        if other.extensionsChanged { extensionsChanged = true }
        if other.workflowChanged { workflowChanged = true }
        if other.backgroundTasksChanged { backgroundTasksChanged = true }
        if other.providerStatusChanged { providerStatusChanged = true }
        if other.layoutRelevantChanged { layoutRelevantChanged = true }
        if other.statusChanged { statusChanged = true }
        if other.interactionChanged { interactionChanged = true }
        if other.inputChanged { inputChanged = true }
    }
}

/// 携带单调递增版本号与增量变更集的应用程序状态更新包。
public struct ApplicationUpdate: Sendable {
    public let revision: UInt64
    public let state: ApplicationState
    public let changes: ApplicationChangeSet

    public init(revision: UInt64, state: ApplicationState, changes: ApplicationChangeSet) {
        self.revision = revision
        self.state = state
        self.changes = changes
    }
}
