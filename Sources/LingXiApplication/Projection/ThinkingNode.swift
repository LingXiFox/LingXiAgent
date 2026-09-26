import Foundation
import LingXiProtocol

/// 思考过程节点。
/// 契约：1 ModelStepID = 1 ThinkingNode。
/// Tool 执行后的后续 ModelStep 必须生成新的 ThinkingNode，严禁向旧 Thinking 节点续写。
public struct ThinkingNode: Sendable, Equatable, Codable {
    public let stepID: ModelStepID
    public var title: String?
    public var content: String
    public var isStreaming: Bool
    public var isComplete: Bool
    public var outputMetadata: ModelStepOutputMetadata?
    public var duration: Duration?
    public var startedAt: Date?
    public var completedAt: Date?

    /// `Swift.Duration` is not Codable: it is carried as `durationSeconds` (Double).
    private enum CodingKeys: String, CodingKey {
        case stepID, title, content, isStreaming, isComplete, outputMetadata
        case durationSeconds, startedAt, completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepID = try container.decode(ModelStepID.self, forKey: .stepID)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        self.isComplete = try container.decode(Bool.self, forKey: .isComplete)
        self.outputMetadata = try container.decodeIfPresent(ModelStepOutputMetadata.self, forKey: .outputMetadata)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        if let seconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) {
            self.duration = .seconds(seconds)
        } else {
            self.duration = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepID, forKey: .stepID)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(isComplete, forKey: .isComplete)
        try container.encodeIfPresent(outputMetadata, forKey: .outputMetadata)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        if let duration {
            let components = duration.components
            try container.encode(
                Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000,
                forKey: .durationSeconds
            )
        }
    }

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
