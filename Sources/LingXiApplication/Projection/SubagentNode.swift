import Foundation
import LingXiProtocol

/// 子 Agent 执行节点。
public struct SubagentNode: Sendable, Equatable {
    public let runID: RunID
    public let parentRunID: RunID
    public var status: String
    public var terminalReason: TerminalReason?
    public var resultPreview: String?

    public init(
        runID: RunID,
        parentRunID: RunID,
        status: String = "created",
        terminalReason: TerminalReason? = nil,
        resultPreview: String? = nil
    ) {
        self.runID = runID
        self.parentRunID = parentRunID
        self.status = status
        self.terminalReason = terminalReason
        self.resultPreview = resultPreview
    }
}
