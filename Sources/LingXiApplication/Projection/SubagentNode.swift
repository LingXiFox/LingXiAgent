import Foundation
import LingXiProtocol

/// 子 Agent 执行节点。
public struct SubagentNode: Sendable, Equatable, Codable {
    public let runID: RunID
    public let parentRunID: RunID
    public var status: String
    public var terminalReason: TerminalReason?
    public var resultPreview: String?
    /// The child reached a terminal state after its originating turn had stopped waiting on it.
    public var late: Bool

    public init(
        runID: RunID,
        parentRunID: RunID,
        status: String = "created",
        terminalReason: TerminalReason? = nil,
        resultPreview: String? = nil,
        late: Bool = false
    ) {
        self.runID = runID
        self.parentRunID = parentRunID
        self.status = status
        self.terminalReason = terminalReason
        self.resultPreview = resultPreview
        self.late = late
    }

    private enum CodingKeys: String, CodingKey {
        case runID, parentRunID, status, terminalReason, resultPreview, late
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(RunID.self, forKey: .runID)
        parentRunID = try container.decode(RunID.self, forKey: .parentRunID)
        status = try container.decode(String.self, forKey: .status)
        terminalReason = try container.decodeIfPresent(TerminalReason.self, forKey: .terminalReason)
        resultPreview = try container.decodeIfPresent(String.self, forKey: .resultPreview)
        late = try container.decodeIfPresent(Bool.self, forKey: .late) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(parentRunID, forKey: .parentRunID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(terminalReason, forKey: .terminalReason)
        try container.encodeIfPresent(resultPreview, forKey: .resultPreview)
        // Only carried when true so existing frontends keep reading the same shape.
        if late { try container.encode(true, forKey: .late) }
    }
}
