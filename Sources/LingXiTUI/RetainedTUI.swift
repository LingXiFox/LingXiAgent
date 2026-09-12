import Foundation
import LingXiApplication
import LingXiClient
import LingXiProtocol
import LingXiTUIComponents

private enum UIEvent: Sendable {
    case input(TUIInputEvent)
    case core(CoreEvent)
    case chunk(StreamChunk)
    case toolOutput(ToolOutputChunk)
    case streamFailed(String)
    case tick
}

private enum CommandAction: Sendable {
    case model, connect, providers, newSession, resume, history, rename
    case status, context, compact, perf, mode, permissions
    case subagents, mcp, skills, plugins, hooks, diff, ps, stop, clear, help, quit
}

private enum CommandAvailability: Sendable {
    case always
    case requiresSession
}

private struct CommandDescriptor: Sendable {
    let name: String
    let aliases: [String]
    let description: String
    let category: String
    let argumentSchema: String
    let action: CommandAction
    let availability: CommandAvailability

    init(name: String, aliases: [String], description: String, category: String, argumentSchema: String, action: CommandAction, availability: CommandAvailability = .always) {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.category = category
        self.argumentSchema = argumentSchema
        self.action = action
        self.availability = availability
    }

    func matches(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return name.lowercased().contains(normalized) || aliases.contains { $0.lowercased().contains(normalized) } || description.lowercased().contains(normalized)
    }

    func isAvailable(hasSession: Bool) -> Bool {
        switch availability {
        case .always: true
        case .requiresSession: hasSession
        }
    }
}

private enum Overlay: Sendable {
    case command
    case commandPalette
    case completion(items: [TUICompletionItem], selected: Int, tokenStart: Int)
    case picker(title: String, items: [String], selected: Int, action: PickerAction)
    case permission(PermissionRequest)
    case question(QuestionRequest, selected: Int)
    case credential(flowID: String)
    case endpoint(flowID: String)
}

private enum PickerAction: Sendable {
    case model
    case session
    case provider
    case mode
    case permissions
    case recovery(runID: AgentRunID)
}

private enum TranscriptKind: String, Sendable {
    case user = "User"
    case assistant = "Assistant"
    case thinking = "Thinking"
    case read = "Read"
    case search = "Search"
    case edit = "Edit"
    case patch = "Patch"
    case write = "Write"
    case shell = "Shell"
    case git = "Git"
    case mcp = "MCP"
    case toolCall = "ToolCall"
    case toolResult = "ToolResult"
    case subagent = "Subagent"
    case question = "Question"
    case permission = "Permission"
    case decision = "Decision"
    case error = "Error"
    case result = "Result"
}


public enum TUIWorkingPhase: Sendable, Equatable {
    case ready
    case thinking
    case runningTool(name: String)
    case waitingForProvider
    case runningSubagents(count: Int)
    case paging
    case actionRequired(prompt: String)
    case error(message: String)
    case disconnected

    public var isAnimated: Bool {
        switch self {
        case .thinking, .runningTool, .waitingForProvider, .runningSubagents, .paging:
            return true
        case .ready, .actionRequired, .error, .disconnected:
            return false
        }
    }
}

final class RetainedTUI: @unchecked Sendable {
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerFrameIndex = 0
    private var workingPhase: TUIWorkingPhase = .ready
    private var runningSubagentIDs: Set<AgentRunID> = []

    private let terminal: any TerminalBackend = POSIXTerminalBackend()
    private let app = TUIApp()
    private let slashCompletion = SlashCompletionView()
    private let registry: [CommandDescriptor] = [
        CommandDescriptor(name: "model", aliases: [], description: "选择模型", category: "Provider", argumentSchema: "[provider/model]", action: .model),
        CommandDescriptor(name: "connect", aliases: [], description: "连接 Provider", category: "Provider", argumentSchema: "", action: .connect),
        CommandDescriptor(name: "providers", aliases: [], description: "查看 Provider", category: "Provider", argumentSchema: "", action: .providers),
        CommandDescriptor(name: "new", aliases: [], description: "新建 Session", category: "Session", argumentSchema: "", action: .newSession),
        CommandDescriptor(name: "resume", aliases: [], description: "恢复 Session", category: "Session", argumentSchema: "", action: .resume),
        CommandDescriptor(name: "history", aliases: [], description: "查看当前 transcript", category: "Session", argumentSchema: "", action: .history, availability: .requiresSession),
        CommandDescriptor(name: "rename", aliases: [], description: "重命名 Session", category: "Session", argumentSchema: "<title>", action: .rename, availability: .requiresSession),
        CommandDescriptor(name: "status", aliases: [], description: "查看运行状态", category: "Runtime", argumentSchema: "", action: .status, availability: .requiresSession),
        CommandDescriptor(name: "context", aliases: [], description: "查看 L1/L2/L3 context", category: "Runtime", argumentSchema: "", action: .context, availability: .requiresSession),
        CommandDescriptor(name: "compact", aliases: [], description: "压缩当前 context", category: "Runtime", argumentSchema: "", action: .compact, availability: .requiresSession),
        CommandDescriptor(name: "perf", aliases: [], description: "查看性能报告", category: "Runtime", argumentSchema: "", action: .perf, availability: .requiresSession),
        CommandDescriptor(name: "mode", aliases: [], description: "切换 Agent 行为模式", category: "Runtime", argumentSchema: "build|plan|explore", action: .mode),
        CommandDescriptor(name: "permissions", aliases: ["permission"], description: "切换权限配置", category: "Runtime", argumentSchema: "ask|auto|yolo", action: .permissions),
        CommandDescriptor(name: "subagents", aliases: [], description: "查看 Subagent 树", category: "Execution", argumentSchema: "", action: .subagents, availability: .requiresSession),
        CommandDescriptor(name: "mcp", aliases: [], description: "查看 MCP 状态", category: "Execution", argumentSchema: "", action: .mcp),
        CommandDescriptor(name: "skills", aliases: [], description: "查看可用 Skills", category: "Extensions", argumentSchema: "", action: .skills),
        CommandDescriptor(name: "plugins", aliases: [], description: "查看 Plugins", category: "Extensions", argumentSchema: "", action: .plugins),
        CommandDescriptor(name: "hooks", aliases: [], description: "查看 Hooks", category: "Extensions", argumentSchema: "", action: .hooks),
        CommandDescriptor(name: "diff", aliases: [], description: "查看 workspace diff", category: "Workspace", argumentSchema: "", action: .diff),
        CommandDescriptor(name: "ps", aliases: [], description: "查看 AgentRun", category: "Execution", argumentSchema: "", action: .ps, availability: .requiresSession),
        CommandDescriptor(name: "stop", aliases: [], description: "停止当前运行", category: "Execution", argumentSchema: "[runID]", action: .stop, availability: .requiresSession),
        CommandDescriptor(name: "clear", aliases: [], description: "清空本地 transcript 视图", category: "UI", argumentSchema: "", action: .clear),
        CommandDescriptor(name: "help", aliases: [], description: "查看命令", category: "UI", argumentSchema: "", action: .help),
        CommandDescriptor(name: "quit", aliases: ["exit"], description: "退出 TUI", category: "UI", argumentSchema: "", action: .quit),
    ]

    private let projector = TUITimelineProjector()
    private var composer = ""
    private var overlay: Overlay?
    private var commandSelection = 0
    private var sessionID: SessionID?
    private var activeModel = "未选择模型"
    private var providerConfigured = false
    private var runtimeState = "Ready"
    private var working = false
    private var shouldQuit = false
    private var permissionConfiguration = PermissionConfiguration.strict
    private var behaviorProfile = AgentBehaviorProfile.build
    private var contextProjection: ContextCacheProjection?
    private var gitBranchName = "-"
    private var secretInput = false
    private var client: LingXiClient?
    private var providerService: ProviderConnectionService?
    private var eventContinuation: AsyncStream<UIEvent>.Continuation?
    private var visibleRunIDs: Set<AgentRunID> = []
    private var previousFocus: TUIFocus = .composer
    private var referenceCandidates: [String] = []
    private var providerActivities: [String: ProviderActivitySnapshot] = [:]

    func run() async {
        do {
            try terminal.start()
            defer { terminal.stop() }
            let client = try LingXiClient.stdioCore(interactive: true)
            self.client = client
            providerService = ProviderConnectionService(client: client)
            let stream = AsyncStream<UIEvent>.makeStream()
            eventContinuation = stream.continuation
            let inputTask = Task { [terminal] in
                while !Task.isCancelled, let input = terminal.nextInput() { stream.continuation.yield(.input(input)) }
            }
            let coreTask = Task {
                for await event in await client.events() { stream.continuation.yield(.core(event)) }
            }
            let toolOutputTask = Task {
                for await chunk in await client.toolOutputEvents() { stream.continuation.yield(.toolOutput(chunk)) }
            }
            await bootstrap(client)
            render()
            for await event in stream.stream {
                await handle(event)
                if shouldQuit { break }
                if case .input(.tick) = event {
                    if workingPhase.isAnimated {
                        spinnerFrameIndex = (spinnerFrameIndex + 1) % Self.spinnerFrames.count
                        let scrollHint = app.transcript.showsBackToCurrent ? " · ↓ Back to current" : ""
                        let (left, right) = statusLineParts(scrollHint: scrollHint)
                        app.statusLine.setParts(left: left, right: right)
                        terminal.render(app.render(size: terminal.size, overlay: overlay.map(overlayModel)))
                    }
                    continue
                }
                render()
            }
            inputTask.cancel()
            coreTask.cancel()
            toolOutputTask.cancel()
            await client.close()
        } catch {
            print("LingXiTUI 启动失败: \(error)")
        }
    }

    private func bootstrap(_ client: LingXiClient) async {
        do {
            let status = try await client.providerStatus()
            providerConfigured = status.configured
            runtimeState = status.configured ? "Ready" : "Disconnected"
            workingPhase = status.configured ? .ready : .disconnected
            activeModel = status.model ?? activeModel
            gitBranchName = detectGitBranch()
            permissionConfiguration = try await client.permissionConfiguration()
            behaviorProfile = try await client.agentBehaviorProfile()
            sessionID = try await client.createSession()
            let sessions = try await client.sessions()
            var resumable: [AgentRunInfo] = []
            for session in sessions {
                resumable.append(contentsOf: try await client.listAgentRuns(session.id).filter { !$0.status.isTerminal })
            }
            if let run = resumable.sorted(by: { $0.latestActivityAt > $1.latestActivityAt }).first {
                overlay = .picker(title: "发现未完成运行", items: ["Resume \(run.runID.rawValue)", "Abandon \(run.runID.rawValue)"], selected: 0, action: .recovery(runID: run.runID))
            }
            await refreshContext(client)
        } catch { append(.error, "启动状态读取失败: \(error)") }
    }

    private func handle(_ event: UIEvent) async {
        switch event {
        case let .input(input): await handleInput(input)
        case let .core(event): await handleCore(event)
        case let .chunk(chunk):
            guard working else { return }
            guard let sessionID, (chunk.sessionID == nil || chunk.sessionID == sessionID) else { return }
            runtimeState = "Working"
            if chunk.kind == .reasoning {
                workingPhase = .thinking
            } else if workingPhase == .thinking {
                workingPhase = .waitingForProvider
            }
            projector.consume(chunk: chunk)
        case let .toolOutput(chunk):
            guard let sessionID, (chunk.sessionID == nil || chunk.sessionID == sessionID) else { return }
            projector.consume(toolOutput: chunk)
        case let .streamFailed(message):
            working = false; runtimeState = "Error"; workingPhase = .error(message: message); projector.consume(streamFailed: message)
        case .tick: break
        }
    }

    private func handleCore(_ event: CoreEvent) async {
        switch event {
        case let .providerActivityChanged(snapshot):
            guard snapshot.sessionID == sessionID else { return }
            if snapshot.state.isTerminal {
                providerActivities.removeValue(forKey: snapshot.providerRequestID)
            } else {
                providerActivities[snapshot.providerRequestID] = snapshot
            }
            if !working {
                workingPhase = .ready
            } else if !runningSubagentIDs.isEmpty {
                workingPhase = .runningSubagents(count: runningSubagentIDs.count)
            } else if snapshot.state == .waitingForRateBudget {
                workingPhase = .waitingForProvider
            } else if snapshot.state == .requesting {
                workingPhase = .waitingForProvider
            } else if snapshot.state == .streaming {
                workingPhase = .thinking
            }
        case let .turnStarted(handle):
            guard sessionID == handle.sessionID else { return }
            working = true
            runtimeState = "Working"
            workingPhase = .waitingForProvider
        case let .turnCompleted(result):
            guard sessionID == result.sessionID else { return }
            working = false; runtimeState = "Ready"
            workingPhase = .ready
            runningSubagentIDs.removeAll()
            providerActivities.removeAll()
            projector.consume(turnCompleted: result)
            if let client { await refreshContext(client) }
        case let .turnFailed(failure):
            guard sessionID == failure.sessionID else { return }
            working = false
            runningSubagentIDs.removeAll()
            providerActivities.removeAll()
            if failure.error.code == .toolCancelled {
                runtimeState = "Ready"
                workingPhase = .ready
                appendCancelledItemOnce()
            } else {
                runtimeState = "Error"
                workingPhase = .error(message: failure.error.message)
                projector.consume(turnFailed: failure)
            }
        case let .toolCallCompleted(call):
            guard call.sessionID == nil || call.sessionID == sessionID else { return }
            workingPhase = .runningTool(name: call.toolID.rawValue)
            projector.consume(toolCall: call)
        case let .toolResult(result):
            guard result.sessionID == nil || result.sessionID == sessionID else { return }
            if !runningSubagentIDs.isEmpty {
                workingPhase = .runningSubagents(count: runningSubagentIDs.count)
            } else {
                workingPhase = .waitingForProvider
            }
            projector.consume(toolResult: result)
        case let .permissionAsked(request):
            guard sessionID == request.sessionID else { return }
            runtimeState = "Action Required"
            workingPhase = .actionRequired(prompt: "Permission required · \(request.toolID.rawValue)")
            openPermission(request)
        case let .questionAsked(request), let .questionEscalated(request):
            guard request.originSessionID == nil || request.originSessionID == sessionID else { return }
            runtimeState = "Action Required"
            workingPhase = .actionRequired(prompt: "Question: \(request.question)")
            openQuestion(request)
        case let .subagentSpawned(run), let .agentRunQueued(run), let .agentRunStarted(run), let .agentRunStatusChanged(run), let .agentRunCompleted(run), let .agentRunFailed(run), let .agentRunCancelled(run):
            if run.parentRunID == nil {
                guard run.sessionID == sessionID else { return }
                visibleRunIDs.insert(run.runID)
                if run.status == .cancelled {
                    working = false
                    runtimeState = "Ready"
                    workingPhase = .ready
                    runningSubagentIDs.removeAll()
                    providerActivities.removeAll()
                    appendCancelledItemOnce()
                }
            } else {
                guard let parentRunID = run.parentRunID, visibleRunIDs.contains(parentRunID) else { return }
                visibleRunIDs.insert(run.runID)
                projector.consume(agentRun: run)
                if run.status == .running || run.status == .queued {
                    runningSubagentIDs.insert(run.runID)
                } else {
                    runningSubagentIDs.remove(run.runID)
                }
            }
            if !runningSubagentIDs.isEmpty {
                workingPhase = .runningSubagents(count: runningSubagentIDs.count)
            } else if working {
                workingPhase = .waitingForProvider
            } else {
                workingPhase = .ready
            }
        case .stateChanged, .childSessionCreated, .subagentResultAvailable, .sessionCreated: break
        }
    }

    private func handleInput(_ input: TUIInputEvent) async {
        if input == .escape, working {
            await stopCommand([])
            return
        }
        if case .permission = overlay {
            await handlePermissionInput(input)
            return
        }
        if case let .question(request, selected) = overlay {
            await handleQuestionInput(input, request: request, selected: selected)
            return
        }
        if case let .picker(title, items, selected, action) = overlay {
            await handlePickerInput(input, title: title, items: items, selected: selected, action: action)
            return
        }
        if case let .credential(flowID) = overlay {
            await handleCredentialInput(input, flowID: flowID)
            return
        }
        if case let .endpoint(flowID) = overlay {
            await handleEndpointInput(input, flowID: flowID)
            return
        }
        if case let .completion(items, selected, tokenStart) = overlay {
            await handleCompletionInput(input, items: items, selected: selected, tokenStart: tokenStart)
            return
        }
        if case .commandPalette = overlay {
            await handleCommandPaletteInput(input)
            return
        }
        if case .command = overlay {
            let candidates = commandCandidates()
            switch input {
            case .backspace:
                _ = app.composer.handle(input)
                syncComposer()
                if composer.isEmpty { overlay = nil }
            case .character, .paste:
                _ = app.composer.handle(input)
                syncComposer()
            case .up, .down:
                slashCompletion.handle(input)
                commandSelection = slashCompletion.selectedIndex
            case .escape: overlay = nil
            case .tab:
                guard candidates.indices.contains(commandSelection) else { return }
                completeCommand(candidates[commandSelection])
            case .enter:
                guard candidates.indices.contains(commandSelection) else { overlay = nil; return }
                let typed = composer.dropFirst().split(whereSeparator: \ .isWhitespace).map(String.init)
                composer = "/\(candidates[commandSelection].name)" + (typed.dropFirst().isEmpty ? "" : " \(typed.dropFirst().joined(separator: " "))")
                overlay = nil
                await submit()
            default: break
            }
            return
        }
        switch input {
        case .enter where app.focus == .transcript:
            app.transcript.toggleSelectedCollapse()
        case .enter: await submit()
        case .character(" ") where app.focus == .transcript:
            app.transcript.toggleSelectedCollapse()
        case .left where app.focus == .transcript:
            app.transcript.collapseSelected()
        case .right where app.focus == .transcript:
            app.transcript.expandSelected()
        case .escape where app.focus == .transcript:
            app.transcript.clearSelection()
            app.setFocus(.composer)
        case .character, .paste, .backspace, .delete, .deleteWordBackward, .left, .right, .home, .end, .shiftEnter:
            app.setFocus(.composer)
            let action = app.composer.handle(input)
            syncComposer()
            if action == .submit { await submit() }
            updateCompletion()
        case .escape: composer.removeAll(); app.composer.clear(); overlay = nil
        case .pageUp, .pageDown, .scrollUp, .scrollDown: app.handleTranscriptInput(input, viewportHeight: max(1, terminal.size.height - 8))
        case .up where app.composer.isEmpty:
            app.setFocus(.transcript)
            app.transcript.selectPrevious()
            app.handleTranscriptInput(input, viewportHeight: max(1, terminal.size.height - 8))
        case .down where app.composer.isEmpty:
            app.setFocus(.transcript)
            app.transcript.selectNext()
            app.handleTranscriptInput(input, viewportHeight: max(1, terminal.size.height - 8))
        case .up:
            if app.focus == .transcript {
                app.transcript.selectPrevious()
            } else {
                app.setFocus(.composer)
                let action = app.composer.handle(input)
                syncComposer()
                if action == .submit { await submit() }
                updateCompletion()
            }
        case .down:
            if app.focus == .transcript {
                app.transcript.selectNext()
            } else {
                app.setFocus(.composer)
                let action = app.composer.handle(input)
                syncComposer()
                if action == .submit { await submit() }
                updateCompletion()
            }
        case .interrupt, .quit: shouldQuit = true
        case .resize, .tick, .mouseClick: break
        case .shiftTab: await cycleBehaviorProfile()
        case .tab: completeActiveCompletion()
        case .commandPalette: openCommandPalette()
        case .cycleReasoningEffort: break
        }
    }

    private func submit() async {
        let value = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.removeAll()
        guard !value.isEmpty else { return }
        guard value.first == "/" else {
            guard let client, let sessionID else { append(.error, "Session 不可用"); return }
            if working { append(.error, "当前 Session 正在执行"); return }
            append(.user, value); working = true; runtimeState = "Working"
            let continuation = eventContinuation
            Task {
                do {
                    let stream = try await client.sendMessage(sessionID: sessionID, content: value)
                    for try await chunk in stream { continuation?.yield(.chunk(chunk)) }
                } catch { continuation?.yield(.streamFailed(String(describing: error))) }
            }
            return
        }
        await routeCommand(value)
    }

    private func routeCommand(_ raw: String) async {
        let parts = raw.dropFirst().split(whereSeparator: \ .isWhitespace).map(String.init)
        guard let name = parts.first, let descriptor = registry.first(where: { $0.name == name || $0.aliases.contains(name) }) else { append(.error, "未知命令: \(raw)"); return }
        guard descriptor.isAvailable(hasSession: sessionID != nil) else { append(.error, "命令当前不可用: \(raw)"); return }
        let args = Array(parts.dropFirst())
        switch descriptor.action {
        case .model: await modelCommand(args)
        case .connect: await connectCommand()
        case .providers: await providersCommand()
        case .newSession: await newSession()
        case .resume: await resumeCommand()
        case .history: if let client, let sessionID { await loadTranscript(client, id: sessionID) }
        case .rename: await renameCommand(args)
        case .status: await refreshStatus()
        case .context: await contextCommand()
        case .compact: await compactCommand()
        case .perf: await perfCommand()
        case .mode: await modeCommand(args)
        case .permissions: await permissionsCommand(args)
        case .subagents: await subagentsCommand()
        case .mcp: await mcpCommand()
        case .skills: await extensionCommand(.skill)
        case .plugins: await extensionCommand(.plugin)
        case .hooks: await extensionCommand(.hook)
        case .diff: await diffCommand()
        case .ps: await psCommand()
        case .stop: await stopCommand(args)
        case .clear: projector.reset()
        case .help: append(.result, registry.map { "/\($0.name)  \($0.description)" }.joined(separator: "\n"))
        case .quit: shouldQuit = true
        }
    }

    private func modelCommand(_ args: [String]) async {
        guard let client else { return }
        do {
            let models = try await client.listProviderModels()
            if let value = args.first { _ = try await client.selectProviderModel(value); activeModel = value; providerConfigured = true; append(.result, "模型已选择: \(value)"); return }
            guard !models.isEmpty else { append(.error, "没有可用模型；先配置 providers.json 或执行 /connect"); return }
            overlay = .picker(title: "Select model", items: models.map { "\($0.providerID)/\($0.modelID) · \($0.displayName)" }, selected: max(0, models.firstIndex { "\($0.providerID)/\($0.modelID)" == activeModel } ?? 0), action: .model)
        } catch { append(.error, String(describing: error)) }
    }

    private func connectCommand() async {
        guard let service = providerService else { return }
        do {
            let products = try await service.listConnectableProducts()
            overlay = .picker(title: "Connect provider", items: products.map(\.displayName), selected: 0, action: .provider)
        } catch { append(.error, String(describing: error)) }
    }

    private func providersCommand() async {
        guard let client else { return }
        do {
            let accounts = try await client.listProviderAccounts()
            let models = try await client.listProviderModels()
            append(.result, (accounts.map { "\($0.displayName) · \($0.productID) · \($0.availability)" } + models.map { "\($0.providerID)/\($0.modelID) · \($0.displayName)" }).joined(separator: "\n").ifEmpty("没有 Provider 配置"))
        } catch { append(.error, String(describing: error)) }
    }

    private func newSession() async {
        guard let client else { return }
        do { sessionID = try await client.createSession(); resetPresentation(); append(.result, "新 Session 已创建") }
        catch { append(.error, String(describing: error)) }
    }

    private func resumeCommand() async {
        guard let client else { return }
        do {
            let sessions = try await client.sessions()
            guard !sessions.isEmpty else { append(.result, "没有可恢复的 Session"); return }
            overlay = .picker(title: "Resume session", items: sessions.map { "\($0.title ?? "Untitled") · \($0.id.rawValue.prefix(8)) · \($0.messageCount) messages" }, selected: 0, action: .session)
        } catch { append(.error, String(describing: error)) }
    }

    private func renameCommand(_ args: [String]) async {
        guard let client, let sessionID, !args.isEmpty else { append(.error, "用法: /rename <title>"); return }
        do { _ = try await client.renameSession(sessionID, title: args.joined(separator: " ")); append(.result, "Session 已重命名") }
        catch { append(.error, String(describing: error)) }
    }

    private func refreshStatus() async {
        guard let client else { return }
        do { let status = try await client.providerStatus(); providerConfigured = status.configured; activeModel = status.model ?? activeModel; permissionConfiguration = try await client.permissionConfiguration(); behaviorProfile = try await client.agentBehaviorProfile(); await refreshContext(client); append(.result, "Provider \(status.configured ? "configured" : "disconnected") · \(status.model ?? "未选择模型")") }
        catch { append(.error, String(describing: error)) }
    }

    private func contextCommand() async {
        guard let client, let sessionID else { return }
        do {
            guard let projection = try await client.contextProjection(sessionID) else { append(.result, "Context projection unavailable"); return }
            append(.result, contextDetails(projection))
            await refreshContext(client)
        } catch { append(.error, String(describing: error)) }
    }

    private func compactCommand() async { guard let client, let sessionID else { return }; do { let result = try await client.compact(sessionID); append(.result, "Compaction \(result.beforeEstimatedTokens) -> \(result.afterEstimatedTokens) tokens"); await refreshContext(client) } catch { append(.error, String(describing: error)) } }
    private func perfCommand() async { guard let client, let sessionID else { return }; do { let result = try await client.performance(sessionID); append(.result, result.map { "Turn \(String(format: "%.1f", $0.totalMilliseconds)) ms · steps \($0.stepCount)" } ?? "性能报告不可用") } catch { append(.error, String(describing: error)) } }

    private func permissionsCommand(_ args: [String]) async {
        guard let client else { return }
        let configuration: PermissionConfiguration?
        switch args.first?.lowercased() {
        case "ask": configuration = .strict
        case "auto": configuration = .agent
        case "yolo": configuration = .yolo
        case nil: configuration = nil
        default: append(.error, "用法: /permissions ask|auto|yolo"); return
        }
        guard let configuration else { overlay = .picker(title: "Permissions", items: ["Ask", "Auto", "YOLO"], selected: permissionPickerIndex, action: .permissions); return }
        do { try await client.setPermissionConfiguration(configuration); permissionConfiguration = configuration; append(.result, "permissions: \(permissionSummary)") } catch { append(.error, String(describing: error)) }
    }

    private func modeCommand(_ args: [String]) async {
        guard let client else { return }
        let profile: AgentBehaviorProfile?
        switch args.first?.lowercased() {
        case "build": profile = .build
        case "plan": profile = .plan
        case "explore": profile = .explore
        case nil: profile = nil
        default: append(.error, "用法: /mode build|plan|explore"); return
        }
        guard let profile else { overlay = .picker(title: "Agent mode", items: ["Build", "Plan", "Explore"], selected: modePickerIndex, action: .mode); return }
        do { try await client.setAgentBehaviorProfile(profile); behaviorProfile = profile; append(.result, "mode: \(profile.displayName)") } catch { append(.error, String(describing: error)) }
    }

    private func subagentsCommand() async { guard let client, let sessionID else { return }; do { let tree = try await client.getAgentTree((try await client.session(sessionID)).rootSessionID); append(.subagent, renderTree(tree)) } catch { append(.error, String(describing: error)) } }
    private func psCommand() async { guard let client, let sessionID else { return }; do { append(.result, try await client.listAgentRuns(sessionID).map { "\($0.runID.rawValue) · \($0.status.rawValue) · \($0.modelSelection.modelID)" }.joined(separator: "\n").ifEmpty("没有 AgentRun")) } catch { append(.error, String(describing: error)) } }
    private func appendCancelledItemOnce() {
        if !projector.items.contains(where: { $0.state == .cancelled && $0.title == "Cancelled by user" }) {
            projector.appendItem(TUITimelineItem(
                id: "cancelled-\(UUID().uuidString.prefix(8))",
                kind: .result,
                title: "Cancelled by user",
                summary: "Cancelled by user",
                details: [],
                state: .cancelled,
                collapsed: false
            ))
        }
    }

    private func stopCommand(_ args: [String]) async {
        guard let client, let sessionID else { return }
        working = false
        runtimeState = "Ready"
        workingPhase = .ready
        runningSubagentIDs.removeAll()
        providerActivities.removeAll()
        appendCancelledItemOnce()
        do {
            let runs = try await client.listAgentRuns(sessionID)
            guard let run = args.first.flatMap({ value in runs.first { $0.runID.rawValue == value } }) ?? runs.last(where: { !$0.status.isTerminal }) else {
                return
            }
            try await client.cancelAgentRun(run.runID)
        } catch {
            // Cancel requested
        }
    }

    private func mcpCommand() async { guard let client else { return }; do { let bundle = try await client.diagnostics(); append(.result, "MCP tools \(bundle.mcp.catalogTools) · schemas \(bundle.mcp.schemaFiles) · leases \(bundle.mcp.activeLeases) · page faults \(bundle.mcp.pageFaults)") } catch { append(.error, String(describing: error)) } }
    private func extensionCommand(_ kind: ExtensionKind) async { guard let client else { return }; do { let values = try await client.listExtensions(kind: kind); append(.result, values.map { "\($0.id) · \($0.scope) · \($0.lifecycleState)\($0.enabled ? "" : " · disabled")" }.joined(separator: "\n").ifEmpty("没有可用 \(kind.rawValue)")) } catch { append(.error, String(describing: error)) } }
    private func diffCommand() async { guard let client else { return }; do { append(.result, try await client.workspaceDiff().ifEmpty("工作区无未提交 diff")) } catch { append(.error, String(describing: error)) } }

    private func handlePickerInput(_ input: TUIInputEvent, title: String, items: [String], selected: Int, action: PickerAction) async {
        var index = selected
        switch input {
        case .up: index = max(0, index - 1)
        case .down: index = min(items.count - 1, index + 1)
        case .escape: overlay = nil
        case .enter: await selectPicker(index, action: action)
        default: break
        }
        if case .picker = overlay { overlay = .picker(title: title, items: items, selected: index, action: action) }
    }

    private func selectPicker(_ index: Int, action: PickerAction) async {
        guard let client else { return }
        overlay = nil
        switch action {
        case .model:
            do { let models = try await client.listProviderModels(); guard models.indices.contains(index) else { return }; let value = "\(models[index].providerID)/\(models[index].modelID)"; _ = try await client.selectProviderModel(value); activeModel = value; providerConfigured = true; append(.result, "模型已选择: \(value)") } catch { append(.error, String(describing: error)) }
        case .session:
            do { let sessions = try await client.sessions(); guard sessions.indices.contains(index) else { return }; sessionID = sessions[index].id; resetPresentation(); await loadTranscript(client, id: sessions[index].id); await promptRecoveryIfNeeded(client, sessionID: sessions[index].id) } catch { append(.error, String(describing: error)) }
        case .mode: await modeCommand([["build", "plan", "explore"][index]])
        case .permissions: await permissionsCommand([["ask", "auto", "yolo"][index]])
        case .provider: await beginProvider(index)
        case let .recovery(runID):
            do {
                if index == 0 {
                    let run = try await client.resumeAgentRun(runID)
                    sessionID = run.sessionID
                    resetPresentation()
                    await loadTranscript(client, id: run.sessionID)
                    append(.result, "已恢复运行: \(runID.rawValue)")
                } else {
                    try await client.cancelAgentRun(runID)
                    append(.result, "已放弃运行: \(runID.rawValue)")
                }
            } catch { append(.error, String(describing: error)) }
        }
    }

    private func beginProvider(_ index: Int) async {
        guard let service = providerService else { return }
        do {
            let products = try await service.listConnectableProducts(); guard products.indices.contains(index) else { return }; let flowID = try await service.beginConnection(productID: products[index].id); let state = try await service.state(flowID: flowID)
            switch state { case .requestingCredential: secretInput = true; overlay = .credential(flowID: flowID); case .requestingLocalEndpoint: secretInput = false; overlay = .endpoint(flowID: flowID); default: append(.result, "Provider 连接状态: \(String(describing: state))") }
        } catch { append(.error, String(describing: error)) }
    }

    private func handleCredentialInput(_ input: TUIInputEvent, flowID: String) async {
        switch input { case .backspace: if !composer.isEmpty { composer.removeLast() }; case let .character(c): composer.append(c); case .escape: overlay = nil; secretInput = false; composer.removeAll(); case .enter: do { _ = try await providerService?.submitCredential(flowID: flowID, credential: composer); composer.removeAll(); overlay = nil; secretInput = false; providerConfigured = true; runtimeState = "Ready"; append(.result, "Provider credential 已保存并连接") } catch { append(.error, String(describing: error)) }; default: break }
    }

    private func handleEndpointInput(_ input: TUIInputEvent, flowID: String) async {
        switch input { case .backspace: if !composer.isEmpty { composer.removeLast() }; case let .character(c): composer.append(c); case .escape: overlay = nil; composer.removeAll(); case .enter: do { _ = try await providerService?.submitLocalEndpoint(flowID: flowID, endpoint: composer); composer.removeAll(); overlay = nil; append(.result, "Provider endpoint 已连接") } catch { append(.error, String(describing: error)) }; default: break }
    }

    private func handlePermissionInput(_ input: TUIInputEvent) async {
        guard case let .permission(request) = overlay else { return }
        switch input { case .up, .left: await replyPermission(request, decision: .deny); case .down, .right, .enter: await replyPermission(request, decision: .allow); case .escape: await replyPermission(request, decision: .deny); default: break }
    }

    private func replyPermission(_ request: PermissionRequest, decision: PermissionDecision) async {
        do { try await client?.replyPermission(PermissionReply(permissionID: request.permissionID, decision: decision)); overlay = nil; runtimeState = "Working" } catch { append(.error, String(describing: error)) }
    }

    private func handleQuestionInput(_ input: TUIInputEvent, request: QuestionRequest, selected: Int) async {
        var index = selected
        switch input {
        case .up: index = max(0, index - 1)
        case .down: index = min(max(0, request.options.count - 1), index + 1)
        case .escape: await replyQuestion(request, selectedOptionIndices: [], cancelled: true)
        case .enter: if request.options.indices.contains(index) { await replyQuestion(request, selectedOptionIndices: [index], cancelled: false) } else if request.allowsFreeText { await replyQuestion(request, text: composer, cancelled: composer.isEmpty) }
        case .backspace: if request.allowsFreeText, !composer.isEmpty { composer.removeLast() }
        case let .character(character): if request.allowsFreeText { composer.append(character) }
        default: break
        }
        if overlay != nil { overlay = .question(request, selected: index) }
    }

    private func replyQuestion(_ request: QuestionRequest, selectedOptionIndices: [Int] = [], text: String? = nil, cancelled: Bool) async {
        do { try await client?.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: selectedOptionIndices, text: text, cancelled: cancelled)); composer.removeAll(); overlay = nil; runtimeState = "Working" } catch { append(.error, String(describing: error)) }
    }

    private func loadTranscript(_ client: LingXiClient, id: SessionID) async {
        do {
            let snapshot = try await client.session(id)
            projector.consume(persistedMessages: snapshot.messages)
        } catch { append(.error, String(describing: error), state: .failed) }
    }

    private func promptRecoveryIfNeeded(_ client: LingXiClient, sessionID: SessionID) async {
        do {
            guard let run = try await client.listAgentRuns(sessionID).filter({ !$0.status.isTerminal }).sorted(by: { $0.latestActivityAt > $1.latestActivityAt }).first else { return }
            overlay = .picker(title: "发现未完成运行", items: ["Resume \(run.runID.rawValue)", "Abandon \(run.runID.rawValue)"], selected: 0, action: .recovery(runID: run.runID))
        } catch { append(.error, String(describing: error)) }
    }

    private func resetPresentation() {
        projector.reset()
        visibleRunIDs.removeAll()
        overlay = nil
        composer.removeAll()
        app.composer.clear()
        app.transcript.replace([])
        app.setFocus(.composer)
    }

    private func refreshContext(_ client: LingXiClient) async {
        guard let sessionID else { return }
        do {
            contextProjection = try await client.contextProjection(sessionID)
        } catch { contextProjection = nil }
    }

    private func contextDetails(_ projection: ContextCacheProjection) -> String {
        let p = projection.policy
        let l1 = projection.l1
        let l2 = projection.l2
        let l3 = projection.l3
        let pg = projection.paging

        var lines: [String] = []
        lines.append("Context")
        lines.append("")
        lines.append(String(format: "%-22@ %@", "Addressable Budget", TokenFormatter.format(p.addressableBudget)))
        lines.append(String(format: "%-22@ %@", "Model Window", TokenFormatter.format(p.modelWindow)))
        if let economic = p.economicThreshold {
            lines.append(String(format: "%-22@ %@", "Economic Threshold", TokenFormatter.format(economic)))
        }
        lines.append(String(format: "%-22@ %@", "Reserve", TokenFormatter.format(p.reserve)))
        lines.append("")
        lines.append("L1 · Hot Working Set")
        let l1Usage = l1.usageTokens == 0 ? "0" : TokenFormatter.format(l1.usageTokens)
        lines.append(String(format: "  %-20@ %@", "Usage", l1Usage))
        if let lastInput = projection.lastProviderInputTokens {
            lines.append(String(format: "  %-20@ %@", "Last Provider Input", TokenFormatter.format(lastInput)))
        }
        lines.append(String(format: "  %-20@ %@", "Target", TokenFormatter.format(p.l1Target)))
        lines.append(String(format: "  %-20@ %@", "Soft Limit", TokenFormatter.format(p.l1SoftLimit)))
        lines.append(String(format: "  %-20@ %@", "Hard Limit", TokenFormatter.format(p.l1HardLimit)))
        lines.append(String(format: "  %-20@ %d", "Entries", l1.entryCount))
        lines.append("")
        lines.append("L2 · Warm Cache")
        let l2Usage = l2.usageTokens == 0 ? "0" : TokenFormatter.format(l2.usageTokens)
        lines.append(String(format: "  %-20@ %@ / %@", "Usage", l2Usage, TokenFormatter.format(l2.capacityTokens)))
        lines.append(String(format: "  %-20@ %d", "Entries", l2.entryCount))
        lines.append("")
        lines.append("L3 · Cold Cache")
        if l3.state == .unavailable {
            lines.append("  State                off")
        } else {
            let l3Usage = l3.usageTokens == 0 ? "0" : TokenFormatter.format(l3.usageTokens)
            lines.append(String(format: "  %-20@ %@ / %@", "Usage", l3Usage, TokenFormatter.format(l3.capacityTokens)))
            lines.append(String(format: "  %-20@ %d", "Entries", l3.entryCount))
        }
        lines.append("")
        lines.append("Paging")
        lines.append(String(format: "  %-20@ %d", "Page-ins", pg.pageIns))
        lines.append(String(format: "  %-20@ %d", "Page-outs", pg.pageOuts))
        lines.append(String(format: "  %-20@ %d", "Promotions", pg.promotions))
        lines.append(String(format: "  %-20@ %d", "Demotions", pg.demotions))

        return lines.joined(separator: "\n")
    }

    private func renderTree(_ node: AgentTreeNode, _ indent: String = "") -> String { let head = indent + (node.session.title ?? node.session.id.rawValue) + (node.latestRun.map { " · \($0.status.rawValue)" } ?? ""); return ([head] + node.children.map { renderTree($0, indent + "  ") }).joined(separator: "\n") }

    private func timelineKind(for kind: TranscriptKind) -> TUITimelineKind {
        switch kind {
        case .user: .user
        case .assistant: .assistant
        case .thinking: .thinking
        case .read: .read
        case .search: .search
        case .edit: .edit
        case .patch: .patch
        case .write: .write
        case .shell: .shell
        case .git: .git
        case .mcp: .mcp
        case .toolCall: .tool
        case .toolResult: .toolResult
        case .subagent: .subagent
        case .question: .question
        case .permission: .permission
        case .decision: .decision
        case .error: .error
        case .result: .result
        }
    }

    private func timelineKind(for tool: String) -> TranscriptKind {
        let normalized = tool.lowercased()
        if normalized.contains("mcp") { return .mcp }
        if normalized.contains("git") { return .git }
        if normalized.contains("shell") || normalized.contains("exec") || normalized.contains("command") { return .shell }
        if normalized.contains("patch") { return .patch }
        if normalized.contains("edit") || normalized.contains("modify") { return .edit }
        if normalized.contains("write") || normalized.contains("create") { return .write }
        if normalized.contains("search") || normalized.contains("find") || normalized.contains("list") || normalized.contains("grep") { return .search }
        if normalized.contains("read") || normalized.contains("cat") || normalized.contains("file") { return .read }
        return .toolCall
    }

    private func append(_ kind: TranscriptKind, _ text: String, summary: String = "", details: [String] = [], state: TUITimelineState = .completed, collapsed: Bool = false, parentID: String? = nil) {
        if kind == .error {
            projector.recordError(message: text)
        } else {
            projector.appendItem(TUITimelineItem(id: UUID().uuidString.prefix(8).description, kind: timelineKind(for: kind), title: summary.ifEmpty(kind.rawValue), summary: text, details: details, state: state, collapsed: collapsed, parentID: parentID))
        }
    }

    private func openPermission(_ request: PermissionRequest) {
        previousFocus = app.focus
        overlay = .permission(request)
        append(.permission, request.description, summary: "Permission Required · \(request.toolID.rawValue)", details: [request.resource], state: .warning)
    }

    private func openQuestion(_ request: QuestionRequest) {
        previousFocus = app.focus
        overlay = .question(request, selected: 0)
        append(.question, request.question, summary: "Question", details: request.options, state: .warning)
    }

    private func timelineState(for outcome: ToolOutcome) -> TUITimelineState {
        switch outcome {
        case .success: .completed
        case .denied: .denied
        case .cancelled: .cancelled
        case .timedOut, .idleTimedOut: .timedOut
        case .failure: .failed
        }
    }

    private func toolSummary(_ call: ToolCall) -> String {
        call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? call.toolID.rawValue : "\(call.toolID.rawValue) · arguments received"
    }

    private func toolDetails(_ result: ToolResult) -> [String] {
        var details: [String] = []
        if let exitCode = result.exitCode { details.append("exit \(exitCode)") }
        if result.timing.milliseconds > 0 { details.append(String(format: "duration %.1fs", result.timing.milliseconds / 1000)) }
        if result.timing.queueMilliseconds > 0 { details.append(String(format: "queue %.1fs", result.timing.queueMilliseconds / 1000)) }
        if result.timing.permissionMilliseconds > 0 { details.append(String(format: "permission %.1fs", result.timing.permissionMilliseconds / 1000)) }
        details.append(contentsOf: result.changedFiles.map { "file: \($0)" })
        if !result.content.isEmpty { details.append(contentsOf: result.content.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).map(String.init)) }
        if let error = result.error { details.append("\(error.code): \(error.message)") }
        return details
    }

    private var workingStatusText: String {
        guard working else { return "✓ Ready" }
        switch workingPhase {
        case .ready:
            return "✓ Ready"
        case .thinking:
            let glyph = Self.spinnerFrames[spinnerFrameIndex % Self.spinnerFrames.count]
            return "\(glyph) Thinking"
        case let .runningTool(name):
            let glyph = Self.spinnerFrames[spinnerFrameIndex % Self.spinnerFrames.count]
            return "\(glyph) Running \(name)"
        case .waitingForProvider:
            let glyph = Self.spinnerFrames[spinnerFrameIndex % Self.spinnerFrames.count]
            if let activeActivity = providerActivities.values.first(where: { !$0.state.isTerminal }) {
                if activeActivity.state == .waitingForRateBudget {
                    return "\(glyph) Waiting for Rate Budget"
                }
            }
            return "\(glyph) Waiting for Provider"
        case let .runningSubagents(count):
            let glyph = Self.spinnerFrames[spinnerFrameIndex % Self.spinnerFrames.count]
            return "\(glyph) \(count) subagent\(count > 1 ? "s" : "")"
        case .paging:
            let glyph = Self.spinnerFrames[spinnerFrameIndex % Self.spinnerFrames.count]
            return "\(glyph) Compacting"
        case let .actionRequired(prompt):
            return "? \(prompt)"
        case let .error(message):
            return "! Error\(message.isEmpty ? "" : ": " + message)"
        case .disconnected:
            return "○ Disconnected"
        }
    }

    private func render() {
        let size = terminal.size
        app.header.subtitle = "Session \(sessionID?.rawValue.prefix(8) ?? "-")"
        app.transcript.replaceTimeline(projector.items)
        if app.composer.text != composer { app.composer.setText(composer) }
        app.composer.masksInput = secretInput
        let scrollHint = app.transcript.showsBackToCurrent ? " · ↓ Back to current" : ""
        let (left, right) = statusLineParts(scrollHint: scrollHint)
        app.statusLine.setParts(left: left, right: right)
        terminal.render(app.render(size: size, overlay: overlay.map(overlayModel)))
    }

    private func syncComposer() { composer = app.composer.text }

    private var modePickerIndex: Int { [.build, .plan, .explore].firstIndex(of: behaviorProfile) ?? 0 }
    private var permissionPickerIndex: Int { permissionConfiguration == .strict ? 0 : permissionConfiguration == .agent ? 1 : 2 }
    private var permissionSummary: String {
        if permissionConfiguration == .yolo { return "YOLO" }
        return "\(permissionConfiguration.policy == .ask ? "Ask" : "Auto")/\(permissionConfiguration.profile == .workspace ? "Workspace" : "FullAccess")"
    }

    private func cycleBehaviorProfile() async {
        await modeCommand([behaviorProfile.next.rawValue])
    }

    private func statusLineParts(scrollHint: String) -> (left: String, right: String) {
        let left = "\(workingStatusText) · \(activeModel)"
        let right = "\(gitBranchName) · Mode \(behaviorProfile.displayName) · \(permissionSummary)\(scrollHint)"
        return (left, right)
    }

    private func statusLineText(scrollHint: String) -> String {
        let (left, right) = statusLineParts(scrollHint: scrollHint)
        return "\(left) · \(right)"
    }

    private func overlayModel(_ overlay: Overlay) -> TUIOverlayModel {
        if case .command = overlay {
            slashCompletion.update(items: commandCandidates().map { TUICommandItem(name: $0.name, description: $0.description) }, selectedIndex: commandSelection)
            return TUIOverlayModel(lines: slashCompletion.render(width: terminal.size.width), focus: .completion)
        }
        if case .commandPalette = overlay {
            slashCompletion.update(items: availableCommands().map { TUICommandItem(name: $0.name, description: "\($0.category) · \($0.description)") }, selectedIndex: commandSelection)
            return TUIOverlayModel(lines: [TUIStyledLine("Command Palette", style: .accent)] + slashCompletion.render(width: terminal.size.width), focus: .picker)
        }
        if case let .completion(items, selected, _) = overlay {
            let view = CompletionView()
            view.update(items: items, selectedIndex: selected)
            return TUIOverlayModel(lines: [TUIStyledLine("Completion", style: .accent)] + view.render(), focus: .completion)
        }
        let focus: TUIFocus = switch overlay {
        case .picker: .picker
        case .permission: .permission
        case .question: .permission
        case .credential, .endpoint: .overlay
        default: .overlay
        }
        return TUIOverlayModel(lines: overlayLines(overlay).enumerated().map { index, line in
            TUIStyledLine(line, style: index == 0 ? .accent : .normal)
        }, focus: focus)
    }

    private func overlayLines(_ overlay: Overlay) -> [String] {
        switch overlay {
        case .command: return (["", "Commands"] + commandCandidates().enumerated().map { "\($0.offset == commandSelection ? "›" : " ") /\($0.element.name)  \($0.element.description)" } + ["↑↓ navigate   Enter select   Esc cancel"])
        case .commandPalette: return ["", "Command Palette", "↑↓ navigate   Enter select   Esc cancel"]
        case .completion: return ["", "↑↓ navigate   Tab complete   Enter select   Esc cancel"]
        case let .picker(title, items, selected, _): return (["", title] + items.enumerated().map { "\($0.offset == selected ? "›" : " ") \($0.element)" } + ["↑↓ navigate   Enter select   Esc cancel"])
        case let .permission(request): return ["", "Permission Required", request.toolID.rawValue, request.resource, "← deny   Enter/→ allow   Esc deny"]
        case let .question(request, selected): return (["", "Question", request.question] + request.options.enumerated().map { "\($0.offset == selected ? "›" : " ") \($0.element)" } + [request.allowsFreeText ? "输入文本后 Enter" : "↑↓ navigate   Enter select", "Esc cancel"])
        case .credential: return ["", "Provider credential", "输入 credential（raw input，不回显）后按 Enter", "Esc cancel"]
        case .endpoint: return ["", "Provider endpoint", "输入 endpoint 后按 Enter", "Esc cancel"]
        }
    }

    private func commandCandidates() -> [CommandDescriptor] {
        let query = composer.dropFirst().split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        return availableCommands().filter { query.isEmpty || $0.matches(query) }
    }
    private func availableCommands() -> [CommandDescriptor] { registry.filter { $0.isAvailable(hasSession: sessionID != nil) } }

    private func updateCompletion() {
        guard !composer.isEmpty else { overlay = nil; return }
        if composer.first == "/" {
            overlay = .command
            commandSelection = 0
            return
        }
        let characters = Array(composer)
        let cursor = min(app.composer.cursor, characters.count)
        guard let start = characters[..<cursor].lastIndex(where: { $0 == "@" }) else { overlay = nil; return }
        let query = String(characters[(start + 1)..<cursor])
        let items = workspaceCompletionItems(query: query)
        guard !items.isEmpty else { overlay = nil; return }
        previousFocus = app.focus
        overlay = .completion(items: items, selected: 0, tokenStart: start)
    }

    private func workspaceCompletionItems(query: String) -> [TUICompletionItem] {
        if referenceCandidates.isEmpty {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                referenceCandidates = enumerator.compactMap { value -> String? in
                    guard let url = value as? URL else { return nil }
                    let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    guard !path.isEmpty, !path.hasPrefix(".build/") else { return nil }
                    return path
                }.prefix(500).map { $0 }
            }
        }
        let normalized = query.lowercased()
        return referenceCandidates.filter { normalized.isEmpty || $0.lowercased().contains(normalized) }.prefix(12).map { path in
            TUICompletionItem(value: path, label: "@\(path)", detail: "workspace", kind: .reference)
        }
    }

    private func completeCommand(_ descriptor: CommandDescriptor) {
        let parts = composer.dropFirst().split(whereSeparator: \ .isWhitespace).map(String.init)
        composer = "/\(descriptor.name)" + (parts.dropFirst().isEmpty ? "" : " \(parts.dropFirst().joined(separator: " "))")
        app.composer.setText(composer)
        overlay = nil
    }

    private func completeActiveCompletion() {
        guard case let .completion(items, selected, tokenStart) = overlay, items.indices.contains(selected) else { return }
        let end = app.composer.cursor
        app.composer.replaceRange(start: tokenStart, end: end, with: "@\(items[selected].value)")
        syncComposer()
        overlay = nil
    }

    private func handleCompletionInput(_ input: TUIInputEvent, items: [TUICompletionItem], selected: Int, tokenStart: Int) async {
        var index = selected
        switch input {
        case .up: index = max(0, index - 1)
        case .down: index = min(items.count - 1, index + 1)
        case .escape: overlay = nil; return
        case .tab: completeActiveCompletion(); return
        case .enter: completeActiveCompletion(); return
        default:
            let action = app.composer.handle(input)
            syncComposer()
            if action == .submit { overlay = nil; await submit(); return }
            updateCompletion()
            return
        }
        overlay = .completion(items: items, selected: index, tokenStart: tokenStart)
    }

    private func openCommandPalette() {
        previousFocus = app.focus
        commandSelection = 0
        overlay = .commandPalette
    }

    private func handleCommandPaletteInput(_ input: TUIInputEvent) async {
        let candidates = availableCommands()
        switch input {
        case .up: commandSelection = max(0, commandSelection - 1)
        case .down: commandSelection = min(max(0, candidates.count - 1), commandSelection + 1)
        case .escape: overlay = nil
        case .enter:
            guard candidates.indices.contains(commandSelection) else { overlay = nil; return }
            overlay = nil
            await routeCommand("/\(candidates[commandSelection].name)")
        default: break
        }
    }
    private func layerCompact(name: String, _ layer: ContextLayerStatus?) -> String {
        guard let layer else {
            let cap = name == "L1" ? 220_000 : (name == "L2" ? 350_000 : 456_576)
            return "\(name) 0/\(TokenFormatter.format(cap))"
        }
        return TokenFormatter.formatLayer(layer: name, usage: layer.usageTokens, capacity: layer.capacityTokens, state: layer.state)
    }
    private func detectGitBranch() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("-") ?? "-"
        } catch { return "-" }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension String {
    func repeating(_ count: Int) -> String { String(repeating: self, count: count) }
}
