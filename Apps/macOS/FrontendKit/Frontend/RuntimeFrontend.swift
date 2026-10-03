#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine
import LingXiClient
import LingXiProtocol
import LingXiApplication

/// GUI runtime: owns the presentation models and routes every user intent.
///
/// Backends:
/// - **live**: an Application-layer `FrontendRuntime` (the same `ApplicationStore`
///   the TUI uses) connected to a real Core; state arrives as coalesced
///   `ApplicationUpdate`s and is projected by `CoreProjection`.
/// - **preview**: an in-memory fixture, only via `RuntimeFrontend.preview()`
///   for previews and tests. The app itself never loads it.
/// - **none**: nothing connected; views show the connection state, not sample data.
@MainActor
public final class RuntimeFrontend: ObservableObject {
    public enum Link: Equatable {
        case disconnected
        case connecting(workspace: String)
        case connected
        case failed(String)
    }

    public let sidebarModel: SidebarPresentationModel
    public let conversationModel: ConversationPresentationModel
    public let inspectorModel: RuntimeInspectorPresentationModel
    public let composerModel: ComposerModel
    /// Backing state for the Runtime Observatory window. Read-only with respect to Core.
    public let observatoryModel: RuntimeObservatoryPresentationModel

    @Published public private(set) var link: Link = .disconnected
    @Published public private(set) var workspaceURL: URL?
    @Published public var isCommandPalettePresented = false
    @Published public var isShowingSettings = false
    @Published public var isShowingTasks = false
    @Published public var isShowingAboutSheet = false
    /// Output of the last slash command, presented as a sheet.
    @Published public var commandOutput: CommandOutput?
    /// Failure of a worktree action, shown as an alert.
    @Published public var worktreeError: String?
    /// Failure of any other user-initiated runtime action. §17 of the closure contract
    /// forbids swallowing these: a click must end in a receipt or in something the user can read.
    @Published public var actionError: String?
    @Published public private(set) var isSwitchingWorktree = false
    @Published public private(set) var availableCommands: [CommandDescriptor] = []
    /// The Agent tree as Core reports it, not as the timeline happened to mention.
    ///
    /// `session.subagents` gives the composer a flat list of rows; the parent/root relationships
    /// and terminal reasons that make a tree a tree only exist on the Core side, so this is read
    /// from `getAgentTree` rather than reconstructed locally.
    @Published public private(set) var agentTree: AgentTreeNode?
    @Published public var isAgentTreePresented = false
    /// Timeline tail notice for a live provider condition (rate limit, retry).
    @Published public private(set) var providerNotice: NoticePresentation?
    @Published public private(set) var providerStatus: ProviderStatus?

    /// Shared with Settings so only one Core process ever runs.
    public private(set) var client: LingXiClientVNext?
    private var backend: (any LingXiApplication.FrontendRuntime)?
    private var isPreview = false
    private var updatesTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var intentCancellables: Set<AnyCancellable> = []
    private var isApplyingProjection = false
    private var sleepActivity: NSObjectProtocol?
    private var activeStreamingTask: Task<Void, Never>?
    /// Diff fetched on demand; newer than the store's connect-time snapshot.
    private var refreshedDiff: WorkspaceDiffSummary?
    private var lastState: ApplicationState = .empty

    public init() {
        self.sidebarModel = SidebarPresentationModel(workspace: WorkspaceSummaryPresentation(name: "未打开工作区"))
        self.conversationModel = ConversationPresentationModel()
        self.inspectorModel = RuntimeInspectorPresentationModel()
        self.composerModel = ComposerModel()
        self.observatoryModel = RuntimeObservatoryPresentationModel()
        bindComposerIntents()
    }

    /// Fixture-backed runtime for SwiftUI previews and tests only.
    public static func preview() -> RuntimeFrontend {
        let runtime = RuntimeFrontend()
        runtime.isPreview = true
        runtime.link = .connected
        runtime.loadPreviewFixture()
        return runtime
    }

    public var isLive: Bool { backend != nil }

    // MARK: - Connection

    /// Starts a Core for `workspace`, handing it the directory at spawn time, and attaches the
    /// shared Application store.
    public func openWorkspace(_ workspace: URL) async {
        await closeWorkspace()
        link = .connecting(workspace: workspace.path)
        workspaceURL = workspace
        do {
            let client = try await LingXiClientVNext.stdioCore(interactive: true, handshakeImmediately: false, workingDirectory: workspace)
            let store = await ApplicationStore(client: client, autoConnect: true)
            self.client = client
            attach(store)
            RecentWorkspaces.record(workspace)
            link = .connected
            // Catalogs load in the background: provider discovery can wait on
            // the Keychain, and the stage must not look stuck meanwhile.
            Task { [weak self] in
                await store.dispatch(.listSessions)
                let commands = await store.availableCommands
                self?.availableCommands = commands
                    .map { CommandDescriptor(name: $0.name, summary: $0.description,
                                             category: $0.category, argument: $0.argumentSchema) }
                    .sorted { $0.name < $1.name }
                await store.dispatch(.refreshExtensions)
                await store.dispatch(.listModels)
                await store.dispatch(.listProviders)
            }
        } catch {
            link = .failed(error.localizedDescription)
        }
    }

    public func closeWorkspace() async {
        updatesTask?.cancel()
        renderTask?.cancel()
        updatesTask = nil
        renderTask = nil
        if let backend { await backend.dispatch(.disconnect) }
        backend = nil
        client = nil
        refreshedDiff = nil
        availableCommands = []
        setSleepPrevention(false)
        if !isPreview {
            apply(.empty)
            link = .disconnected
        }
    }

    /// Attaches any Application-layer runtime (real store or a test double).
    func attach(_ runtime: any LingXiApplication.FrontendRuntime) {
        backend = runtime
        let coalescer = FrontendUpdateCoalescer()
        updatesTask = Task.detached {
            for await update in await runtime.updates {
                await coalescer.ingest(update: update)
            }
        }
        renderTask = Task { [weak self] in
            for await _ in await coalescer.invalidationSignal {
                guard let drained = await coalescer.drain() else { continue }
                self?.apply(drained.state)
                // Streams can emit hundreds of deltas per second; ~30 Hz is enough to read.
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    // MARK: - Projection

    func apply(_ state: ApplicationState) {
        lastState = state
        isApplyingProjection = true
        defer { isApplyingProjection = false }
        if isLive, state.connectionState.status == .failed {
            link = .failed(state.connectionState.detail ?? "Core 连接中断")
        }
        let session = state.activeSessionState

        let previousSessionID = conversationModel.sessionID
        conversationModel.sessionID = state.activeSessionID?.rawValue ?? ""
        if conversationModel.sessionID != previousSessionID {
            conversationModel.activeTask = nil
            if isLive { Task { _ = try? await refreshTasks() } }
        }
        conversationModel.items = CoreProjection.timeline(session)
        conversationModel.isGenerating = session?.activeTurnID != nil || session?.status.isActiveRun == true
        providerNotice = CoreProjection.providerNotice(session)
        providerStatus = state.providerStatus

        sidebarModel.workspace = CoreProjection.workspace(state, root: workspaceURL)
        sidebarModel.folders = CoreProjection.sessionFolders(state, workspaceRoot: workspaceURL)
        sidebarModel.selectedSessionID = state.activeSessionID?.rawValue

        let accountIDs = Set(state.providers.flatMap { [$0.id, $0.productID] })
        composerModel.models = state.models.filter { accountIDs.contains($0.providerID) }
        composerModel.selectedModelID = state.currentModelID ?? state.selectedModel?.qualifiedID
        let mode = state.nextTurnMode ?? session?.mode ?? .build
        composerModel.selectedMode = AgentRunMode(mode)
        composerModel.reasoningEffort = ReasoningEffortLevel(protocolEffort: state.effectiveReasoningEffort)
        if let permission = state.activeTurnPermissionConfiguration.flatMap(PermissionPreset.init) {
            composerModel.permissionPreset = permission
        }
        // The goal is Core session state, so the chip shows what Core last reported and never
        // what the composer happened to ask for. A set, a clear, a session switch and a
        // reconnect all arrive through the same projected field.
        if isLive {
            let reportedGoal = session?.goal?.text
            composerModel.goal = (reportedGoal?.isEmpty == false) ? reportedGoal : nil
            let reportedState = composerModel.goal == nil ? nil : session?.goal
            if composerModel.goalState != reportedState { composerModel.goalState = reportedState }
        }

        inspectorModel.live = isLive ? inspectorSnapshot(state) : nil
        inspectorModel.traceEvents = state.latestDiagnostics?.trace ?? []
        setSleepPrevention(conversationModel.isGenerating)
    }

    private func inspectorSnapshot(_ state: ApplicationState) -> InspectorSnapshot {
        let session = state.activeSessionState
        let rootRun = session?.activeRootRunID.flatMap { session?.runs[$0] }
            ?? session?.runs.values.filter { $0.parentRunID == nil }.max { $0.createdAt < $1.createdAt }
        let lastMetrics = session?.timelineNodes.reversed().lazy.compactMap { node -> MessageMetrics? in
            if case .message(let m) = node.kind { return m.metrics }
            return nil
        }.first
        let subagents = (session?.subagents.values).map { nodes in
            nodes.map { node -> SubagentRowPresentation in
                let run = session?.runs[node.runID]
                return SubagentRowPresentation(runID: node.runID.rawValue, parentRunID: node.parentRunID.rawValue,
                                               status: node.status, model: run?.model, startedAt: run?.createdAt,
                                               completedAt: run?.completedAt, terminalReason: node.terminalReason?.rawValue)
            }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        } ?? []
        let root = state.currentWorkspace?.rootPath ?? workspaceURL?.path
        return InspectorSnapshot(
            status: state.status,
            runStartedAt: session?.activeTurnID.flatMap { session?.turns[$0]?.createdAt },
            modelID: state.currentModelID ?? state.selectedModel?.qualifiedID,
            reasoning: state.effectiveReasoningEffort.rawValue,
            permission: state.activeTurnPermissionConfiguration?.displayName ?? "",
            providerState: session?.activeProviderRequestState,
            providerDetail: session?.activeProviderRequestDetail,
            lastMetrics: lastMetrics,
            activeTools: (session?.activeToolCallIDs ?? []).compactMap { session?.toolNodes[$0]?.toolName }.sorted(),
            pendingInteraction: state.activeInteraction.map { $0.kind.rawValue },
            health: state.runtimeHealth,
            context: session?.contextState,
            contextPolicy: session?.contextPolicy,
            compaction: session?.contextCompacted,
            todos: session?.todos ?? [],
            workflows: state.workflows,
            backgroundTasks: state.backgroundTasks,
            rootRun: rootRun,
            subagents: subagents,
            changes: (refreshedDiff ?? state.workspaceDiff).map { CoreProjection.fileChanges(fromUnifiedDiff: $0.diff) } ?? [],
            diffLoaded: (refreshedDiff ?? state.workspaceDiff) != nil,
            branch: state.currentWorkspace?.gitBranch,
            workspaceRoot: root)
    }

    /// Keeps the Mac awake while a run is active, when the user enabled it.
    private func setSleepPrevention(_ running: Bool) {
        let wanted = running && UserDefaults.standard.bool(forKey: LXPreferenceKey.preventSleepWhileRunning)
        if wanted, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "LingXiAgent run in progress")
        } else if !wanted, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - Composer intents → Core

    /// Composer controls write to the model; forward user changes (not projection
    /// echoes) to the store as next-turn intent.
    private func bindComposerIntents() {
        composerModel.$selectedMode.dropFirst().removeDuplicates().sink { [weak self] mode in
            self?.forward(.setMode(AgentMode(mode)))
        }.store(in: &intentCancellables)
        composerModel.$reasoningEffort.dropFirst().removeDuplicates().sink { [weak self] level in
            self?.forward(.setReasoningEffort(level.protocolEffort))
        }.store(in: &intentCancellables)
        composerModel.$permissionPreset.dropFirst().removeDuplicates().sink { [weak self] preset in
            self?.forward(.setPermissionConfiguration(preset.configuration))
        }.store(in: &intentCancellables)
        composerModel.$selectedModelID.dropFirst().removeDuplicates().sink { [weak self] id in
            guard let id else { return }
            self?.forward(.selectModel(id))
        }.store(in: &intentCancellables)
    }

    private func forward(_ action: ApplicationAction) {
        guard !isApplyingProjection, let backend else { return }
        Task { await backend.dispatch(action) }
    }

    // MARK: - Isolated worktree

    /// Creates a Core-managed worktree off the current HEAD and moves the
    /// workspace into it: the agent's edits stay isolated until applied.
    public func enterNewWorktree() async {
        guard let client, !isSwitchingWorktree else { return }
        isSwitchingWorktree = true
        defer { isSwitchingWorktree = false }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        do {
            let receipt = try await client.workspace.createWorktree(name: "task-\(formatter.string(from: .now))")
            guard let info = receipt.result else { throw CoreError(code: .commandFailed, message: "Core 没有返回 Worktree") }
            await openWorkspace(URL(fileURLWithPath: info.path))
        } catch {
            worktreeError = "无法创建独立 Worktree：\(error.localizedDescription)"
        }
    }

    /// Squashes the worktree into the main checkout as staged changes, removes
    /// it and returns there.
    public func applyCurrentWorktree() async {
        await leaveWorktree(label: "应用") { client, id in
            _ = try await client.workspace.applyWorktree(worktreeID: id)
        }
    }

    /// Drops the worktree and its branch, then returns to the main checkout.
    public func discardCurrentWorktree() async {
        await leaveWorktree(label: "丢弃") { client, id in
            _ = try await client.workspace.discardWorktree(worktreeID: id, force: true)
        }
    }

    /// Back to the main checkout; the worktree stays for later.
    public func returnToMainWorkspace() async {
        await leaveWorktree(label: "返回", action: nil)
    }

    private func leaveWorktree(label: String,
                               action: ((LingXiClientVNext, String) async throws -> Void)?) async {
        guard let client, let current = workspaceURL, !isSwitchingWorktree else { return }
        isSwitchingWorktree = true
        defer { isSwitchingWorktree = false }
        // main checkout root 由 Core 用 `--git-common-dir` 推导（契约第十九节）；
        // 前端不再自己跑 `git worktree list`，也不再往 git 传 -C。
        guard let path = try? await client.git.status().mainCheckoutRoot, !path.isEmpty else {
            worktreeError = "找不到主工作区。"
            return
        }
        let main = URL(fileURLWithPath: path)
        do {
            try await action?(client, current.lastPathComponent)
            await openWorkspace(main)
        } catch {
            worktreeError = "\(label) Worktree 失败：\(error.localizedDescription)"
        }
    }


    // MARK: - Actions

    public func sendMessage(text: String, mode: AgentRunMode = .build, attachments: [AttachmentPresentation] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if trimmed.hasPrefix("/") {
            // A slash command is a command line, not a turn; there is nowhere for a file to go.
            guard attachments.isEmpty else {
                actionError = "斜杠命令不能带附件。请先移除附件，或把附件和说明分成两次发送。"
                return
            }
            composerModel.clear()
            runCommand(trimmed)
            return
        }
        if let backend {
            guard !attachments.isEmpty else {
                composerModel.clear()
                Task { await backend.dispatch(.submitPrompt(text: text, attachments: [])) }
                return
            }
            submitWithFiles(text: trimmed, attachments: attachments)
            return
        }
        guard isPreview else { return }
        sendPreviewMessage(text: text, mode: mode, attachments: attachments)
    }

    /// Starts preparing a picked file in Core right away, so the send finds it ready: normalize
    /// and hash first, then — only if the active provider has a Files API — upload. The chip
    /// follows each step; nothing here waits on the user or blocks the composer.
    public func prepareAttachment(id: String, url: URL) {
        guard let client else { return }
        let selectedAt = Date()
        func update(_ state: AttachmentPreparation.State, _ detail: String?) {
            guard let index = composerModel.attachments.firstIndex(where: { $0.id == id }) else { return }
            composerModel.attachments[index].preparation = state
            composerModel.attachments[index].preparationDetail = detail
        }
        update(.preprocessing, nil)
        Task {
            do {
                let local = try await client.resource.prepareAttachment(path: url.path, selectedAt: selectedAt)
                guard local.state != .failed else { return update(.failed, local.detail) }
                guard local.providerSupportsFiles, local.preparedBytes != nil, !local.providerFileReady else {
                    return update(.ready, local.detail)
                }
                update(.uploading, nil)
                let uploaded = try await client.resource.prepareAttachment(path: url.path, selectedAt: selectedAt, upload: true)
                update(uploaded.state, uploaded.detail)
            } catch {
                update(.failed, error.localizedDescription)
            }
        }
    }

    /// Hands the composer's files to Core by path and submits.
    ///
    /// Core runs on this machine beside the files, so there is nothing to upload: the turn carries
    /// each absolute path and Core reads what it needs (an image's bytes; for anything else the
    /// model is told the path). The chip used to wait for an upload, and because the composer
    /// item never received the ref back, its spinner never stopped. A file that has gone away
    /// is reported here and nothing is sent, so a turn never silently loses an attachment.
    private func submitWithFiles(text: String, attachments: [AttachmentPresentation]) {
        guard let backend else {
            actionError = "未连接 Core，无法发送附件。"
            return
        }
        var paths: [String] = []
        for item in attachments {
            guard let url = item.sourceURL else {
                actionError = "「\(item.filename)」不在本机，无法再次发送。"
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                actionError = "「\(item.filename)」已被移动或删除，本轮未发送。"
                return
            }
            paths.append(url.standardizedFileURL.path)
        }
        composerModel.clear()
        Task { await backend.dispatch(.submitPrompt(text: text, fileReferences: paths)) }
    }

    public func stopGenerating() {
        if let backend {
            Task { await backend.dispatch(.stopCurrentRun) }
            return
        }
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        conversationModel.finalizeStreaming()
    }

    /// Re-read the model list. A probe changes what is known about a model, and the composer's menu
    /// is built from this list — without a refresh the answer is paid for and then never shown.
    public func refreshModels() {
        if let backend { Task { await backend.dispatch(.listModels) } }
    }

    /// Permission allow / deny.
    public func resolveInteraction(interactionID: String, approved: Bool) {
        if let backend {
            Task { await backend.dispatch(.grantPermission(interactionID: InteractionID(interactionID),
                                                           decision: approved ? .allow : .deny)) }
            return
        }
        guard isPreview else { return }
        updatePreviewCard(interactionID, status: approved ? .approved : .rejected)
    }

    /// Question reply: selected option indices and / or free text; `nil` cancels.
    public func answerQuestion(_ card: InteractionCardPresentation, selected: [Int], text: String?) {
        guard let backend else { return }
        let id = InteractionID(card.interactionID)
        switch card.kind {
        case .decision:
            guard let index = selected.first, card.options.indices.contains(index) else { return }
            Task { await backend.dispatch(.submitDecision(interactionID: id, decision: card.options[index])) }
        case .question, .permission:
            let reply = QuestionReply(questionID: QuestionID(card.interactionID), selectedOptionIndices: selected,
                                      text: text, cancelled: false)
            Task { await backend.dispatch(.replyQuestion(interactionID: id, reply: reply)) }
        }
    }

    public func cancelQuestion(_ card: InteractionCardPresentation) {
        guard let backend else { return }
        let reply = QuestionReply(questionID: QuestionID(card.interactionID), selectedOptionIndices: [], text: nil, cancelled: true)
        Task { await backend.dispatch(.replyQuestion(interactionID: InteractionID(card.interactionID), reply: reply)) }
    }

    public func switchSession(id: String) {
        if let backend {
            Task { await backend.dispatch(.switchSession(SessionID(id))) }
            return
        }
        guard isPreview else { return }
        sidebarModel.selectedSessionID = id
        conversationModel.sessionID = id
        for folder in sidebarModel.folders {
            if let session = folder.sessions.first(where: { $0.id == id }) {
                conversationModel.activeTask = session.tasks.first
                break
            }
        }
    }

    public func newSession() {
        if let backend {
            let mode = AgentMode(composerModel.selectedMode)
            Task { await backend.dispatch(.createSession(title: nil, mode: mode)) }
            return
        }
        guard isPreview else { return }
        let newID = "sess-\(UUID().uuidString.prefix(6))"
        let newSession = SessionItemPresentation(
            id: newID,
            title: "新会话 \(Date().formatted(date: .omitted, time: .shortened))",
            tasks: [TaskPresentation(taskID: "task-\(UUID().uuidString.prefix(6))", objective: "新会话任务", state: "queued")])
        if sidebarModel.folders.isEmpty {
            sidebarModel.folders = [SessionFolderPresentation(folderName: "Default", sessions: [newSession])]
        } else {
            sidebarModel.folders[0].sessions.insert(newSession, at: 0)
        }
        switchSession(id: newID)
    }

    /// New session in a named workspace. A session always belongs to the workspace its Core
    /// serves, so a workspace other than the current one is opened first.
    public func newSession(inWorkspace path: String) async {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        if link != .connected || workspaceURL?.standardizedFileURL != target {
            guard FileManager.default.fileExists(atPath: target.path) else {
                actionError = "工作区「\(target.lastPathComponent)」已不存在：\(target.path)"
                return
            }
            await openWorkspace(target)
        }
        if link == .connected { newSession() }
    }

    /// Branches a session of the current workspace into a new one with the same history and
    /// switches to it. Core refuses a session with a run in flight; the reason is surfaced.
    public func forkSession(id: String) {
        guard let client, let backend else { return }
        Task {
            do {
                let receipt = try await client.session.fork(sessionID: SessionID(id))
                await backend.dispatch(.listSessions)
                if let forked = receipt.result?.sessionID {
                    await backend.dispatch(.switchSession(forked))
                }
            } catch {
                actionError = "无法创建分支：\(error.localizedDescription)"
            }
        }
    }

    public func renameSession(id: String, title: String) {
        guard let backend else { return }
        Task {
            await backend.dispatch(.renameSession(SessionID(id), newTitle: title))
            await backend.dispatch(.listSessions)
        }
    }

    public func deleteSession(id: String) {
        guard let backend else { return }
        Task {
            await backend.dispatch(.deleteSession(SessionID(id)))
            await backend.dispatch(.listSessions)
        }
    }

    public func compactContext() {
        guard let backend else { return }
        Task { await backend.dispatch(.compactContext(nil)) }
    }

    /// Refreshes the workspace diff and diagnostics for the Changes / Tasks tabs.
    public func refreshRuntimeDetails() {
        guard let backend else { return }
        Task {
            await backend.dispatch(.refreshDiagnostics)
            if let diff = try? await client?.workspace.diff() {
                refreshedDiff = diff
                apply(lastState)
            }
        }
    }

    public func refreshTrace() async {
        guard let backend else { return }
        await backend.dispatch(.refreshDiagnostics)
    }

    public func refreshTasks() async throws -> [TaskSnapshot] {
        guard let client, let sessionID = sidebarModel.selectedSessionID else { return [] }
        let tasks = try await client.task.list(sessionID: SessionID(sessionID))
        if sidebarModel.selectedSessionID == sessionID {
            conversationModel.activeTask = tasks.first(where: { !$0.capsule.state.isTerminal })
                .map { CoreProjection.task($0.capsule) }
                ?? tasks.first.map { CoreProjection.task($0.capsule) }
        }
        return tasks
    }

    /// Stops a background task. The 停止 button in the tasks pane calls this, so a failure is
    /// something the user clicked for and must be able to see; §17 lists Stop among the actions
    /// `try?` is not allowed to swallow.
    public func terminateBackgroundTask(id: String) {
        guard let backend else {
            actionError = "未连接 Core，后台任务无法停止。"
            return
        }
        Task {
            do {
                _ = try await backend.terminateBackgroundTask(id: id)
            } catch {
                actionError = "停止后台任务失败：\(error.localizedDescription)"
            }
            await backend.dispatch(.refreshDiagnostics)
        }
    }

    // MARK: - Terminal sessions

    /// Sessions Core reports right now: the user's shells and the Agent's
    /// running processes. The pane never creates or kills a process itself.
    @Published public private(set) var terminalSessions: [TerminalSessionInfo] = []
    /// One screen per terminal session, kept here rather than in the pane so collapsing and
    /// reopening the panel shows the same screen instead of an empty one.
    private var terminalScreens: [String: TerminalEmulator] = [:]
    /// Bumped whenever any screen changes; the pane observes this, not the screens.
    @Published public private(set) var terminalGeneration = 0
    @Published public var terminalError: String?

    func terminalScreen(for sessionID: String) -> TerminalEmulator {
        if let screen = terminalScreens[sessionID] { return screen }
        let screen = TerminalEmulator()
        // Replies a program asks the terminal for (cursor position, device attributes) go
        // back down the same PTY, as they would from Terminal.app.
        screen.respond = { [weak self] reply in
            Task { await self?.sendTerminalInput(sessionID: sessionID, text: reply) }
        }
        terminalScreens[sessionID] = screen
        return screen
    }

    public func refreshTerminalSessions() async {
        guard let client else { return }
        if let sessions = try? await client.terminal.sessions() {
            terminalSessions = sessions
        }
    }

    /// Pulls whatever the session produced since the last poll into its screen. Returns
    /// whether anything arrived, which is what the pane paces its next poll by.
    @discardableResult
    public func pollTerminalOutput(sessionID: String, columns: Int, rows: Int) async -> Bool {
        guard let client else { return false }
        do {
            let chunk = try await client.terminal.read(sessionID: sessionID, columns: columns, rows: rows)
            if !chunk.text.isEmpty {
                let isPipe = terminalSessions.first { $0.id == sessionID }?.kind == .agent
                // An Agent process writes to a pipe, where nothing turns LF into CR LF the way a
                // tty's line discipline does; without it every line would start where the last ended.
                let text = isPipe ? chunk.text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n") : chunk.text
                terminalScreen(for: sessionID).feed(text)
                terminalGeneration &+= 1
            }
            if chunk.state != .running { await refreshTerminalSessions() }
            return !chunk.text.isEmpty
        } catch {
            terminalError = error.localizedDescription
            return false
        }
    }

    public func spawnTerminalShell(columns: Int = 80, rows: Int = 24) async {
        guard let client else { return }
        do {
            _ = try await client.terminal.spawnShell(cwd: workspaceURL?.path, columns: columns, rows: rows)
            terminalError = nil
            await refreshTerminalSessions()
        } catch {
            terminalError = error.localizedDescription
        }
    }

    public func sendTerminalInput(sessionID: String, text: String) async {
        guard let client else { return }
        do {
            try await client.terminal.write(sessionID: sessionID, text: text)
            terminalError = nil
        } catch {
            terminalError = error.localizedDescription
        }
    }

    public func interruptTerminal(sessionID: String) async {
        guard let client else { return }
        do {
            try await client.terminal.interrupt(sessionID: sessionID)
            terminalError = nil
        } catch {
            terminalError = error.localizedDescription
        }
    }

    /// Ends every shell the user started. The terminal panel owns those: closing it releases
    /// them, as closing a Terminal window does. Processes an Agent run started are not touched.
    public func closeUserShells() async {
        await refreshTerminalSessions()
        for session in terminalSessions where session.kind == .user && session.state == .running {
            await closeTerminalSession(session.id)
        }
    }

    public func closeTerminalSession(_ sessionID: String) async {
        guard let client else { return }
        do {
            try await client.terminal.close(sessionID: sessionID)
            terminalScreens[sessionID] = nil
            terminalError = nil
            await refreshTerminalSessions()
        } catch {
            terminalError = error.localizedDescription
        }
    }

    /// Sets, changes or clears the session goal.
    ///
    /// All three go through the same structured RPC. The composer chip is not written here —
    /// `apply(_:)` renders whatever Core reports, so a clear cannot leave the old goal on
    /// screen while Core still anchors it, and a reconnect restores the truth instead of the
    /// last thing the user typed.
    public func setGoal(_ goal: String?) {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard let client else {
            actionError = "未连接 Core，目标无法设置。"
            return
        }
        guard let sessionID = lastState.activeSessionID else {
            actionError = "没有活动会话，目标无法设置。"
            return
        }
        Task {
            do {
                _ = try await client.session.setGoal(sessionID: sessionID, goal: next)
            } catch {
                actionError = (next == nil ? "清除目标失败：" : "设置目标失败：") + error.localizedDescription
            }
        }
    }

    /// Pauses or resumes the goal. Core stops putting a paused goal in front of the model and
    /// stops its clock; the bar above the composer renders whatever Core reports back.
    public func setGoalPaused(_ paused: Bool) {
        guard let client, let sessionID = lastState.activeSessionID else { return }
        Task {
            do {
                _ = try await client.session.setGoalPaused(sessionID: sessionID, paused: paused)
            } catch {
                actionError = (paused ? "暂停目标失败：" : "恢复目标失败：") + error.localizedDescription
            }
        }
    }

    /// 目标模式 ⏎: anchors the text as a new goal and sends it as the turn that starts work.
    ///
    /// The anchor goes first when a session exists, so the first request already carries it.
    /// With no session yet the turn creates one, and the goal is anchored on it right after —
    /// the first turn still has the goal, because its message *is* the goal.
    public func startGoal(_ text: String, mode: AgentRunMode, attachments: [AttachmentPresentation]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        Task {
            if let sessionID = lastState.activeSessionID {
                do {
                    // A new goal starts its own clock; editing one in the bar keeps it.
                    if composerModel.goal != nil { _ = try await client.session.setGoal(sessionID: sessionID, goal: nil) }
                    _ = try await client.session.setGoal(sessionID: sessionID, goal: trimmed)
                } catch {
                    actionError = "设置目标失败：" + error.localizedDescription
                    return
                }
                sendMessage(text: trimmed, mode: mode, attachments: attachments)
            } else {
                sendMessage(text: trimmed, mode: mode, attachments: attachments)
                for _ in 0..<50 where lastState.activeSessionID == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let sessionID = lastState.activeSessionID else {
                    actionError = "会话尚未建立，目标没有设置。"
                    return
                }
                do { _ = try await client.session.setGoal(sessionID: sessionID, goal: trimmed) }
                catch { actionError = "设置目标失败：" + error.localizedDescription }
            }
        }
    }

    /// Re-reads the Agent tree from Core. Called when the panel opens, after a cancel or a
    /// resume, and never used to guess the shape locally.
    public func refreshAgentTree() async {
        guard let client, let sessionID = lastState.activeSessionID else {
            agentTree = nil
            return
        }
        do {
            agentTree = try await client.run.getAgentTree(sessionID: sessionID)
        } catch {
            actionError = "无法读取 Agent 树：\(error.localizedDescription)"
        }
    }

    /// Cancels a run by its real RPC and reloads the tree from the answer, so the row that
    /// disappears is Core's decision and not the GUI having moved a node on its own board.
    public func cancelAgentRun(_ runID: RunID, title: String?) async {
        guard let client, let sessionID = lastState.activeSessionID else {
            actionError = "未连接 Core，无法取消。"
            return
        }
        do {
            _ = try await client.run.cancelRun(sessionID: sessionID, runID: runID, reason: "用户从 Agent 树取消")
        } catch {
            actionError = "取消「\(title ?? runID.rawValue)」失败：\(error.localizedDescription)"
            return
        }
        await refreshAgentTree()
    }

    /// Resumes only what Core says is resumable. A terminal run answers with an error now
    /// instead of `applied: true` and an unchanged snapshot, so the button cannot lie.
    public func resumeAgentRun(_ runID: RunID, title: String?) async {
        guard let client, let sessionID = lastState.activeSessionID else {
            actionError = "未连接 Core，无法恢复。"
            return
        }
        do {
            _ = try await client.run.resumeRun(sessionID: sessionID, runID: runID)
        } catch {
            actionError = "恢复「\(title ?? runID.rawValue)」失败：\(error.localizedDescription)"
            return
        }
        await refreshAgentTree()
    }

    // MARK: - Context inspector (§8)

    /// The session id the inspector queries. Read from Core's projected state rather than a
    /// GUI-side notion of "current", so the inspector cannot search a session the user left.
    private var activeSessionID: SessionID? { lastState.activeSessionID }

    public func searchCurrentContext(_ query: String) async throws -> [ContextSearchResultItem] {
        guard let client, let sessionID = activeSessionID else {
            throw CoreError(code: .notReady, message: "未连接 Core 或没有活动会话，无法搜索上下文。")
        }
        return try await client.context.search(sessionID: sessionID, query: query)
    }

    public func contextEntry(uri: String) async throws -> ContextEntryItem {
        guard let client, let sessionID = activeSessionID else {
            throw CoreError(code: .notReady, message: "未连接 Core 或没有活动会话，无法打开上下文条目。")
        }
        return try await client.context.getEntry(sessionID: sessionID, uri: uri)
    }

    /// Re-reads what the inspector header shows. Failures are left alone rather than shown as
    /// zero: an unread policy must look unknown, not empty.
    public func refreshContextInspector() async {
        guard let client else { return }
        if let policy = try? await client.context.getPolicy() {
            inspectorModel.effectivePolicy = policy
        }
    }

    /// §10.1: the turn performance report Core actually produces. Reachable from the runtime
    /// detail surface rather than a Settings page, because it is per session and Settings has no
    /// session — the alternative was the global ProviderMetrics RPC, which answered hardcoded
    /// zeros and is now unsupported.
    public func loadPerformanceReport() async {
        guard let client, let sessionID = activeSessionID else {
            inspectorModel.performance = nil
            return
        }
        do {
            inspectorModel.performance = try await client.diagnostics.getPerformanceMetrics(sessionID: sessionID)
        } catch {
            inspectorModel.performance = nil
            actionError = "读取性能报告失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Runtime Observatory (read-only)

    /// Asks Core what the debug surface can do, and records the answer as availability.
    ///
    /// Separate from `refreshObservatory` because it is the one read allowed while the mode is off
    /// — it is how the window knows to say "not enabled" instead of "enabled and empty".
    public func probeObservatory() async {
        guard let client else {
            observatoryModel.availability = .notConnected
            return
        }
        switch await client.debug.probe() {
        case .unsupported: observatoryModel.availability = .unsupported
        case .disabled: observatoryModel.availability = .disabled
        case .enabled(let status): observatoryModel.availability = .enabled(status)
        case .unknown: observatoryModel.availability = .unknown(reason: "Core 未回答该探测")
        }
    }

    /// Pulls one fresh view of everything the Observatory shows.
    ///
    /// Triggered by the window's own controls and by its `.task`, never by a background timer in
    /// the frontend: one of the deep reads behind this is a full heat recompute, so putting it on
    /// the projection path would make an unopened debug window cost the running agent real work.
    public func refreshObservatory() async {
        guard let client, let sessionID = activeSessionID else {
            observatoryModel.availability = .notConnected
            return
        }
        await probeObservatory()
        guard observatoryModel.isLive else { return }

        do {
            observatoryModel.status = try await client.debug.status()
        } catch {
            observatoryModel.readFailure = "读取调试状态失败：\(error.localizedDescription)"
            return
        }
        do {
            observatoryModel.snapshot = try await client.debug.snapshot(sessionID: sessionID)
        } catch {
            // Left at whatever was there before. A panel that clears itself on a failed read shows
            // an absence that did not happen.
            observatoryModel.readFailure = "读取运行时快照失败：\(error.localizedDescription)"
        }
        do {
            let page = try await client.debug.events(sessionID: sessionID,
                                                     afterSequence: observatoryModel.lastSeenSequence)
            observatoryModel.absorb(page)
        } catch {
            observatoryModel.readFailure = "读取遥测事件失败：\(error.localizedDescription)"
        }
    }

    /// Turns Developer Debug Mode on or off, then renders what Core answered.
    ///
    /// No optimistic write: the receipt from Core *is* the authoritative status, so this displays
    /// that rather than what was requested. A toggle that showed "on" while Core said otherwise
    /// would make every subsequent reading uninterpretable.
    public func setDebugMode(_ enabled: Bool) async {
        guard let client else {
            actionError = "未连接 Core，无法切换开发者调试模式。"
            return
        }
        do {
            let status = try await client.debug.setEnabled(enabled)
            observatoryModel.status = status
            observatoryModel.availability = status.enabled ? .enabled(status) : .disabled
            if !enabled { observatoryModel.reset() }
            observatoryModel.readFailure = nil
        } catch {
            actionError = "切换开发者调试模式失败：\(error.localizedDescription)"
            await probeObservatory()
        }
    }

    public func startDebugRecording(runName: String?) async {
        await runDebugRecorderAction { client in
            try await client.debug.startRecording(runName: runName)
        }
    }

    public func stopDebugRecording() async {
        await runDebugRecorderAction { client in
            try await client.debug.stopRecording()
        }
    }

    /// Clears live telemetry only. The archive is a separate decision with a separate door.
    public func clearDebugData() async {
        await runDebugRecorderAction { client in
            try await client.debug.clear()
        }
        observatoryModel.reset()
    }

    public func exportDebugRun(to url: URL) async {
        guard let client else {
            actionError = "未连接 Core，无法导出调试数据。"
            return
        }
        do {
            observatoryModel.status = try await client.debug.export(to: url.path)
        } catch {
            actionError = "导出调试数据失败：\(error.localizedDescription)"
        }
    }

    private func runDebugRecorderAction(_ action: (LingXiClientVNext) async throws -> DebugObservatoryStatus) async {
        guard let client else {
            actionError = "未连接 Core，无法操作调试记录。"
            return
        }
        do {
            observatoryModel.status = try await action(client)
        } catch {
            actionError = "调试记录操作失败：\(error.localizedDescription)"
        }
    }

    public func compactCurrentContext() async {
        guard let client, let sessionID = activeSessionID else {
            actionError = "未连接 Core，无法压缩上下文。"
            return
        }
        do {
            _ = try await client.context.compact(sessionID: sessionID)
        } catch {
            actionError = "压缩上下文失败：\(error.localizedDescription)"
            return
        }
        await refreshContextInspector()
    }

    public func runCommand(_ input: String) {
        guard let backend else {
            commandOutput = CommandOutput(title: input, text: "未连接 Core，命令不可用。")
            return
        }
        Task {
            do {
                let result = try await backend.executeCommand(input)
                if let reverted = result.revertedComposerText { composerModel.text = reverted }
                if !result.output.isEmpty {
                    commandOutput = CommandOutput(title: result.modalTitle ?? input, text: result.output)
                }
            } catch {
                commandOutput = CommandOutput(title: input, text: error.localizedDescription)
            }
        }
    }

    /// Reverts the last conversation turn, removing assistant responses/tool calls and restoring prompt to composer.
    public func undoLastTurn() {
        runCommand("/undo")
    }

    /// Loads a historical user message back into composer for editing and re-submitting.
    public func editMessage(content: String) {
        composerModel.text = content
    }

    /// Finalizes the active task.
    ///
    /// This used to write `task.state = "completed"` into the GUI first and then fire the RPC with
    /// `try?`, so a rejected finalize left the panel showing a completed task that Core had never
    /// accepted. §7.1 requires the opposite order: send the command, take the receipt, then
    /// re-read Core's snapshot and let that change what is displayed.
    public func finalizeTask(action: TaskFinalizeAction) {
        guard let task = conversationModel.activeTask else { return }
        guard let client else {
            actionError = "未连接 Core，任务无法收尾。"
            return
        }
        Task {
            do {
                _ = try await client.task.finalize(taskID: TaskID(task.taskID), action: action)
            } catch {
                actionError = "任务收尾失败：\(error.localizedDescription)"
                return
            }
            await reloadTasks(after: "任务已收尾，但刷新列表失败")
        }
    }

    /// Re-reads the task list after a mutation that Core accepted. A failure here is not the
    /// mutation failing — it is the panel being stale — so it says which, instead of surfacing an
    /// error that would make the user retry a finalize that already worked.
    private func reloadTasks(after successPhrase: String) async {
        do {
            _ = try await refreshTasks()
        } catch {
            actionError = "\(successPhrase)：\(error.localizedDescription)"
        }
    }

    /// Replaces a task's success criteria. Same rule as finalize: the write is confirmed by Core
    /// and read back, never predicted.
    public func updateTaskCriteria(taskID: String, criteria: [SuccessCriterion]) async {
        guard let client else {
            actionError = "未连接 Core，验收标准无法修改。"
            return
        }
        do {
            _ = try await client.task.updateCriteria(taskID: TaskID(taskID), criteria: criteria)
        } catch {
            actionError = "修改验收标准失败：\(error.localizedDescription)"
            return
        }
        await reloadTasks(after: "验收标准已提交，但刷新列表失败")
    }

    /// Artifacts and report are read on demand rather than cached in the GUI, so what Task Detail
    /// shows is whatever Core currently holds.
    public func taskArtifacts(taskID: String) async -> [TaskArtifact] {
        guard let client else { return [] }
        do {
            return try await client.task.listArtifacts(taskID: TaskID(taskID))
        } catch {
            actionError = "读取任务产物失败：\(error.localizedDescription)"
            return []
        }
    }

    public func taskReport(taskID: String) async -> TaskReport? {
        guard let client else { return nil }
        do {
            return try await client.task.getReport(taskID: TaskID(taskID))
        } catch {
            actionError = "读取任务报告失败：\(error.localizedDescription)"
            return nil
        }
    }

    public func submitSideQuestion(question: String) async -> String {
        guard let client, let id = sidebarModel.selectedSessionID else {
            return "请先打开一段对话。"
        }
        do {
            let result = try await client.turn.submitSideQuestion(sessionID: SessionID(id), question: question)
            return result.answer
        } catch {
            return "侧问失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Preview fixture (previews & tests only)

    private func sendPreviewMessage(text: String, mode: AgentRunMode, attachments: [AttachmentPresentation]) {
        conversationModel.items.append(TimelineItemPresentation(kind: .user(content: text, attachments: attachments)))
        composerModel.clear()
        conversationModel.isGenerating = true
        activeStreamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            for chunk in ["预览模式回复：", "收到，", "以 ", mode.rawValue, " 模式处理。"] {
                if Task.isCancelled { break }
                self.conversationModel.appendOrUpdateStreamingChunk(chunk: chunk)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            self.conversationModel.finalizeStreaming()
        }
    }

    private func updatePreviewCard(_ interactionID: String, status: InteractionStatus) {
        guard let index = conversationModel.items.firstIndex(where: {
            if case .interaction(let card) = $0.kind { return card.interactionID == interactionID }
            return false
        }), case .interaction(var card) = conversationModel.items[index].kind else { return }
        card.status = status
        conversationModel.items[index].kind = .interaction(card: card)
    }

    func loadPreviewFixture() {
        let defaultTask = TaskPresentation(
            taskID: "task-init",
            objective: "macOS Sonoma 原生 SwiftUI 界面交付与契约对接",
            state: "running",
            criteria: [
                SuccessCriterion(criterionID: "c1", description: "两栏 NavigationSplitView + .inspector() 原生结构", isSatisfied: true),
                SuccessCriterion(criterionID: "c2", description: "暖墨底、单品牌强调色（狐橙）、原生 Gauge 上下文健康度", isSatisfied: true),
                SuccessCriterion(criterionID: "c3", description: "HITL 审批内联卡片与 AppKit NSTextView Composer 桥接", isSatisfied: false)
            ],

            artifacts: [
                TaskArtifact(ordinal: 1, kind: "spec", ref: "Docs/GUI-DESIGN-SPECIFICATION.md", version: 1),
                TaskArtifact(ordinal: 2, kind: "diff", ref: "git-diff-b4.patch", version: 2, parentVersion: 1)
            ],
            worktreeBranch: "feat/gui-v1-foundation"
        )

        let initialSession = SessionItemPresentation(
            id: "sess-1",
            title: "Phase 4: SwiftUI 原生前端与契约对接",
            lastUpdated: Date(),
            messageCount: 3,
            mode: "Build",
            isActive: true,
            tasks: [defaultTask]
        )

        let folder = SessionFolderPresentation(
            folderName: "LingXiAgent",
            sessions: [initialSession]
        )

        sidebarModel.folders = [folder]
        sidebarModel.selectedSessionID = initialSession.id
        sidebarModel.selectedTaskID = defaultTask.taskID

        conversationModel.sessionID = initialSession.id
        conversationModel.activeTask = defaultTask
        conversationModel.stageTab = .actionFlow
        conversationModel.items = [
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-300),
                kind: .user(content: "开始执行：按照系统工程规范推进开发！", attachments: [])
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-290),
                kind: .thinking(content: "已解析项目规范与架构设计。先读核心依赖与现有实现，确认字阶、列宽与检查器分区，再逐项落实。", isExpanded: false, durationSeconds: 2.4, tokenCount: 420)
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-260),
                kind: .tool(ToolCallPresentation(callID: "c1", toolName: "read", summary: "Docs/GUI-DESIGN-SPECIFICATION.md", status: "completed", output: "## 二、视觉语言：系统语义色 ✕ 狐橙\n…"))
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-252),
                kind: .tool(ToolCallPresentation(callID: "c2", toolName: "read", summary: "Apps/LingXiApp/Shared/DesignSystem/Theme.swift", status: "completed", output: "import SwiftUI\n…"))
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-246),
                kind: .tool(ToolCallPresentation(callID: "c3", toolName: "grep", summary: "monospaced in Apps/", status: "completed", output: "20 matches"))
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-240),
                kind: .tool(ToolCallPresentation(callID: "c4", toolName: "list_directory", summary: "Apps/LingXiApp/Shared/Components", status: "completed", output: "8 files"))
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-200),
                kind: .interaction(card: InteractionCardPresentation(
                    interactionID: "int-101",
                    agentRunID: "main",
                    toolName: "shell",
                    parametersSummary: "swift build --target LingXiFrontendKit",
                    status: .pending
                ))
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-160),
                kind: .diff(filePath: "Apps/LingXiApp/Shared/DesignSystem/DesignTokens.swift", diffContent: "@@ -0,0 +1,96 @@\n+import SwiftUI\n+public enum LingXiMetrics {\n+    public enum Space {\n+        public static let sm: CGFloat = 8\n+    }\n+")
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-150),
                kind: .diff(filePath: "Apps/LingXiApp/Shared/Components/MainStageView.swift", diffContent: "@@ -248,7 +248,6 @@\n-                    .font(.body)\n-                    .lineSpacing(4)\n+                    .font(.lxBody)\n")
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-10),
                kind: .assistant(content: "LingXiAgent 已就绪。可以开始新任务。", isStreaming: false)
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-5),
                kind: .terminal(title: "本轮完成", isSuccess: true, message: "用时 4m 12s · 2 个文件改动")
            )
        ]

    }

}

// MARK: - Supporting types

public struct CommandOutput: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let text: String
}

public struct CommandDescriptor: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let category: String
    public let argument: String
}

/// Recently opened workspaces, most recent first (UserDefaults, GUI-only).
/// Sessions the user archived from the sidebar.
///
/// Archiving is a navigator concern — it keeps a finished thread out of the list without
/// deleting anything — so it lives with the GUI's other preferences, not in Core. Other
/// frontends still list these sessions.
public enum ArchivedSessions {
    static let key = "lx.sidebar.archivedSessions"

    public static var all: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    public static func set(_ id: String, archived: Bool) {
        var ids = all
        if archived { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}

public enum RecentWorkspaces {
    static let key = "lx.workspace.recents"

    public static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    public static func record(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

extension AgentRunMode {
    init(_ mode: AgentMode) {
        switch mode {
        case .plan: self = .plan
        case .explore: self = .explore
        case .build, .unknown: self = .build
        }
    }
}

extension AgentMode {
    init(_ mode: AgentRunMode) {
        switch mode {
        case .build: self = .build
        case .plan: self = .plan
        case .explore: self = .explore
        }
    }
}
#endif
