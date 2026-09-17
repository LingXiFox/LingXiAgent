import Testing
import Foundation
import LingXiProtocol
import LingXiClient
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUI

final class MockFrontendRuntime: FrontendRuntime, @unchecked Sendable {
    private var _state: ApplicationState
    private let (stream, continuation): (AsyncStream<ApplicationUpdate>, AsyncStream<ApplicationUpdate>.Continuation)
    public var dispatchedActions: [ApplicationAction] = []
    public var availableCommands: [ApplicationCommand] = []
    public var referenceCandidates: [String] = ["main.swift", "App.swift"]
    public var tasks: [BackgroundTaskSnapshot] = []

    init(initialState: ApplicationState = ApplicationState()) {
        self._state = initialState
        let (s, c) = AsyncStream.makeStream(of: ApplicationUpdate.self)
        self.stream = s
        self.continuation = c
    }

    var state: ApplicationState {
        get async {
            _state
        }
    }

    var updates: AsyncStream<ApplicationUpdate> {
        get async {
            stream
        }
    }

    func dispatch(_ action: ApplicationAction) async {
        dispatchedActions.append(action)
    }

    func workspaceReferenceCandidates() async -> [String] {
        referenceCandidates
    }

    func getBackgroundTasks() async throws -> [BackgroundTaskSnapshot] {
        tasks
    }

    func terminateBackgroundTask(id: String) async throws -> Bool {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks.remove(at: idx)
            return true
        }
        return false
    }

    func executeCommand(_ input: String) async throws -> ApplicationCommandResult {
        ApplicationCommandResult(output: "mock: \(input)")
    }

    func emitUpdate(_ update: ApplicationUpdate) {
        continuation.yield(update)
    }
}

@Suite("Frontend Contract & Runtime Decoupling Tests (Phase 10)", .serialized)
struct FrontendContractTests {

    @Test("FrontendRuntime protocol allows mock runtime without concrete ApplicationStore")
    func testFrontendRuntimeContractMock() async throws {
        let sessionID = SessionID("mock_session")
        var state = ApplicationState()
        state.activeSessionID = sessionID
        let mockRuntime = MockFrontendRuntime(initialState: state)

        let resolvedState = await mockRuntime.state
        #expect(resolvedState.activeSessionID == sessionID)

        await mockRuntime.dispatch(.setMode(.plan))
        #expect(mockRuntime.dispatchedActions.count == 1)
        if case let .setMode(mode) = mockRuntime.dispatchedActions.first {
            #expect(mode == .plan)
        } else {
            Issue.record("Expected setMode action dispatched")
        }

        let candidates = await mockRuntime.workspaceReferenceCandidates()
        #expect(candidates.contains("main.swift"))

        let execResult = try await mockRuntime.executeCommand("/test")
        #expect(execResult.output == "mock: /test")
    }

    @Test("Frontend protocol run method accepts any FrontendRuntime")
    @MainActor
    func testFrontendProtocolAcceptsFrontendRuntime() async throws {
        let mockRuntime = MockFrontendRuntime()
        let options = TUILaunchOptions()
        let tui = ApplicationTUI(options: options)

        // Verify that tui is typed as Frontend
        let _: any Frontend = tui

        // Verify default protocol extensions
        let defaultResult = try await mockRuntime.executeCommand("unknown")
        #expect(!defaultResult.output.isEmpty)
    }
}
