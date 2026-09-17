import Foundation
@_exported import LingXiProtocol
import LingXiClient

/// 统一应用程序存储与调度中枢（Frontend 的唯一产品交互接口）。
/// 封装底层 Client、Transport、EventStream、StreamFrame 与 CommandReceipt，
/// 严格保证对外只暴露 ApplicationState、ApplicationAction 与 ApplicationStore。
public actor ApplicationStore {
    private let client: LingXiClientVNext
    public nonisolated let commandRegistry: ApplicationCommandRegistry
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
        let initialPrefs = UserPreferencesStore.shared.load()
        if let lastModel = initialPrefs.lastModelID, !lastModel.isEmpty {
            self.state.currentModelID = lastModel
        }
        if let savedPerm = Self.parsePermissionConfiguration(initialPrefs.lastPermissionConfiguration) {
            self.state.nextTurnPermission = savedPerm
        }

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
            let conn = await client.connectionState
            RootReducer.reduce(state: &state, action: ._connectionStateChanged(conn))
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
        let conn = await client.connectionState
        RootReducer.reduce(state: &state, action: ._connectionStateChanged(conn))
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
            _ = try? await client.runtime.terminateAllBackgroundTasks()
            state.backgroundTasks.removeAll()
            if let sID = state.activeSessionID {
                if let activeRunID = state.activeSessionState?.activeRootRunID {
                    _ = try? await client.run.cancelRun(sessionID: sID, runID: activeRunID, reason: "User stopped")
                }
                if let activeTurnID = state.activeSessionState?.activeTurnID {
                    _ = try? await client.turn.cancelTurn(sessionID: sID, turnID: activeTurnID)
                }
                if let turns = state.activeSessionState?.turns.values {
                    for turn in turns {
                        if turn.status == .running || turn.status == .queued {
                            _ = try? await client.turn.cancelTurn(sessionID: sID, turnID: turn.turnID)
                        }
                    }
                }
                for pending in state.activeSessionState?.pendingInteractions ?? [] {
                    _ = try? await client.interaction.resolve(sessionID: sID, interactionID: pending.interactionID, resolution: .permission(.deny))
                }
                state.activeSessionState?.activeRootRunID = nil
                state.activeSessionState?.activeTurnID = nil
                state.activeSessionState?.queuedTurns.removeAll()
                state.activeSessionState?.status = .ready
                state.recalculateStatus()
                notifyStateChanged()
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
            UserPreferencesStore.shared.update(permissionConfiguration: perm.displayName)
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
            do {
                let receipt = try await client.model.select(model: modelID)
                state.currentModelID = modelID
                UserPreferencesStore.shared.update(modelID: modelID)
                if let sel = receipt.result {
                    state.selectedModel = sel
                }
                notifyStateChanged()
            } catch {
                debug("selectModel.failed: \(error)")
                let errMsg = (error as? CoreError)?.message ?? error.localizedDescription
                if state.activeSessionID != nil {
                    let errID = RuntimeErrorID()
                    let errNodeID = TimelineNodeID.error(errID)
                    state.activeSessionState?.appendNode(
                        TimelineNode(id: errNodeID, timestamp: Date(), kind: .error(ErrorNode(errorID: errID, code: "modelSelectFailed", message: "切换模型失败: \(errMsg)")))
                    )
                }
                notifyStateChanged()
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
                commandRegistry.syncPluginCommands(from: exts, client: client)
            }
            notifyStateChanged()

        case .refreshDiagnostics:
            if let diag = try? await client.diagnostics.getBundle() {
                state.latestDiagnostics = diag
                state.workflows = diag.workflows
                if let tasks = diag.backgroundTasks {
                    state.backgroundTasks = tasks
                }
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
        if result.revertedComposerText != nil, let sID = state.activeSessionID {
            let currentEffort = state.effectiveReasoningEffort
            state.status = .ready
            state.activeSessionState?.status = .ready
            state.activeSessionState?.activeTurnID = nil
            state.activeSessionState?.activeRootRunID = nil
            state.activeSessionState?.activeProviderRequestState = nil
            state.activeSessionState?.activeProviderRequestID = nil
            if let snapshot = result.snapshot {
                RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))
            }
            state.nextTurnReasoningEffort = currentEffort
            state.activeSessionState?.reasoningEffort = currentEffort
            if currentEffort != .auto {
                _ = try? await client.session.setReasoningEffort(sessionID: sID, effort: currentEffort)
            }
            notifyStateChanged()
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
    }

    // MARK: - Background Tasks
    public func getBackgroundTasks() async throws -> [BackgroundTaskSnapshot] {
        let tasks = try await client.diagnostics.getBackgroundTasks()
        state.backgroundTasks = tasks
        notifyStateChanged()
        return tasks
    }

    @discardableResult
    public func terminateBackgroundTask(id: String) async throws -> Bool {
        try await client.runtime.terminateBackgroundTask(id: id)
    }

    // MARK: - Prompt 处理
    private func handleSubmitPrompt(_ prompt: String) async {
        debug("handleSubmitPrompt.begin prompt=\(prompt.prefix(20))")
        var sessionID = state.activeSessionID
        let nextMode = state.nextTurnMode ?? state.activeSessionState?.mode ?? .build
        let nextPerm = state.nextTurnPermission ?? state.activeSessionState?.permissionConfiguration ?? .askWorkspace
        let nextEffort = state.nextTurnReasoningEffort ?? state.activeSessionState?.reasoningEffort ?? .auto

        if sessionID == nil {
            debug("handleSubmitPrompt.sessionID.nil calling create")
            do {
                let receipt = try await client.session.create(defaultMode: nextMode, defaultPermissionConfiguration: nextPerm)
                debug("handleSubmitPrompt.session.create.done receipt=\(receipt.applied), sID=\(String(describing: receipt.result?.sessionID))")
                sessionID = receipt.result?.sessionID
            } catch {
                debug("handleSubmitPrompt.session.create.failed error=\(error)")
                let errID = RuntimeErrorID()
                let errNodeID = TimelineNodeID.error(errID)
                let errMsg = (error as? RuntimeError)?.message ?? (error as? CoreError)?.message ?? error.localizedDescription
                if state.activeSessionState == nil {
                    let fallbackSID = SessionID("failed-session")
                    state.activeSessionID = fallbackSID
                    state.activeSessionState = SessionViewState(sessionID: fallbackSID)
                }
                state.activeSessionState?.appendNode(TimelineNode(id: errNodeID, timestamp: Date(), kind: .error(ErrorNode(errorID: errID, code: "createSessionFailed", message: "创建会话失败: \(errMsg)"))))
                notifyStateChanged()
                return
            }
            if let newID = sessionID {
                debug("handleSubmitPrompt.calling switchToSession")
                await switchToSession(newID)
                debug("handleSubmitPrompt.switchToSession returned")
                if nextEffort != .auto {
                    _ = try? await client.session.setReasoningEffort(sessionID: newID, effort: nextEffort)
                    state.activeSessionState?.reasoningEffort = nextEffort
                }
            }
        }
        guard let validSessionID = sessionID else {
            debug("handleSubmitPrompt.sessionID.stillNil! ABORTING!")
            let errID = RuntimeErrorID()
            let errNodeID = TimelineNodeID.error(errID)
            if state.activeSessionState == nil {
                let fallbackSID = SessionID("failed-session")
                state.activeSessionID = fallbackSID
                state.activeSessionState = SessionViewState(sessionID: fallbackSID)
            }
            state.activeSessionState?.appendNode(TimelineNode(id: errNodeID, timestamp: Date(), kind: .error(ErrorNode(errorID: errID, code: "noSessionID", message: "无法创建或获取有效会话 ID"))))
            notifyStateChanged()
            return
        }
        debug("handleSubmitPrompt.validSessionID=\(validSessionID)")

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
        state.activeSessionState?.permissionConfiguration = nextPerm
        if state.activeSessionState?.status == .ready {
            state.activeSessionState?.status = .waitingForProvider
            state.recalculateStatus()
        }
        notifyStateChanged()

        let input = UserInput(text: prompt)
        // 乐观呈现用户消息气泡：消除回车后的等待空白，带来原生即时响应体验
        let optimisticMessageID = MessageID("opt:\(UUID().uuidString)")
        let optimisticNodeID = TimelineNodeID.message(optimisticMessageID)
        let optimisticNode = TimelineNode(
            id: optimisticNodeID,
            timestamp: Date(),
            kind: .message(MessageNode(
                messageID: optimisticMessageID,
                role: .user,
                content: prompt,
                isStreaming: false,
                isFinal: true
            ))
        )
        state.activeSessionState?.appendNode(optimisticNode)
        notifyStateChanged()

        debug("handleSubmitPrompt.calling submitTurn sessionID=\(validSessionID)")
        do {
            _ = try await client.turn.submitTurn(
                sessionID: validSessionID,
                input: input,
                executionIntent: intent
            )
            debug("handleSubmitPrompt.submitTurn.done")
        } catch {
            debug("handleSubmitPrompt.submitTurn.failed error=\(error)")
            state.activeSessionState?.removeNode(id: optimisticNodeID)
            state.activeSessionState?.recalculateStatus(connectionState: state.connectionState)
            state.recalculateStatus()
            let errID = RuntimeErrorID()
            let errNodeID = TimelineNodeID.error(errID)
            let errMsg = (error as? RuntimeError)?.message ?? (error as? CoreError)?.message ?? error.localizedDescription
            state.activeSessionState?.appendNode(TimelineNode(id: errNodeID, timestamp: Date(), kind: .error(ErrorNode(errorID: errID, code: "submitFailed", message: "发送失败: \(errMsg)"))))
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
                    if candidates.count >= 1000 { break }
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    if !relative.isEmpty {
                        candidates.append(relative)
                    }
                }
            }
            return candidates
        }
        let result = await scan.value
        cachedReferenceRoot = rootPath
        cachedReferenceCandidates = result
        return result
    }

    // MARK: - 会话切换与订阅
    public func switchToSession(_ sessionID: SessionID) async {
        debug("switchToSession.begin sessionID=\(sessionID)")
        sessionEventsTask?.cancel()
        sessionEventsTask = nil
        for task in activeStreamTasks.values {
            task.cancel()
        }
        activeStreamTasks.removeAll()

        state.activeSessionID = sessionID
        state.activeSessionState = SessionViewState(sessionID: sessionID)

        // 1. 同步完整权威快照
        var authoritativeCursor: EventCursor?
        debug("switchToSession.calling snapshot")
        if let snapshot = try? await client.session.snapshot(sessionID: sessionID) {
            debug("switchToSession.snapshot success")
            authoritativeCursor = snapshot.eventCursor
            RootReducer.reduce(state: &state, action: ._snapshotResynced(snapshot))

            // 保持工作区权限配置：恢复会话后按最高真实度优先恢复权限策略：
            // 1. 若恢复的会话历史 Turn 中已有执行记录，优先沿用最近一个 Turn 的实际权限策略；
            // 2. 其次若当前应用已显式设定了 nextTurnPermission，沿用该策略；
            // 3. 再次沿用用户全局持久化偏好 lastPermissionConfiguration；
            // 4. 最后降级至快照默认配置。
            let resolvedPerm: PermissionConfiguration = {
                if let lastTurnPerm = snapshot.recentTurns.reversed().compactMap({ $0.executionIntent.permissionConfiguration }).first {
                    return lastTurnPerm
                }
                if let preservedPerm = state.nextTurnPermission {
                    return preservedPerm
                }
                if let savedPerm = Self.parsePermissionConfiguration(UserPreferencesStore.shared.load().lastPermissionConfiguration) {
                    return savedPerm
                }
                return snapshot.permissionConfiguration
            }()

            state.nextTurnPermission = resolvedPerm
            state.activeSessionState?.permissionConfiguration = resolvedPerm
            _ = try? await client.runtime.updateTypedSetting(key: "permissionConfiguration", value: resolvedPerm.displayName)
            UserPreferencesStore.shared.update(permissionConfiguration: resolvedPerm.displayName)

            // 保持工作区模式设定
            if let preservedMode = state.nextTurnMode {
                state.activeSessionState?.mode = preservedMode
            }

            // 保持 Reasoning Effort 思考等级设定：防止快照默认 auto 冲刷用户配置的等级
            let preservedEffort = state.nextTurnReasoningEffort
                ?? (UserPreferencesStore.shared.load().lastReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)))
            if let effort = preservedEffort, effort != .auto {
                state.nextTurnReasoningEffort = effort
                state.activeSessionState?.reasoningEffort = effort
                _ = try? await client.session.setReasoningEffort(sessionID: sessionID, effort: effort)
            }

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
                let stream = try await self.client.session.events(sessionID: sessionID, after: authoritativeCursor)
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
        async let diagTask = try? client.diagnostics.getBundle()

        let (info, health, caps, models, selection, providers, pStatus, extensions, ws, diag) = await (
            infoTask, healthTask, capsTask, modelsTask, selectionTask, providersTask, pStatusTask, extensionsTask, wsTask, diagTask
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
            if state.currentModelID == nil || state.currentModelID?.isEmpty == true {
                state.currentModelID = selection.modelID
            }
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
            commandRegistry.syncPluginCommands(from: extensions, client: client)
        }
        if let ws {
            state.currentWorkspace = ws
        }
        if let diag {
            state.latestDiagnostics = diag
            state.workflows = diag.workflows
            if let tasks = diag.backgroundTasks {
                state.backgroundTasks = tasks
            }
        }
        debug("refresh.runtime.basics.concurrent.end")
        notifyStateChanged()

        // 异步后台拉取 workspace diff 与图谱索引状态，不阻塞 UI 首屏渲染
        Task { [weak self] in
            guard let self = self else { return }
            if let diff = try? await self.client.workspace.diff() {
                await self.updateWorkspaceDiff(diff)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let latestWs = try? await self.client.workspace.get() {
                await self.updateWorkspace(latestWs)
            }
        }
    }

    private func updateWorkspace(_ ws: WorkspaceSummary) {
        state.currentWorkspace = ws
        notifyStateChanged()
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

    public static func parsePermissionConfiguration(_ name: String?) -> PermissionConfiguration? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let lower = name.lowercased()
        if lower.contains("yolo") {
            return .yoloFullAccess
        } else if lower.contains("auto") {
            return .autoWorkspace
        } else if lower.contains("full") {
            return .askFullAccess
        } else if lower.contains("ask") {
            return .askWorkspace
        }
        return nil
    }
}
