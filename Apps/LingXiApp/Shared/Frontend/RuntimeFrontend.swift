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
    @Published public var isShowingAboutSheet = false
    /// Output of the last slash command, presented as a sheet.
    @Published public var commandOutput: CommandOutput?
    @Published public private(set) var availableCommands: [CommandDescriptor] = []
    /// Timeline tail notice for a live provider condition (rate limit, retry).
    @Published public private(set) var providerNotice: NoticePresentation?

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

    /// Starts a Core for `workspace` (the Core inherits this process's working
    /// directory as its workspace) and attaches the shared Application store.
    public func openWorkspace(_ workspace: URL) async {
        await closeWorkspace()
        link = .connecting(workspace: workspace.path)
        workspaceURL = workspace
        do {
            FileManager.default.changeCurrentDirectoryPath(workspace.path)
            let client = try await LingXiClientVNext.stdioCore(interactive: false, handshakeImmediately: false)
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

        conversationModel.sessionID = state.activeSessionID?.rawValue ?? ""
        conversationModel.items = CoreProjection.timeline(session)
        conversationModel.isGenerating = session?.activeTurnID != nil
        providerNotice = CoreProjection.providerNotice(session)

        sidebarModel.workspace = CoreProjection.workspace(state, root: workspaceURL)
        sidebarModel.folders = CoreProjection.sessionFolders(state, workspaceName: sidebarModel.workspace.name)
        sidebarModel.selectedSessionID = state.activeSessionID?.rawValue

        composerModel.models = state.models
        composerModel.selectedModelID = state.currentModelID ?? state.selectedModel?.modelID
        let mode = state.nextTurnMode ?? session?.mode ?? .build
        composerModel.selectedMode = AgentRunMode(mode)
        composerModel.reasoningEffort = ReasoningEffortLevel(protocolEffort: state.effectiveReasoningEffort)
        if let permission = state.activeTurnPermissionConfiguration.flatMap(PermissionPreset.init) {
            composerModel.permissionPreset = permission
        }

        inspectorModel.live = isLive ? inspectorSnapshot(state) : nil
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
            modelID: state.currentModelID ?? state.selectedModel?.modelID,
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
            branch: root.flatMap { CoreProjection.gitBranch(at: URL(fileURLWithPath: $0)) },
            workspaceRoot: root)
    }

    /// Keeps the Mac awake while a run is active, when the user enabled it.
    private func setSleepPrevention(_ running: Bool) {
        let wanted = running && UserDefaults.standard.bool(forKey: LXPreferenceKey.preventSleepWhileRunning)
        if wanted, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "LingXi agent run in progress")
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

    // MARK: - Actions

    public func sendMessage(text: String, mode: AgentRunMode = .build, attachments: [AttachmentPresentation] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("/") {
            composerModel.clear()
            runCommand(trimmed)
            return
        }
        if let backend {
            composerModel.clear()
            Task { await backend.dispatch(.submitPrompt(text)) }
            return
        }
        guard isPreview else { return }
        sendPreviewMessage(text: text, mode: mode, attachments: attachments)
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

    public func terminateBackgroundTask(id: String) {
        guard let backend else { return }
        Task {
            _ = try? await backend.terminateBackgroundTask(id: id)
            await backend.dispatch(.refreshDiagnostics)
        }
    }

    /// Sets the goal through the existing `/goal` command and keeps it visible in the composer.
    public func setGoal(_ goal: String?) {
        let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        composerModel.goal = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard let trimmed, !trimmed.isEmpty else { return }
        runCommand("/goal \(trimmed)")
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

    /// Core has no `submitSideQuestion` implementation — only the protocol
    /// extension default, which echoes the question back as an answer. Showing
    /// that would be a mock, so the surface stays closed until Core ships one.
    public func submitSideQuestion(question: String) async -> String {
        "侧问还没有由 Core 实现，暂时无法回答。"
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
                kind: .assistant(content: "LingXiAgent 环境已就绪。系统双栏结构、任务控制条、Context Health 仪表与赛博时间线已全部接入。", isStreaming: false)
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
