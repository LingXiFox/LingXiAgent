import Foundation
import Testing
import LingXiProtocol

struct TaskLifecycleContractTests {

    @Test("RunStatus terminal state predicate satisfies contract")
    func runStatusTerminalSemantics() {
        #expect(!RunStatus.queued.isTerminal)
        #expect(!RunStatus.running.isTerminal)
        #expect(!RunStatus.paused.isTerminal)
        #expect(!RunStatus.unknown.isTerminal)

        #expect(RunStatus.completed.isTerminal)
        #expect(RunStatus.failed.isTerminal)
        #expect(RunStatus.cancelled.isTerminal)
    }
}
