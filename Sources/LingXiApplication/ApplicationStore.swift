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
            if let page = try? await client.session.list() {
                state.sessionCatalog = page.items
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
            _ = try? await client.model.select(model: modelID)

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
            case .providerCatalogChanged, .modelCatalogChanged, .extensionCatalogChanged:
                await refreshRuntimeBasics()
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

    public func workspaceReferenceCandidates() async -> [String] {
        if !cachedReferenceCandidates.isEmpty {
            return cachedReferenceCandidates
        }
        let rootPath = state.currentWorkspace?.rootPath ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: rootPath)
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            cachedReferenceCandidates = enumerator.compactMap { value in
                guard let url = value as? URL else { return nil }
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                guard !path.isEmpty, !path.hasPrefix(".build/"), !path.hasPrefix(".git/") else { return nil }
                return path
            }.prefix(500).map { $0 }
        }
        return cachedReferenceCandidates
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
        debug("refresh.runtime.info.begin")
        if let info = try? await client.runtime.getInfo() {
            RootReducer.reduce(state: &state, action: ._runtimeInfoResynced(info))
        }
        debug("refresh.runtime.info.end")
        debug("refresh.runtime.health.begin")
        if let health = try? await client.runtime.getHealth() {
            RootReducer.reduce(state: &state, action: ._runtimeHealthResynced(health))
        }
        debug("refresh.runtime.health.end")
        debug("refresh.runtime.capabilities.begin")
        if let caps = try? await client.runtime.getCapabilities() {
            RootReducer.reduce(state: &state, action: ._runtimeCapabilitiesResynced(caps))
        }
        debug("refresh.runtime.capabilities.end")
        debug("refresh.model.list.begin")
        if let models = try? await client.model.list() {
            state.models = models
        }
        debug("refresh.model.list.end")
        debug("refresh.model.selection.begin")
        if let selection = try? await client.model.getSelection() {
            state.currentModelID = selection.modelID
            state.selectedModel = selection
        }
        debug("refresh.model.selection.end")
        debug("refresh.provider.list.begin")
        if let providers = try? await client.provider.list() {
            state.providers = providers
        }
        debug("refresh.provider.list.end")
        debug("refresh.provider.status.begin")
        if let pStatus = try? await client.provider.status() {
            state.providerStatus = pStatus
        }
        debug("refresh.provider.status.end")
        debug("refresh.extension.list.begin")
        if let extensions = try? await client.extensionDomain.list() {
            state.extensions = extensions
        }
        debug("refresh.extension.list.end")
        debug("refresh.workspace.get.begin")
        if let ws = try? await client.workspace.get() {
            state.currentWorkspace = ws
        }
        debug("refresh.workspace.get.end")
        debug("refresh.workspace.diff.begin")
        if let diff = try? await client.workspace.diff() {
            state.workspaceDiff = diff
        }
        debug("refresh.workspace.diff.end")
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
