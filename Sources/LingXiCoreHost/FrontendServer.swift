import Foundation
import LingXiCredentialStore
import LingXiFrontendProtocol
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime

/// The resident Core's frontend endpoint. It owns no execution logic: chat requests go straight
/// through the existing AgentLoop, plugin requests through the existing coordinator.
final class FrontendServer: @unchecked Sendable {
    private let loop: AgentLoop
    private let store: SessionStore
    private let router: ModelRouter
    private let registry: PluginRegistry
    private let coordinator: PluginCoordinator
    private let settings: PluginSettingsCoordinator
    private let credentials: CredentialAuthority
    private let policy: SignaturePolicy
    private let output = FileHandle.standardOutput
    private let lock = NSLock()
    private var runs: [String: Task<Void, Never>] = [:]
    private var shuttingDown = false

    init(
        loop: AgentLoop, store: SessionStore, router: ModelRouter,
        registry: PluginRegistry, coordinator: PluginCoordinator, policy: SignaturePolicy,
        credentials: CredentialAuthority, settings: PluginSettingsCoordinator
    ) {
        self.loop = loop
        self.store = store
        self.router = router
        self.registry = registry
        self.coordinator = coordinator
        self.policy = policy
        self.credentials = credentials
        self.settings = settings
        Task { [weak self, coordinator] in
            await coordinator.setStateChangeHandler { [weak self] in
                Task { await self?.broadcastState() }
            }
        }
    }

    func serve() async {
        var pending = Data()
        while !shuttingDown {
            let chunk = FileHandle.standardInput.availableData
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard !line.isEmpty else { continue }
                guard let request = try? JSONDecoder().decode(FrontendRequest.self, from: Data(line)) else {
                    send(FrontendReply(id: 0, ok: false, error: "undecodable request"))
                    continue
                }
                Task { await self.handle(request) }
            }
        }
    }

    private func handle(_ request: FrontendRequest) async {
        var reply = FrontendReply(id: request.id, ok: true)
        switch request.method {
        case .hello:
            reply.models = await offeredModels()
            reply.modelDetails = await offeredModelDetails()
            reply.preferredModel = await settings.preferredModelHint(
                bundleIDs: await registry.all().map(\.bundleID)
            )
            reply.sessions = await sessionSummaries()
            reply.plugins = await pluginSummaries()
        case .modelsList:
            reply.models = await offeredModels()
            reply.modelDetails = await offeredModelDetails()
        case .sessionsList:
            reply.sessions = await sessionSummaries()
        case .sessionNew:
            reply.sessionID = "session-\(UUID().uuidString)"
        case .sessionHistory:
            guard let sessionID = request.sessionID else {
                return send(FrontendReply(id: request.id, ok: false, error: "session.history needs sessionID"))
            }
            reply.history = await history(for: sessionID)
        case .chatSend:
            guard let text = request.text, !text.isEmpty else {
                return send(FrontendReply(id: request.id, ok: false, error: "chat.send needs text"))
            }
            let sessionID = request.sessionID ?? "session-\(UUID().uuidString)"
            let offered = await offeredModels()
            guard let model = request.model ?? offered.first else {
                return send(FrontendReply(id: request.id, ok: false, error: "no model is available; enable a provider plugin"))
            }
            guard offered.contains(model) else {
                return send(FrontendReply(id: request.id, ok: false, error: "model \(model) is not offered by an active provider"))
            }
            let runID = "run-\(UUID().uuidString)"
            reply.sessionID = sessionID
            reply.runID = runID
            send(reply)
            startRun(runID: runID, sessionID: sessionID, model: model, text: text)
            return
        case .runCancel:
            guard let runID = request.runID else {
                return send(FrontendReply(id: request.id, ok: false, error: "run.cancel needs runID"))
            }
            takeRun(runID)?.cancel()
        case .pluginsList:
            reply.plugins = await pluginSummaries()
        case .pluginSettingsOpen:
            guard let bundleID = request.bundleID else {
                return send(FrontendReply(id: request.id, ok: false, error: "plugin.settings.open needs bundleID"))
            }
            do {
                reply.settings = try await settings.open(
                    bundleID: bundleID,
                    viewport: request.viewport ?? SettingsViewport(width: 72, height: 20)
                )
            } catch {
                reply.ok = false
                reply.error = "\(error)"
            }
        case .pluginSettingsInput:
            guard let sessionID = request.settingsSessionID, let input = request.settingsInput else {
                return send(FrontendReply(id: request.id, ok: false, error: "plugin.settings.input needs a session and input"))
            }
            do {
                reply.settings = try await settings.input(sessionID: sessionID, input: input)
            } catch {
                reply.ok = false
                reply.error = "\(error)"
            }
        case .pluginSettingsResize:
            guard let sessionID = request.settingsSessionID, let viewport = request.viewport else {
                return send(FrontendReply(id: request.id, ok: false, error: "plugin.settings.resize needs a session and viewport"))
            }
            do {
                reply.settings = try await settings.resize(sessionID: sessionID, viewport: viewport)
            } catch {
                reply.ok = false
                reply.error = "\(error)"
            }
        case .pluginSettingsSave:
            guard let sessionID = request.settingsSessionID else {
                return send(FrontendReply(id: request.id, ok: false, error: "plugin.settings.save needs a session"))
            }
            do {
                let bundleID = await settings.bundleID(forSessionID: sessionID)
                try await settings.save(sessionID: sessionID)
                if let bundleID {
                    reply.preferredModel = await settings.preferredModel(forBundleID: bundleID)
                }
            } catch {
                reply.ok = false
                reply.error = "\(error)"
            }
        case .pluginSettingsCancel:
            if let sessionID = request.settingsSessionID {
                await settings.cancel(sessionID: sessionID)
            }
        case .pluginSettingsCredential:
            guard let sessionID = request.settingsSessionID,
                  let providerID = request.provider, !providerID.isEmpty,
                  let action = request.settingsCredentialAction else {
                return send(FrontendReply(
                    id: request.id, ok: false,
                    error: "plugin.settings.credential needs a session, provider and action"
                ))
            }
            do {
                switch action {
                case "update":
                    reply.credentials = [try await settings.credentialStatus(
                        sessionID: sessionID, providerID: providerID
                    )]
                case "remove":
                    reply.credentials = [try await settings.removeCredential(
                        sessionID: sessionID, providerID: providerID,
                        confirmed: request.settingsCredentialConfirmed == true
                    )]
                default:
                    throw PluginSettingsCoordinator.SettingsError.rejected("unknown credential action \(action)")
                }
            } catch {
                reply.ok = false
                reply.error = "\(error)"
            }
        case .pluginEnable, .pluginDisable:
            guard let bundleID = request.bundleID else {
                return send(FrontendReply(id: request.id, ok: false, error: "\(request.method.rawValue) needs bundleID"))
            }
            do {
                if request.method == .pluginEnable {
                    let grants = await registry.entry(bundleID)?.grants ?? []
                    _ = try await coordinator.enable(
                        bundleID: bundleID, policy: policy, grantedPermissions: grants
                    )
                } else {
                    try await coordinator.disable(bundleID: bundleID)
                }
                reply.plugins = await pluginSummaries()
                reply.models = await offeredModels()
                reply.modelDetails = await offeredModelDetails()
            } catch {
                reply.ok = false
                reply.error = "\(error)"
                reply.plugins = await pluginSummaries()
            }
        case .authStatus, .authSet, .authRemove:
            do {
                guard let providerID = request.provider, !providerID.isEmpty else {
                    throw AuthError.invalidRequest
                }
                let bundleID: String
                let requirement: CredentialRequirement
                let declared = await coordinator.credentialProviders()
                    .filter { $0.declaration.id == providerID }
                if let settingsSessionID = request.settingsSessionID {
                    // The settings session is the authority for a disabled plugin's credentials:
                    // it may not be running, but its declaration still owns this provider.
                    let binding = try await settings.credentialBinding(
                        sessionID: settingsSessionID, providerID: providerID
                    )
                    bundleID = binding.bundleID
                    requirement = binding.requirement
                } else if let provider = declared.first,
                    let first = provider.declaration.credentials?.first {
                    bundleID = provider.bundleID
                    requirement = first
                } else {
                    let installed = await registry.all().map(\.bundleID)
                    let saved = try credentials.storedKeys().filter {
                        $0.providerID == providerID && installed.contains($0.bundleID)
                    }
                    guard declared.isEmpty, saved.count == 1, let key = saved.first else { throw AuthError.enableFirst }
                    guard request.method != .authSet else { throw AuthError.enableFirst }
                    bundleID = key.bundleID
                    requirement = CredentialRequirement(id: key.credentialID, label: "API Key", envVariable: nil, helpURL: nil)
                }
                switch request.method {
                case .authSet:
                    guard let secret = request.secret else { throw AuthError.invalidRequest }
                    try credentials.set(secret, bundleID: bundleID, providerID: providerID, requirement: requirement)
                case .authRemove:
                    try credentials.remove(bundleID: bundleID, providerID: providerID, requirement: requirement)
                default: break
                }
                let state = try credentials.availability(bundleID: bundleID, providerID: providerID, requirement: requirement)
                reply.credentials = [CredentialStatus(
                    providerID: state.providerID, credentialID: state.credentialID, label: state.label,
                    source: state.source.rawValue, configured: state.configured
                )]
            } catch {
                reply.ok = false
                // Auth errors carry fixed text or OSStatus only, never an IPC payload or secret.
                reply.error = String(describing: error)
            }
        case .shutdown:
            shuttingDown = true
            await settings.shutdown()
        }
        send(reply)
    }

    private enum AuthError: Error, CustomStringConvertible {
        case invalidRequest, enableFirst
        var description: String {
            switch self {
            case .invalidRequest: "auth needs a provider id and auth.set needs a nonempty secret"
            case .enableFirst: "enable the provider plugin with one declared API key first; a saved key may still be inspected or removed while disabled"
            }
        }
    }

    private func startRun(runID: String, sessionID: String, model: String, text: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            self.emit(FrontendEvent(event: "run.state", runID: runID, sessionID: sessionID, status: "running"))
            let request = RunRequest(
                sessionID: SessionID(sessionID),
                turnID: TurnID(runID),
                runID: RunID(runID),
                executionID: ExecutionID(runID),
                model: ModelID(model),
                prompt: text
            )
            let result = await self.loop.run(request, policy: LoopPolicy()) { event in
                switch event {
                case .textDelta(let delta):
                    self.emit(FrontendEvent(event: "delta", runID: runID, sessionID: sessionID, delta: delta))
                case .reasoningDelta(let delta):
                    self.emit(FrontendEvent(event: "reasoning", runID: runID, sessionID: sessionID, reasoning: delta))
                case .toolCallStarted(let start):
                    var tool = FrontendEvent(event: "tool", runID: runID, sessionID: sessionID, status: "started")
                    tool.tool = start.toolName
                    self.emit(tool)
                case .toolCallCompleted(let call):
                    var tool = FrontendEvent(event: "tool", runID: runID, sessionID: sessionID, status: "requested")
                    tool.tool = call.toolName
                    // Arguments are model output the user may see; bound them so one call cannot flood the UI.
                    tool.detail = call.argumentsJSON.count > 240 ? String(call.argumentsJSON.prefix(240)) + "…" : call.argumentsJSON
                    self.emit(tool)
                case .usage(let usage):
                    var event = FrontendEvent(event: "usage", runID: runID, sessionID: sessionID)
                    event.usage = TokenUsage(
                        inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                        reasoningTokens: usage.reasoningTokens, cacheReadTokens: usage.cacheReadTokens
                    )
                    self.emit(event)
                default:
                    break
                }
            }
            var terminal = FrontendEvent(event: "run.terminal", runID: runID, sessionID: sessionID)
            terminal.status = result.status.rawValue
            terminal.cause = result.cause.rawValue
            terminal.detail = result.detail
            terminal.sessions = await self.sessionSummaries()
            self.emit(terminal)
            self.removeRun(runID)
        }
        storeRun(task, for: runID)
    }

    private func broadcastState() async {
        var plugins = FrontendEvent(event: "plugins.changed")
        plugins.plugins = await pluginSummaries()
        emit(plugins)
        var models = FrontendEvent(event: "models.changed")
        models.models = await offeredModels()
        models.modelDetails = await offeredModelDetails()
        models.preferredModel = await settings.preferredModelHint(
            bundleIDs: await registry.all().map(\.bundleID)
        )
        emit(models)
    }

    private func offeredModels() async -> [String] {
        await router.offeredModels.map(\.rawValue).sorted()
    }

    /// Model metadata for the frontend. Filtered by the router's accepted routes so a declaration
    /// that lost a duplicate-id race never appears as an offered model.
    private func offeredModelDetails() async -> [ModelSummary] {
        let offered = Set(await router.offeredModels.map(\.rawValue))
        var seen = Set<String>()
        var result: [ModelSummary] = []
        for entry in await coordinator.modelDeclarations() {
            guard offered.contains(entry.model.id), seen.insert(entry.model.id).inserted else { continue }
            result.append(ModelSummary(
                id: entry.model.id,
                provider: entry.providerID,
                thinkingLevels: (entry.model.thinkingLevels ?? []).map {
                    ModelThinkingLevel(id: $0.id, label: $0.label)
                },
                defaultThinkingLevel: entry.model.defaultThinkingLevel
            ))
        }
        return result.sorted { $0.id < $1.id }
    }

    private func sessionSummaries() async -> [SessionSummary] {
        var summaries: [SessionSummary] = []
        for sessionID in await store.sessionIDs() {
            let entries = await store.entries(for: sessionID)
            let title = entries.first {
                $0.role == .user && ($0.segment == .currentUser || $0.segment == .history)
            }?.renderedText ?? "(empty)"
            let turns = entries.filter {
                $0.role == .user && ($0.segment == .currentUser || $0.segment == .history)
            }.count
            summaries.append(SessionSummary(
                id: sessionID.rawValue,
                title: title.count > 60 ? String(title.prefix(60)) + "…" : title,
                turns: turns
            ))
        }
        return summaries.sorted { $0.id < $1.id }
    }

    private func history(for sessionID: String) async -> [HistoryEntry] {
        let entries = await store.entries(for: SessionID(sessionID))
        var history: [HistoryEntry] = []
        for entry in entries {
            switch entry.payload {
            case .text(let text):
                if entry.segment == .immutableInstructions || entry.segment == .derivedPage { continue }
                history.append(HistoryEntry(role: entry.role.rawValue, text: text, kind: "message"))
            case .assistantMessage(let text, let calls):
                if !text.isEmpty {
                    history.append(HistoryEntry(role: "assistant", text: text, kind: "message"))
                }
                for call in calls {
                    history.append(HistoryEntry(
                        role: "assistant", text: "\(call.toolName) \(call.argumentsJSON)", kind: "toolCall"
                    ))
                }
            case .toolCall(let calls):
                for call in calls {
                    history.append(HistoryEntry(
                        role: "assistant", text: "\(call.toolName) \(call.argumentsJSON)", kind: "toolCall"
                    ))
                }
            case .toolResult(let outcomes):
                for outcome in outcomes {
                    history.append(HistoryEntry(role: "tool", text: outcome.content, kind: "tool"))
                }
            }
        }
        return history
    }

    private func pluginSummaries() async -> [PluginSummary] {
        var summaries: [PluginSummary] = []
        for entry in await registry.all() {
            summaries.append(PluginSummary(
                bundleID: entry.bundleID,
                version: entry.version,
                enabled: entry.enabled,
                running: await coordinator.isRunning(bundleID: entry.bundleID),
                capabilities: entry.capabilities ?? [],
                permissions: entry.permissions ?? []
            ))
        }
        return summaries
    }

    private func storeRun(_ task: Task<Void, Never>, for runID: String) {
        lock.lock(); runs[runID] = task; lock.unlock()
    }

    private func takeRun(_ runID: String) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }; return runs[runID]
    }

    private func removeRun(_ runID: String) {
        lock.lock(); runs.removeValue(forKey: runID); lock.unlock()
    }

    private func emit(_ event: FrontendEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        lock.lock()
        output.write(data + Data([UInt8(ascii: "\n")]))
        lock.unlock()
    }

    private func send(_ reply: FrontendReply) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        lock.lock()
        output.write(data + Data([UInt8(ascii: "\n")]))
        lock.unlock()
    }
}

