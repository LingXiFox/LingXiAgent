import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct ECoreRecallDiscoveryTests {

    private func makeStore() -> (store: ECoreObjectStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = ECoreObjectStore(
            baseDirectory: dir,
            configuration: ContextObjectFabricConfiguration(
                eCorePersistenceEnabled: true,
                objectizationThreshold: 100
            )
        )
        return (store, dir)
    }

    @Test("A blank session_id falls back to the executing session instead of hiding every object")
    func blankSessionIdFallsBackToExecutingSession() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-recall-blank-session")
        let meta = await store.store(
            sessionID: session,
            toolCallID: ToolCallID("call-blank-1"),
            toolName: "shell",
            content: String(repeating: "BM25 versus local dense vectors\n", count: 20)
        )
        #expect(meta != nil)

        let tool = ContextRecallTool(ecoreStore: store)
        let runtime = ToolRuntime(registry: ToolRegistry([tool]), permissions: PermissionEngine(defaultDecision: .allow))
        let result = await runtime.execute(ToolCall(callID: ToolCallID("missing"), toolID: ToolID("context_recall"), arguments: #"{"id":"previous-shell-output","session_id":""}"#), sessionID: session)
        #expect(!result.success)
        let output = result.error?.message ?? result.content
        #expect(output.contains("Archived objects available now"))
        #expect(output.contains(meta?.objectID.rawValue ?? "¤"))
        #expect(!output.contains("no archived objects"))
    }

    @Test("An unknown id in a session with no objects says so instead of failing silently")
    func emptySessionReportsNothingArchived() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = ContextRecallTool(ecoreStore: store)
        let runtime = ToolRuntime(registry: ToolRegistry([tool]), permissions: PermissionEngine(defaultDecision: .allow))
        let result = await runtime.execute(ToolCall(callID: ToolCallID("missing"), toolID: ToolID("context_recall"), arguments: #"{"id":"previous-shell-output"}"#), sessionID: SessionID("s-recall-empty"))
        #expect(!result.success)
        let output = result.error?.message ?? result.content
        #expect(output.contains("no archived objects"))
        #expect(!output.contains("Archived objects available now"))
    }
}
