import LingXiKernel
import LingXiPluginABI
@testable import LingXiPluginRuntime
import Testing

@Test("reasoning turns are cleared at the final execution boundary and bounded at 64 executions")
func reasoningStoreBoundsAndClears() {
    let store = PluginProviderAdapter.ReasoningStore()
    let turn = ProviderReasoningTurn(
        callIDs: ["call-1"],
        items: [ProviderReasoningItem(id: "rs-1", text: "reasoning", status: "completed")]
    )
    store.appendTurn(turn, for: ExecutionID("exec-one"))
    let first = store.turns(for: ExecutionID("exec-one"))
    #expect(first.count == 1)
    #expect(store.turns(for: ExecutionID("exec-other")).isEmpty)
    store.endExecution(ExecutionID("exec-one"))
    #expect(store.cachedExecutionCount == 0)

    for index in 0..<100 {
        let execution = ExecutionID("exec-\(index)")
        store.appendTurn(turn, for: execution)
        // A tool round expects one more request, so the turn survives this boundary.
        store.endExecution(execution)
        // The next request consumes it; the following end is the Run's final boundary.
        #expect(store.turns(for: execution).count == 1)
        store.endExecution(execution)
    }
    #expect(store.cachedExecutionCount == 0)
    #expect(store.turns(for: ExecutionID("exec-99")).isEmpty)

    for index in 0..<100 {
        store.appendTurn(turn, for: ExecutionID("pending-\(index)"))
    }
    #expect(store.cachedExecutionCount <= 64)
    store.clearAll()
    #expect(store.cachedExecutionCount == 0)
}
