import Foundation
import LingXiProtocol

/// Run 终态节点。
public struct RunTerminalNode: Sendable, Equatable {
    public let runID: RunID
    public let terminalReason: TerminalReason

    public init(runID: RunID, terminalReason: TerminalReason) {
        self.runID = runID
        self.terminalReason = terminalReason
    }
}
