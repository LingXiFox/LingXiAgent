import Foundation
import LingXiProtocol

/// 思考过程节点。
/// 契约：1 ModelStepID = 1 ThinkingNode。
/// Tool 执行后的后续 ModelStep 必须生成新的 ThinkingNode，严禁向旧 Thinking 节点续写。
public struct ThinkingNode: Sendable, Equatable {
    public let stepID: ModelStepID
    public var title: String?
    public var content: String
    public var isStreaming: Bool
    public var isComplete: Bool
    public var outputMetadata: ModelStepOutputMetadata?
    public var duration: Duration?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        stepID: ModelStepID,
        title: String? = nil,
        content: String = "",
        isStreaming: Bool = false,
        isComplete: Bool = false,
        outputMetadata: ModelStepOutputMetadata? = nil,
        duration: Duration? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.stepID = stepID
        self.title = title
        self.content = content
        self.isStreaming = isStreaming
        self.isComplete = isComplete
        self.outputMetadata = outputMetadata
        self.duration = duration
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
