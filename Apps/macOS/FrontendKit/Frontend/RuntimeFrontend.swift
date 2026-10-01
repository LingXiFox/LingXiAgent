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

        composerModel.models = state.models
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
            Task { await submitWithAttachments(text: trimmed, attachments: attachments) }
            return
        }
        guard isPreview else { return }
        sendPreviewMessage(text: text, mode: mode, attachments: attachments)
    }

    /// Uploads the composer's attachments and only then submits.
    ///
    /// The draft is cleared after every upload succeeded, because §3.2 requires that a failed
    /// attachment never turn into a silently attachment-free turn. One failure aborts the
    /// submission: refs already obtained are left in Core's content store, which is where they
    /// belong — they are addressed by digest and cost nothing to re-reference.
    private func submitWithAttachments(text: String, attachments: [AttachmentPresentation]) async {
        guard let client, let backend else {
            actionError = "未连接 Core，附件无法上传。"
            return
        }
        let limit = lastState.runtimeCapabilities?.maxAttachmentBytes ?? 100 * 1024 * 1024
        var refs: [ContentRef] = []
        for item in attachments {
            // A chip with no local file is one projected back from a snapshot — already Core's,
            // never re-uploadable. Reaching here would mean the pending strip held something it
            // should not, and dropping it quietly is the failure mode worth guarding against.
            guard let url = item.sourceURL else {
                actionError = "「\(item.filename)」不在本机，无法再次上传。"
                return
            }
            guard AttachmentSupport.isText(mediaType: item.mediaType) else {
                actionError = AttachmentSupport.unsupportedReason(for: url)
                return
            }
            guard item.byteCount <= limit else {
                actionError = "「\(item.filename)」有 \(item.formattedSize)，超过本 Core 声明的附件上限 "
                    + "\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))。"
                return
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                actionError = "读取「\(item.filename)」失败：\(error.localizedDescription)"
                return
            }
            do {
                refs.append(try await client.resource.upload(
                    data: data, filename: item.filename, mediaType: item.mediaType))
            } catch {
                actionError = "上传「\(item.filename)」失败，本轮未发送：\(error.localizedDescription)"
                return
            }
        }
        composerModel.clear()
        await backend.dispatch(.submitPrompt(text: text, attachments: refs))
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

    /// A private app-owned working directory lets Core run a session without
    /// binding it to any of the user's projects.
    public func newSessionWithoutWorkspace() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("LingXiAgent", isDirectory: true)
            .appendingPathComponent("无项目", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if link != .connected || workspaceURL?.standardizedFileURL != root.standardizedFileURL {
            await openWorkspace(root)
        }
        if link == .connected { newSession() }
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

    public func terminateBackgroundTask(id: String) {
        guard let backend else { return }
        Task {
            _ = try? await backend.terminateBackgroundTask(id: id)
            await backend.dispatch(.refreshDiagnostics)
        }
    }

    // MARK: - Terminal sessions

    /// Sessions Core reports right now: the user's shells and the Agent's
    /// running processes. The pane never creates or kills a process itself.
    @Published public private(set) var terminalSessions: [TerminalSessionInfo] = []
    @Published public private(set) var terminalOutput: [String: String] = [:]
    @Published public var terminalError: String?

    public func refreshTerminalSessions() async {
        guard let client else { return }
        if let sessions = try? await client.terminal.sessions() {
            terminalSessions = sessions
        }
    }

    /// Pulls whatever the session produced since the last poll.
    public func pollTerminalOutput(sessionID: String, columns: Int, rows: Int) async {
        guard let client else { return }
        do {
            let chunk = try await client.terminal.read(sessionID: sessionID, columns: columns, rows: rows)
            if !chunk.text.isEmpty {
                var text = terminalOutput[sessionID] ?? ""
                text += Self.plainTerminalText(chunk.text)
                if text.count > 120_000 { text.removeFirst(text.count - 120_000) }
                terminalOutput[sessionID] = text
            }
            if chunk.state != .running { await refreshTerminalSessions() }
        } catch {
            terminalError = error.localizedDescription
        }
    }

    public func spawnTerminalShell() async {
        guard let client else { return }
        do {
            _ = try await client.terminal.spawnShell(cwd: workspaceURL?.path, columns: 80, rows: 24)
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

    public func closeTerminalSession(_ sessionID: String) async {
        guard let client else { return }
        do {
            try await client.terminal.close(sessionID: sessionID)
            terminalOutput[sessionID] = nil
            terminalError = nil
            await refreshTerminalSessions()
        } catch {
            terminalError = error.localizedDescription
        }
    }

    /// The pane renders text, not a screen: escape sequences are dropped rather
    /// than drawn. Core's output is untouched.
    private static func plainTerminalText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
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

    public func finalizeTask(action: TaskFinalizeAction) {
        guard var task = conversationModel.activeTask else { return }
        task.state = action == .discard ? "cancelled" : "completed"
        conversationModel.activeTask = task
        if let client {
            Task { _ = try? await client.task.finalize(taskID: TaskID(task.taskID), action: action) }
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
