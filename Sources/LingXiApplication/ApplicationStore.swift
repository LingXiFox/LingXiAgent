import Foundation
@_exported import LingXiProtocol
import LingXiClient

/// 统一应用程序存储与调度中枢（Frontend 的唯一产品交互接口）。
/// 封装底层 Client、Transport、EventStream、StreamFrame 与 CommandReceipt，
/// 严格保证对外只暴露 ApplicationState、ApplicationAction 与 ApplicationStore。
public actor ApplicationStore {
    private let client: LingXiClientVNext
    public let commandRegistry: ApplicationCommandRegistry
    public private(set) var state: ApplicationState

    private var stateContinuations: [UUID: AsyncStream<ApplicationState>.Continuation] = [:]
    private var runtimeEventsTask: Task<Void, Never>?
    private var connectionStateTask: Task<Void, Never>?
    private var sessionEventsTask: Task<Void, Never>?
    private var activeStreamTasks: [StreamID: Task<Void, Never>] = [:]
    private var runtimeRefreshTask: Task<Void, Never>?

    public init(
        client: LingXiClientVNext,
        autoConnect: Bool = false
    ) async {
        self.client = client
        self.commandRegistry = ApplicationCommandRegistry()
        let initialConn = await client.connectionState
        Self.trace("init.connectionState.done state=\(initialConn)")
        self.state = ApplicationState(connectionState: initialConn)

        // 注册全部内建 20 个正式业务命令
        for cmd in BuiltinCommands.createAll() {
            commandRegistry.register(cmd)
        }

        // 启动连接状态监听
        self.connectionStateTask = Task { [weak self] in
            guard let self = self else { return }
            for await conn in client.stateUpdates {
                await self.dispatch(._connectionStateChanged(conn))
            }
        }

        // 启动 Runtime 语义事件监听
        self.runtimeEventsTask = Task { [weak self] in
            guard let self = self else { return }
            let stream = await client.runtime.events()
            for await event in stream {
                await self.dispatch(._runtimeEventReceived(event))
            }
        }

        if autoConnect {
            debug("init.connect.begin")
            try? await client.connect()
            debug("init.connect.end")
            await refreshRuntimeBasics()
        }
    }

    /// Production composition root for the Application-driven TUI.
    /// Client and transport construction stay inside the Application module.
    public static func stdio(
        corePath: String? = nil,
        interactive: Bool = true,
        autoConnect: Bool = true
    ) async throws -> ApplicationStore {
        trace("stdio.client.create.begin")
        let client = try await LingXiClientVNext.stdioCore(
            corePath: corePath,
            interactive: interactive,
            handshakeImmediately: false
        )
        trace("stdio.client.create.end")
        return await ApplicationStore(client: client, autoConnect: autoConnect)
    }

    public func connect() async throws {
        debug("connect.begin")
        try await client.connect()
        debug("connect.end")
        await refreshRuntimeBasics()
        debug("connect.refreshRuntimeBasics.end")
        notifyStateChanged()
    }

    deinit {
        runtimeEventsTask?.cancel()
        connectionStateTask?.cancel()
        sessionEventsTask?.cancel()
        runtimeRefreshTask?.cancel()
        for task in activeStreamTasks.values {
            task.cancel()
        }
        for cont in stateContinuations.values {
            cont.finish()
        }
    }

    // MARK: - 状态流订阅
    public var stateUpdates: AsyncStream<ApplicationState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(self.state)
            self.stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func notifyStateChanged() {
        for cont in stateContinuations.values {
            cont.yield(state)
        }
    }

    // MARK: - 核心分发调度 (Dispatch)
    public func dispatch(_ action: ApplicationAction) async {
        switch action {
        // MARK: 1. Prompt & Turn 提交
        case let .submitPrompt(prompt):
            await handleSubmitPrompt(prompt)

        // MARK: 2. 会话管理
        case let .createSession(title, mode):
            do {
                let receipt = try await client.session.create(defaultMode: mode)
                if let sID = receipt.result?.sessionID {
                    if let title = title {
                        _ = try? await client.session.rename(sessionID: sID, title: title)
                    }
                    await switchToSession(sID)
                }
            } catch {
            }

        case let .switchSession(sessionID):
            await switchToSession(sessionID)

        case let .renameSession(sessionID, newTitle):
            _ = try? await client.session.rename(sessionID: sessionID, title: newTitle)

        case let .deleteSession(sessionID):
            _ = try? await client.session.delete(sessionID: sessionID)

        case .listSessions:
            if let sessions = try? await client.session.listAll() {
                state.sessionCatalog = sessions
                notifyStateChanged()
            }

        // MARK: 3. 执行取消与停止
        case let .cancelRun(runID, reason):
            if let sID = state.activeSessionID {
                _ = try? await client.run.cancelRun(sessionID: sID, runID: runID, reason: reason)
            }

        case .stopCurrentRun:
            if let sID = state.activeSessionID {
                if let activeRunID = state.activeSessionState?.activeRootRunID {
                    _ = try? await client.run.cancelRun(sessionID: sID, runID: activeRunID, reason: "User stopped")
                }
                if let activeTurnID = state.activeSessionState?.activeTurnID {
                    _ = try? await client.turn.cancelTurn(sessionID: sID, turnID: activeTurnID)
                }
                for pending in state.activeSessionState?.pendingInteractions ?? [] {
                    _ = try? await client.interaction.resolve(sessionID: sID, interactionID: pending.interactionID, resolution: .permission(.deny))
                }
            }

        case let .setMode(mode):
            state.nextTurnMode = mode
            if state.activeSessionID != nil {
                state.activeSessionState?.mode = mode
            }
            notifyStateChanged()

        case let .setPermissionConfiguration(perm):
            state.nextTurnPermission = perm
            if state.activeSessionState?.activeTurnID == nil {
                state.activeSessionState?.permissionConfiguration = perm
                _ = try? await client.runtime.updateTypedSetting(key: "permissionConfiguration", value: perm.displayName)
            }
            notifyStateChanged()

        case let .setReasoningEffort(effort):
            await handleSetReasoningEffort(effort)

        // MARK: 4. HITL 交互响应
        case let .respondInteraction(interactionID, resolution):
            if let sID = state.activeSessionID {
                _ = try? await client.interaction.resolve(sessionID: sID, interactionID: interactionID, resolution: resolution)
            }

        case let .grantPermission(interactionID, decision):
            if let sID = state.activeSessionID {
                _ = try? await client.interaction.resolve(sessionID: sID, interactionID: interactionID, resolution: .permission(decision))
            }

        case let .replyQuestion(interactionID, reply):
            if let sID = state.activeSessionID {
                _ = try? await client.interaction.resolve(sessionID: sID, interactionID: interactionID, resolution: .question(reply))
            }

        case let .submitDecision(interactionID, decision):
            if let sID = state.activeSessionID {
                _ = try? await client.interaction.resolve(sessionID: sID, interactionID: interactionID, resolution: .decision(decision))
            }

        // MARK: 5. Provider & Model
        case let .selectModel(modelID):
            UserPreferencesStore.shared.update(modelID: modelID)
            do {
                let receipt = try await client.model.select(model: modelID)
                state.currentModelID = modelID
                if let sel = receipt.result {
                    state.selectedModel = sel
                }
                notifyStateChanged()
            } catch {
                debug("selectModel.failed: \(error)")
            }

        case .listProviders:
            if let list = try? await client.provider.list() {
                state.providers = list
                notifyStateChanged()
            }

        case .listModels:
            if let list = try? await client.model.list() {
                state.models = list
                notifyStateChanged()
            }

        // MARK: 6. 上下文与扩展
        case let .compactContext(sessionID):
            if let sID = sessionID ?? state.activeSessionID {
                _ = try? await client.context.compact(sessionID: sID)
            }

        case .refreshExtensions:
            if let exts = try? await client.extensionDomain.list() {
                state.extensions = exts
            }
            notifyStateChanged()

        case .refreshDiagnostics:
            if let diag = try? await client.diagnostics.getBundle() {
                state.latestDiagnostics = diag
                state.workflows = diag.workflows
                notifyStateChanged()
            }

        // MARK: 7. 命令执行
        case let .executeCommand(rawInput):
            _ = try? await executeCommand(rawInput)

        // MARK: 8. 连接控制
        case .connect:
            try? await client.connect()

        case .disconnect:
            await client.disconnect()

        case .reconnect:
            try? await client.reconnect()

        // MARK: 9. 内部事件驱动
        case let ._connectionStateChanged(conn):
            RootReducer.reduce(state: &state, action: ._connectionStateChanged(conn))
            if conn.status == .connected {
                await resyncAfterReconnect()
            }
            notifyStateChanged()

        case let ._runtimeEventReceived(event):
            RootReducer.reduce(state: &state, action: ._runtimeEventReceived(event))
            switch event.payload {
            case .providerCatalogChanged, .modelCatalogChanged:
                await refreshRuntimeBasics()
            case .extensionCatalogChanged:
                await dispatch(.refreshExtensions)
            default:
                break
            }
            notifyStateChanged()

        case let ._sessionEventReceived(event):
            RootReducer.reduce(state: &state, action: ._sessionEventReceived(event))
            handleSubscribingStreamsIfNeeded(for: event)
            notifyStateChanged()

        case let ._streamFrameReceived(frame):
            RootReducer.reduce(state: &state, action: ._streamFrameReceived(frame))
            notifyStateChanged()

        case let ._snapshotResynced(snapshot):
            RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))
            notifyStateChanged()

        case let ._runtimeInfoResynced(info):
            RootReducer.reduce(state: &state, action: ._runtimeInfoResynced(info))
            notifyStateChanged()

        case let ._runtimeHealthResynced(health):
            RootReducer.reduce(state: &state, action: ._runtimeHealthResynced(health))
            notifyStateChanged()

        case let ._runtimeCapabilitiesResynced(caps):
            RootReducer.reduce(state: &state, action: ._runtimeCapabilitiesResynced(caps))
            notifyStateChanged()
        }
    }

    /// Executes an application command and returns its user-facing result.
    /// The Client remains private to this actor; Frontends only see this result.
    @discardableResult
    public func executeCommand(_ rawInput: String) async throws -> ApplicationCommandResult {
        let result = try await commandRegistry.execute(
            input: rawInput,
            sessionID: state.activeSessionID,
            client: client,
            state: state
        )
        if let newSessionID = result.sessionIDToSwitch {
            await switchToSession(newSessionID)
        }
        if let newMode = result.nextTurnMode {
            state.nextTurnMode = newMode
            if state.activeSessionID != nil {
                state.activeSessionState?.mode = newMode
            }
            notifyStateChanged()
        }
        if let newPerm = result.nextTurnPermission {
            state.nextTurnPermission = newPerm
            if state.activeSessionState?.activeTurnID == nil {
                state.activeSessionState?.permissionConfiguration = newPerm
                _ = try? await client.runtime.updateTypedSetting(key: "permissionConfiguration", value: newPerm.displayName)
            }
            notifyStateChanged()
        }
        if let newEffort = result.nextTurnReasoningEffort {
            await handleSetReasoningEffort(newEffort)
        }
        return result
    }

    /// 显式设置 Reasoning Effort
    public func setReasoningEffort(_ effort: ReasoningEffort) async {
        await handleSetReasoningEffort(effort)
    }

    private func handleSetReasoningEffort(_ effort: ReasoningEffort) async {
        UserPreferencesStore.shared.update(reasoningEffort: effort.rawValue)
        state.nextTurnReasoningEffort = effort
        if let activeSessionID = state.activeSessionID {
            state.activeSessionState?.reasoningEffort = effort
            _ = try? await client.session.setReasoningEffort(sessionID: activeSessionID, effort: effort)
        }
        notifyStateChanged()
    }

    // MARK: - Prompt 处理
    private func handleSubmitPrompt(_ prompt: String) async {
        var sessionID = state.activeSessionID
        let nextMode = state.nextTurnMode ?? state.activeSessionState?.mode ?? .build
        let nextPerm = state.nextTurnPermission ?? state.activeSessionState?.permissionConfiguration ?? .askWorkspace
        let nextEffort = state.nextTurnReasoningEffort ?? state.activeSessionState?.reasoningEffort ?? .auto

        if sessionID == nil {
            let receipt = try? await client.session.create(defaultMode: nextMode, defaultPermissionConfiguration: nextPerm)
            sessionID = receipt?.result?.sessionID
            if let newID = sessionID {
                await switchToSession(newID)
                if nextEffort != .auto {
                    _ = try? await client.session.setReasoningEffort(sessionID: newID, effort: nextEffort)
                    state.activeSessionState?.reasoningEffort = nextEffort
                }
            }
        }
        guard let validSessionID = sessionID else { return }

        // 自动重命名会话：若当前会话标题为空或为未命名，提取首条 Prompt 生成有意义的摘要标题
        let currentTitle = state.activeSessionState?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isDefaultOrUntitled = currentTitle.isEmpty || currentTitle == "未命名会话" || currentTitle == "未命名" || currentTitle.lowercased() == "untitled"
        if isDefaultOrUntitled {
            let cleanPrompt = prompt.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? prompt
            let trimmedPrompt = cleanPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                let autoTitle = trimmedPrompt.count > 28 ? String(trimmedPrompt.prefix(28)) + "..." : trimmedPrompt
                state.activeSessionState?.title = autoTitle
                if let idx = state.sessionCatalog.firstIndex(where: { $0.sessionID == validSessionID }) {
                    let old = state.sessionCatalog[idx]
                    state.sessionCatalog[idx] = SessionSummary(
                        sessionID: old.sessionID,
                        title: autoTitle,
                        createdAt: old.createdAt,
                        updatedAt: Date(),
                        turnCount: old.turnCount,
                        mode: old.mode,
                        reasoningEffort: old.reasoningEffort,
                        workingDirectory: old.workingDirectory,
                        messageCount: old.messageCount
                    )
                }
                Task { [client, validSessionID, autoTitle] in
                    _ = try? await client.session.rename(sessionID: validSessionID, title: autoTitle)
                }
            }
        }

        let intent = TurnExecutionIntent(
            modelSelection: state.currentModelID,
            mode: nextMode,
            permissionConfiguration: nextPerm
        )
        state.nextTurnMode = nil
        state.nextTurnPermission = nil
        if state.activeSessionState?.status == .ready {
            state.activeSessionState?.status = .waitingForProvider
            state.recalculateStatus()
        }
        notifyStateChanged()

        let input = UserInput(text: prompt)
        do {
            _ = try await client.turn.submitTurn(
                sessionID: validSessionID,
                input: input,
                executionIntent: intent
            )
        } catch {
            state.activeSessionState?.recalculateStatus(connectionState: state.connectionState)
            state.recalculateStatus()
            notifyStateChanged()
        }
    }

    // MARK: - Workspace Reference Scanning
    private var cachedReferenceCandidates: [String] = []
    private var cachedReferenceRoot: String?

    public func workspaceReferenceCandidates() async -> [String] {
        let rootPath = state.currentWorkspace?.rootPath ?? FileManager.default.currentDirectoryPath
        if cachedReferenceRoot == rootPath {
            return cachedReferenceCandidates
        }
        let scan = Task.detached(priority: .utility) {
            let root = URL(fileURLWithPath: rootPath).standardizedFileURL
            var candidates: [String] = []
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    if ["node_modules", "build", "dist", "coverage"].contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                    candidates.append(String(url.path.dropFirst(root.path.count + 1)))
                    if candidates.count >= 500 { break }
                }
            }
            return candidates
        }
        let candidates = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard !Task.isCancelled,
              rootPath == (state.currentWorkspace?.rootPath ?? FileManager.default.currentDirectoryPath) else { return [] }
        cachedReferenceRoot = rootPath
        cachedReferenceCandidates = candidates
        return candidates
    }

    // MARK: - 会话切换与订阅
    public func switchToSession(_ sessionID: SessionID) async {
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
        for task in activeStreamTasks.values {
            task.cancel()
        }
        activeStreamTasks.removeAll()

        state.activeSessionID = sessionID
        if state.activeSessionState?.sessionID != sessionID {
            state.activeSessionState = SessionViewState(sessionID: sessionID)
        }

        // 1. 同步完整权威快照
        if let snapshot = try? await client.session.snapshot(sessionID: sessionID) {
            RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))

            // 若恢复的会话属于其它工作目录，自动切换当前工作文件夹
            if let targetDir = snapshot.info.workingDirectory,
               !targetDir.isEmpty,
               targetDir != FileManager.default.currentDirectoryPath {
                _ = FileManager.default.changeCurrentDirectoryPath(targetDir)
            }
        }

        // 2. 建立 Session 语义事件流订阅
        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.client.session.events(sessionID: sessionID)
                for await event in stream {
                    await self.dispatch(._sessionEventReceived(event))
                }
            } catch {
                // 会话流不可用或关闭
            }
        }
        sessionEventsTask = task
        notifyStateChanged()
    }

    // MARK: - 重连后快照对齐
    private func resyncAfterReconnect() async {
        await refreshRuntimeBasics()
        if let currentSessionID = state.activeSessionID {
            if let snapshot = try? await client.session.snapshot(sessionID: currentSessionID) {
                RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))
            }
        }
    }

    private func refreshRuntimeBasics() async {
        if let task = runtimeRefreshTask {
            await task.value
            return
        }
        let task = Task { await self.performRuntimeBasicsRefresh() }
        runtimeRefreshTask = task
        await task.value
        runtimeRefreshTask = nil
    }

    private func performRuntimeBasicsRefresh() async {
        debug("refresh.runtime.basics.concurrent.begin")
        async let infoTask = try? client.runtime.getInfo()
        async let healthTask = try? client.runtime.getHealth()
        async let capsTask = try? client.runtime.getCapabilities()
        async let modelsTask = try? client.model.list()
        async let selectionTask = try? client.model.getSelection()
        async let providersTask = try? client.provider.list()
        async let pStatusTask = try? client.provider.status()
        async let extensionsTask = try? client.extensionDomain.list()
        async let wsTask = try? client.workspace.get()

        let (info, health, caps, models, selection, providers, pStatus, extensions, ws) = await (
            infoTask, healthTask, capsTask, modelsTask, selectionTask, providersTask, pStatusTask, extensionsTask, wsTask
        )

        if let info {
            RootReducer.reduce(state: &state, action: ._runtimeInfoResynced(info))
        }
        if let health {
            RootReducer.reduce(state: &state, action: ._runtimeHealthResynced(health))
        }
        if let caps {
            RootReducer.reduce(state: &state, action: ._runtimeCapabilitiesResynced(caps))
        }
        if let models {
            state.models = models
        }
        if let selection {
            state.currentModelID = selection.modelID
            state.selectedModel = selection
        }
        if let providers {
            state.providers = providers
        }
        if let pStatus {
            state.providerStatus = pStatus
        }
        if let extensions {
            state.extensions = extensions
        }
        if let ws {
            state.currentWorkspace = ws
        }
        debug("refresh.runtime.basics.concurrent.end")
        notifyStateChanged()

        // 异步后台拉取 workspace diff，不阻塞 UI 首屏渲染
        Task { [weak self] in
            guard let self = self else { return }
            if let diff = try? await self.client.workspace.diff() {
                await self.updateWorkspaceDiff(diff)
            }
        }
    }

    private func updateWorkspaceDiff(_ diff: WorkspaceDiffSummary) {
        state.workspaceDiff = diff
        notifyStateChanged()
    }

    private func debug(_ message: String) {
        Self.trace(message)
    }

    private static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [ApplicationStore] \(message)\n".utf8))
    }

    // MARK: - 动态数据流订阅管理
    private func handleSubscribingStreamsIfNeeded(for event: SessionEventEnvelope) {
        switch event.payload {
        case let .assistantMessageStarted(_, streamID):
            subscribeStreamIfNeeded(streamID: streamID)

        case let .modelStepStarted(_, visibleReasoningStreamID, _):
            if let rStream = visibleReasoningStreamID {
                subscribeStreamIfNeeded(streamID: rStream)
            }

        case let .toolRunning(_, stdoutStreamID, stderrStreamID):
            if let out = stdoutStreamID {
                subscribeStreamIfNeeded(streamID: out)
            }
            if let err = stderrStreamID {
                subscribeStreamIfNeeded(streamID: err)
            }

        default:
            break
        }
    }

    private func subscribeStreamIfNeeded(streamID: StreamID) {
        guard activeStreamTasks[streamID] == nil else { return }
        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.client.subscribeStreamFrames(streamID: streamID)
                let coalesced = LiveDeltaBuffer.coalesceStream(stream, windowMs: 16)
                for await frame in coalesced {
                    StreamingLatencyTracker.shared.record("\(frame.streamID.rawValue):\(frame.index)", stage: .applicationProjected)
                    await self.dispatch(._streamFrameReceived(frame))
                }
            } catch {
                // 流已结束或不可订阅
            }
        }
        activeStreamTasks[streamID] = task
    }
}
