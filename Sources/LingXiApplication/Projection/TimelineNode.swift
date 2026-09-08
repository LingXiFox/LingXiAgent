import Foundation
import LingXiProtocol

/// 时间线节点稳定唯一标识符。
/// 严格由权威 Domain ID 派生，杜绝随机 UUID 或前端本地序号。
public struct TimelineNodeID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func message(_ id: MessageID, modelStepID: ModelStepID? = nil) -> TimelineNodeID {
        TimelineNodeID("message:\(id.rawValue)")
    }

    public static func thinking(_ id: ModelStepID) -> TimelineNodeID {
        TimelineNodeID("thinking:\(id.rawValue)")
    }

    public static func tool(_ id: ToolCallID, modelStepID: ModelStepID? = nil) -> TimelineNodeID {
        TimelineNodeID("tool:\(id.rawValue)")
    }

    public static func interaction(_ id: InteractionID) -> TimelineNodeID {
        TimelineNodeID("interaction:\(id.rawValue)")
    }

    public static func subagent(_ id: RunID) -> TimelineNodeID {
        TimelineNodeID("subagent:\(id.rawValue)")
    }

    public static func runTerminal(_ id: RunID) -> TimelineNodeID {
        TimelineNodeID("runTerminal:\(id.rawValue)")
    }

    public static func error(_ id: RuntimeErrorID) -> TimelineNodeID {
        TimelineNodeID("error:\(id.rawValue)")
    }

    public var description: String { rawValue }
}

/// 时间线节点：面向 Frontend 的稳定产品级视图单元。
public struct TimelineNode: Sendable, Equatable, Identifiable {
    public let id: TimelineNodeID
    public var timestamp: Date
    public var kind: NodeKind
    public var modelStepID: ModelStepID?

    public init(id: TimelineNodeID, timestamp: Date = Date(), kind: NodeKind, modelStepID: ModelStepID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.modelStepID = modelStepID
    }

    public enum NodeKind: Sendable, Equatable {
        case message(MessageNode)
        case thinking(ThinkingNode)
        case tool(ToolNode)
        case interaction(InteractionNode)
        case subagent(SubagentNode)
        case runTerminal(RunTerminalNode)
        case error(ErrorNode)
    }
}
