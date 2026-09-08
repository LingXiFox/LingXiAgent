import Foundation
import LingXiProtocol

/// 子 Agent 执行节点。
public struct SubagentNode: Sendable, Equatable {
    public let runID: RunID
    public let parentRunID: RunID
    public var status: String
    public var terminalReason: TerminalReason?

    public init(
        runID: RunID,
        parentRunID: RunID,
        status: String = "created",
        terminalReason: TerminalReason? = nil
    ) {
        self.runID = runID
        self.parentRunID = parentRunID
        self.status = status
        self.terminalReason = terminalReason
    }
}
