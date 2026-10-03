#if os(macOS)
import Foundation
import LingXiApplication
import LingXiProtocol

/// Automation owns a real draft until the native editor acknowledges its presentation.
/// All submissions then use the same Composer action as a user pressing Send.
@MainActor
public final class GUIAutomationController {
    private weak var runtime: RuntimeFrontend?
    private struct Pending {
        let task: GUIAutomationTask
        let source: SubmissionSource
        let revision: UInt64
        let pause: Bool
        var presented = false
    }
    private var pending: Pending?
    private var boundary: CheckedContinuation<Bool, Never>?
    private var terminalWait: Task<TurnStatus?, Never>?
    private var creationWait: Task<ApplicationState?, Never>?
    private var busy = false
    private var cancelled = false
    private var expectedSession: SessionID?
    private var sequence: UInt64 = 0
    public private(set) var events: [ComposerAutomationEvent] = []

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        runtime.composerModel.draftDidChange = { [weak self] in
            guard let self, let pending = self.pending,
                  let model = self.runtime?.composerModel else { return }
            if model.draftRevision != pending.revision || model.text != pending.task.text ||
                !model.attachments.isEmpty || model.isGoalMode { self.cancel() }
        }
    }

    public func handle(_ request: GUIAutomationRequest) async -> GUIAutomationResponse {
        switch request.action {
        case .status, .trace:
            return snapshot(includeEvents: request.action == .trace)
        case .cancel:
            cancel()
            return GUIAutomationResponse(accepted: true)
        case .resume:
            guard pending?.presented == true, pending?.pause == true, let boundary else {
                return GUIAutomationResponse(accepted: false, reason: "notPaused")
            }
            self.boundary = nil
            boundary.resume(returning: true)
            return GUIAutomationResponse(accepted: true)
        case .send, .batch: break
        }
        guard !busy else { return GUIAutomationResponse(accepted: false, reason: "automationBusy") }
        guard !request.tasks.isEmpty, request.action != .send || request.tasks.count == 1,
              Set(request.tasks.map(\.id)).count == request.tasks.count,
              request.tasks.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }) else {
            return GUIAutomationResponse(accepted: false, reason: "invalidInput")
        }
        guard let runtime, let backend = runtime.automationBackend else {
            return GUIAutomationResponse(accepted: false, reason: "guiDisconnected")
        }
        guard !request.pauseBeforeSend || runtime.observatoryModel.isLive || request.source == .benchmark else {
            return GUIAutomationResponse(accepted: false, reason: "debugModeRequired")
        }
        busy = true
        cancelled = false
        let startSequence = sequence
        var results: [GUIAutomationResult] = []
        defer {
            busy = false
            pending = nil
            expectedSession = nil
            runtime.composerModel.automationPending = false
            terminalWait?.cancel()
            terminalWait = nil
            creationWait?.cancel()
            creationWait = nil
        }
        func response(_ reason: String? = nil) -> GUIAutomationResponse {
            GUIAutomationResponse(accepted: reason == nil, reason: reason, results: results,
                                  events: events.filter { $0.sequence > startSequence })
        }
        return await withTaskCancellationHandler {
            for task in request.tasks {
                record("automation.command_received", task, request.source, runtime.composerModel.draftRevision)
                if cancelled || Task.isCancelled { return response("cancelled") }
                // Subscribe before Send so even an immediately terminal turn remains observable.
                let updates = await backend.updates
                let before = await backend.state
                guard !cancelled, !Task.isCancelled else { return response("cancelled") }
                guard before.connectionState.status == .connected else { return response("guiDisconnected") }
                let model = runtime.composerModel
                guard model.text.isEmpty, model.attachments.isEmpty else { return response("composerOccupied") }
                guard !model.isGoalMode else { return response("composerGoalMode") }
                guard before.activeSessionState?.activeTurnID == nil,
                      before.activeSessionState?.status.isActiveRun != true,
                      !runtime.conversationModel.isGenerating else { return response("turnActive") }
                expectedSession = before.activeSessionID
                let previousTurns = Set(before.activeSessionState?.turns.keys.map { $0 } ?? [])
                model.text = task.text
                let revision = model.draftRevision
                pending = Pending(task: task, source: request.source, revision: revision, pause: request.pauseBeforeSend)
                model.automationPending = true
                record("composer.draft_set", task, request.source, revision)
                let presented = await withCheckedContinuation { boundary = $0 }
                guard presented, !cancelled, !Task.isCancelled, pending?.revision == revision,
                      model.draftRevision == revision, model.text == task.text,
                      model.attachments.isEmpty, !model.isGoalMode else { return response("cancelled") }
                // Release draft ownership before the common Send action clears it.
                pending = nil
                model.automationPending = false
                record("composer.send_invoked", task, request.source, revision)
                guard let submission = runtime.submitComposer() else { return response("sendRejected") }
                await submission.value
                var after = await backend.state
                func createdTurn(in state: ApplicationState) -> TurnSnapshot? {
                    guard let session = state.activeSessionState else { return nil }
                    return session.turnOrder.compactMap { session.turns[$0] }.first {
                        !previousTurns.contains($0.turnID) && $0.userMessage.text == task.text
                    }
                }
                if createdTurn(in: after) == nil, after.activeSessionState?.status.isActiveRun == true, !cancelled {
                    let wait = Task { @MainActor in
                        var sawSubmission = false
                        for await update in updates {
                            guard !Task.isCancelled else { return nil as ApplicationState? }
                            if createdTurn(in: update.state) != nil { return update.state }
                            if update.state.activeSessionState?.status.isActiveRun == true { sawSubmission = true }
                            if update.state.connectionState.status == .failed || update.state.connectionState.status == .disconnected ||
                                (sawSubmission && update.state.activeSessionState?.status == .error) { return nil }
                        }
                        return nil
                    }
                    // Cancellation must also interrupt waiting for Core's turn-created event.
                    creationWait = wait
                    if cancelled { wait.cancel() }
                    if let created = await wait.value { after = created }
                    creationWait = nil
                }
                guard let session = after.activeSessionState,
                      let turn = createdTurn(in: after) else { return response(cancelled ? "cancelled" : "turnNotCreated") }
                expectedSession = session.sessionID
                record("turn.created", task, request.source, revision)
                var terminal: TurnStatus?
                if request.action == .batch {
                    if turn.status.isTerminal { terminal = turn.status }
                    else if !cancelled {
                        let turnUpdates = await backend.updates
                        let wait = Task { @MainActor in
                            var sawSession = false
                            for await update in turnUpdates {
                                guard !Task.isCancelled else { return nil as TurnStatus? }
                                guard update.state.activeSessionID == session.sessionID else {
                                    if sawSession { return nil }
                                    continue
                                }
                                sawSession = true
                                if let status = update.state.activeSessionState?.turns[turn.turnID]?.status, status.isTerminal {
                                    return status
                                }
                                if update.state.connectionState.status == .failed || update.state.connectionState.status == .disconnected {
                                    return nil
                                }
                            }
                            return nil
                        }
                        terminalWait = wait
                        if cancelled { wait.cancel() }
                        terminal = await wait.value
                        terminalWait = nil
                    }
                }
                results.append(GUIAutomationResult(taskID: task.id, draftRevision: revision, presentedRevision: revision,
                    sessionID: session.sessionID.rawValue, turnID: turn.turnID.rawValue, terminal: terminal?.rawValue))
                if request.action == .batch {
                    guard let terminal, !cancelled else { return response("cancelled") }
                    record("turn.terminal", task, request.source, revision)
                    guard terminal == .completed else { return response("turn\(terminal.rawValue.capitalized)") }
                    // Projection must reflect the terminal state before another real Composer Send.
                    runtime.apply(await backend.state)
                }
            }
            return response()
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    /// Called exclusively by the real NSTextView after drawing and a display boundary.
    public func composerPresented(revision: UInt64, text: String) {
        guard var pending, !pending.presented, let model = runtime?.composerModel,
              pending.revision == revision, pending.task.text == text,
              model.didPresent(revision: revision, text: text) else { return }
        pending.presented = true
        self.pending = pending
        record("composer.presented", pending.task, pending.source, revision)
        if !pending.pause {
            let waiting = boundary
            boundary = nil
            waiting?.resume(returning: true)
        }
    }

    @discardableResult
    public func cancel() -> Bool {
        guard busy else { return false }
        cancelled = true
        if let pending { record("composer.cancelled", pending.task, pending.source, pending.revision) }
        pending = nil
        runtime?.composerModel.automationPending = false
        let waiting = boundary
        boundary = nil
        waiting?.resume(returning: false)
        terminalWait?.cancel()
        creationWait?.cancel()
        return true
    }

    func stateDidChange(_ state: ApplicationState) {
        guard busy else { return }
        if state.connectionState.status == .failed || state.connectionState.status == .disconnected ||
            (pending != nil && expectedSession != nil && expectedSession != state.activeSessionID) { cancel() }
    }

    private func record(_ name: String, _ task: GUIAutomationTask, _ source: SubmissionSource, _ revision: UInt64) {
        sequence += 1
        events.append(ComposerAutomationEvent(sequence: sequence, name: name, taskID: task.id, source: source, composerRevision: revision))
        if events.count > 4096 { events.removeFirst(events.count - 4096) }
    }

    private func snapshot(includeEvents: Bool) -> GUIAutomationResponse {
        GUIAutomationResponse(accepted: true, events: includeEvents ? events : [],
            draftRevision: runtime?.composerModel.draftRevision, presentedRevision: runtime?.composerModel.presentedRevision,
            pendingTaskID: pending?.task.id, draftText: pending == nil ? nil : runtime?.composerModel.text)
    }
}

/// GUI-attached benchmarks share the CLI Composer path and wait for each terminal turn.
@MainActor
public final class BenchmarkController {
    private let automation: GUIAutomationController
    public init(runtime: RuntimeFrontend) { automation = runtime.automationController }
    public func run(tasks: [GUIAutomationTask]) async -> GUIAutomationResponse {
        await automation.handle(GUIAutomationRequest(action: .batch, tasks: tasks, source: .benchmark))
    }
    public func cancel() { automation.cancel() }
}
#endif
