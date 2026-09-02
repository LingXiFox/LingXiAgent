import Darwin
import Foundation
import LingXiApplication
import LingXiClient
import LingXiProtocol

private final class Terminal: @unchecked Sendable {
    private var original: termios?
    private(set) var width = 80
    private(set) var height = 24

    func start() throws {
        var state = termios()
        guard tcgetattr(STDIN_FILENO, &state) == 0 else { throw POSIXError(.EIO) }
        original = state
        cfmakeraw(&state)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &state) == 0 else { throw POSIXError(.EIO) }
        emit("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H")
        refreshSize()
    }

    func stop() {
        if let original { var state = original; _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state) }
        emit("\u{1B}[?25h\u{1B}[?1049l")
    }

    func refreshSize() {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else { return }
        width = max(40, Int(size.ws_col))
        height = max(12, Int(size.ws_row))
    }

    func readEvent() -> InputEvent? {
        guard let first = FileHandle.standardInput.readData(ofLength: 1).first else { return nil }
        switch first {
        case 3: return .interrupt
        case 4: return .quit
        case 9: return .tab
        case 10, 13: return .enter
        case 27:
            guard let second = FileHandle.standardInput.readData(ofLength: 1).first else { return .escape }
            guard second == 91, let third = FileHandle.standardInput.readData(ofLength: 1).first else { return .escape }
            switch third {
            case 65: return .up
            case 66: return .down
            case 67: return .right
            case 68: return .left
            case 72: return .home
            case 70: return .end
            default: return .escape
            }
        case 127, 8: return .backspace
        default: return .character(Character(UnicodeScalar(first)))
        }
    }

    private func emit(_ text: String) { print(text, terminator: ""); fflush(stdout) }
}

private enum InputEvent: Sendable {
    case character(Character)
    case enter, backspace, escape, up, down, left, right, home, end, tab, interrupt, quit
}

private enum UIEvent: Sendable {
    case input(InputEvent)
    case core(CoreEvent)
    case chunk(StreamChunk)
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
        name.hasPrefix(value) || aliases.contains { $0.hasPrefix(value) }
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
}

private enum TranscriptKind: String, Sendable {
    case user = "User"
    case assistant = "Assistant"
    case thinking = "Thinking"
    case toolCall = "ToolCall"
    case toolResult = "ToolResult"
    case subagent = "Subagent"
    case question = "Question"
    case permission = "Permission"
    case decision = "Decision"
    case error = "Error"
    case result = "Result"
}

private struct TranscriptEntry: Sendable {
    let kind: TranscriptKind
    var text: String
}

final class RetainedTUI: @unchecked Sendable {
    private let terminal = Terminal()
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
        CommandDescriptor(name: "mode", aliases: [], description: "切换执行模式", category: "Runtime", argumentSchema: "strict|agent|yolo", action: .mode),
        CommandDescriptor(name: "permissions", aliases: ["permission"], description: "查看权限配置", category: "Runtime", argumentSchema: "", action: .permissions),
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

    private var transcript: [TranscriptEntry] = []
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
    private var contextProjection: ContextCacheProjection?
    private var gitBranchName = "-"
    private var secretInput = false
    private var client: LingXiClient?
    private var providerService: ProviderConnectionService?
    private var eventContinuation: AsyncStream<UIEvent>.Continuation?

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
                while !Task.isCancelled, let input = terminal.readEvent() { stream.continuation.yield(.input(input)) }
            }
            let coreTask = Task {
                for await event in await client.events() { stream.continuation.yield(.core(event)) }
            }
            await bootstrap(client)
            render()
            for await event in stream.stream {
                await handle(event)
                if shouldQuit { break }
                terminal.refreshSize()
                render()
            }
            inputTask.cancel()
            coreTask.cancel()
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
            activeModel = status.model ?? activeModel
            gitBranchName = detectGitBranch()
            permissionConfiguration = try await client.permissionConfiguration()
            if let id = try await client.sessions().last?.id { sessionID = id; await loadTranscript(client, id: id) } else { sessionID = try await client.createSession() }
            await refreshContext(client)
        } catch { append(.error, "启动状态读取失败: \(error)") }
    }

    private func handle(_ event: UIEvent) async {
        switch event {
        case let .input(input): await handleInput(input)
        case let .core(event): await handleCore(event)
        case let .chunk(chunk):
            runtimeState = "Working"
            if let last = transcript.last, last.kind == .assistant { transcript[transcript.count - 1].text += chunk.text } else { transcript.append(TranscriptEntry(kind: chunk.kind == .reasoning ? .thinking : .assistant, text: chunk.text)) }
        case let .streamFailed(message):
            working = false; runtimeState = "Error"; append(.error, message)
        case .tick: break
        }
    }

    private func handleCore(_ event: CoreEvent) async {
        switch event {
        case .turnStarted: runtimeState = "Working"
        case let .turnCompleted(result):
            working = false; runtimeState = "Ready"
            let usage = result.usage.map { " · input \($0.inputTokens.map(String.init) ?? "-") · output \($0.outputTokens.map(String.init) ?? "-")" } ?? ""
            append(.result, "完成\(usage)")
            if let client { await refreshContext(client) }
        case let .turnFailed(failure): working = false; runtimeState = "Error"; append(.error, failure.error.message)
        case let .toolCallCompleted(call): append(.toolCall, "\(call.toolID.rawValue)")
        case let .toolResult(result): append(.toolResult, result.success ? "成功" : result.error?.message ?? "失败")
        case let .permissionAsked(request): runtimeState = "Action Required"; overlay = .permission(request)
        case let .questionAsked(request), let .questionEscalated(request): runtimeState = "Action Required"; overlay = .question(request, selected: 0)
        case let .subagentSpawned(run), let .agentRunQueued(run), let .agentRunStarted(run), let .agentRunStatusChanged(run), let .agentRunCompleted(run), let .agentRunFailed(run), let .agentRunCancelled(run): append(.subagent, "\(run.title ?? run.runID.rawValue) · \(run.status.rawValue)")
        case .stateChanged, .childSessionCreated, .subagentResultAvailable, .sessionCreated: break
        }
    }

    private func handleInput(_ input: InputEvent) async {
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
        if case .command = overlay {
            let candidates = commandCandidates()
            switch input {
            case .backspace:
                if !composer.isEmpty { composer.removeLast() }
                if composer.isEmpty { overlay = nil }
            case let .character(character):
                composer.append(character)
            case .up: commandSelection = max(0, commandSelection - 1)
            case .down: commandSelection = min(max(0, candidates.count - 1), commandSelection + 1)
            case .escape: overlay = nil
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
        case .enter: await submit()
        case .backspace: if !composer.isEmpty { composer.removeLast() }
        case let .character(character):
            composer.append(character)
            if composer.first == "/" { overlay = .command; commandSelection = 0 } else { overlay = nil }
        case .escape: composer.removeAll(); overlay = nil
        case .interrupt, .quit: shouldQuit = true
        case .up, .down, .left, .right, .home, .end, .tab: break
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
        case .permissions: await permissionsCommand()
        case .subagents: await subagentsCommand()
        case .mcp: await mcpCommand()
        case .skills: await extensionCommand(.skill)
        case .plugins: await extensionCommand(.plugin)
        case .hooks: await extensionCommand(.hook)
        case .diff: await diffCommand()
        case .ps: await psCommand()
        case .stop: await stopCommand(args)
        case .clear: transcript.removeAll()
        case .help: append(.result, registry.map { "/\($0.name)  \($0.description)" }.joined(separator: "\n"))
        case .quit: shouldQuit = true
        }
    }

    private func modelCommand(_ args: [String]) async {
        guard let client else { return }
        do {
            let models = try await client.listProviderModels()
            if let value = args.first { _ = try await client.selectProviderModel(value); activeModel = value; providerConfigured = true; append(.decision, "模型已选择: \(value)"); return }
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
        do { sessionID = try await client.createSession(); transcript.removeAll(); append(.result, "新 Session 已创建") }
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
        do { _ = try await client.renameSession(sessionID, title: args.joined(separator: " ")); append(.decision, "Session 已重命名") }
        catch { append(.error, String(describing: error)) }
    }

    private func refreshStatus() async {
        guard let client else { return }
        do { let status = try await client.providerStatus(); providerConfigured = status.configured; activeModel = status.model ?? activeModel; permissionConfiguration = try await client.permissionConfiguration(); await refreshContext(client); append(.result, "Provider \(status.configured ? "configured" : "disconnected") · \(status.model ?? "未选择模型")") }
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

    private func permissionsCommand() async { guard let client else { return }; do { permissionConfiguration = try await client.permissionConfiguration(); append(.result, "policy \(permissionConfiguration.policy.rawValue) · profile \(permissionConfiguration.profile.rawValue)") } catch { append(.error, String(describing: error)) } }

    private func modeCommand(_ args: [String]) async {
        guard let client else { return }
        let configuration: PermissionConfiguration?
        switch args.first {
        case "strict": configuration = .strict
        case "agent": configuration = .agent
        case "yolo": configuration = .yolo
        default: configuration = nil
        }
        guard let configuration else { overlay = .picker(title: "Execution mode", items: ["strict", "agent", "yolo"], selected: 0, action: .mode); return }
        do { try await client.setPermissionConfiguration(configuration); permissionConfiguration = configuration; append(.decision, "mode: \(args[0])") } catch { append(.error, String(describing: error)) }
    }

    private func subagentsCommand() async { guard let client, let sessionID else { return }; do { let tree = try await client.getAgentTree((try await client.session(sessionID)).rootSessionID); append(.subagent, renderTree(tree)) } catch { append(.error, String(describing: error)) } }
    private func psCommand() async { guard let client, let sessionID else { return }; do { append(.result, try await client.listAgentRuns(sessionID).map { "\($0.runID.rawValue) · \($0.status.rawValue) · \($0.modelSelection.modelID)" }.joined(separator: "\n").ifEmpty("没有 AgentRun")) } catch { append(.error, String(describing: error)) } }
    private func stopCommand(_ args: [String]) async { guard let client, let sessionID else { return }; do { let runs = try await client.listAgentRuns(sessionID); guard let run = args.first.flatMap({ value in runs.first { $0.runID.rawValue == value } }) ?? runs.last(where: { !$0.status.isTerminal }) else { append(.result, "没有可停止的运行"); return }; try await client.cancelAgentRun(run.runID); append(.decision, "已停止 \(run.runID.rawValue)") } catch { append(.error, String(describing: error)) } }

    private func mcpCommand() async { guard let client else { return }; do { let bundle = try await client.diagnostics(); append(.result, "MCP tools \(bundle.mcp.catalogTools) · schemas \(bundle.mcp.schemaFiles) · leases \(bundle.mcp.activeLeases) · page faults \(bundle.mcp.pageFaults)") } catch { append(.error, String(describing: error)) } }
    private func extensionCommand(_ kind: ExtensionKind) async { guard let client else { return }; do { let values = try await client.listExtensions(kind: kind); append(.result, values.map { "\($0.id) · \($0.scope) · \($0.lifecycleState)\($0.enabled ? "" : " · disabled")" }.joined(separator: "\n").ifEmpty("没有可用 \(kind.rawValue)")) } catch { append(.error, String(describing: error)) } }
    private func diffCommand() async { guard let client else { return }; do { append(.result, try await client.workspaceDiff().ifEmpty("工作区无未提交 diff")) } catch { append(.error, String(describing: error)) } }

    private func handlePickerInput(_ input: InputEvent, title: String, items: [String], selected: Int, action: PickerAction) async {
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
            do { let models = try await client.listProviderModels(); guard models.indices.contains(index) else { return }; let value = "\(models[index].providerID)/\(models[index].modelID)"; _ = try await client.selectProviderModel(value); activeModel = value; providerConfigured = true; append(.decision, "模型已选择: \(value)") } catch { append(.error, String(describing: error)) }
        case .session:
            do { let sessions = try await client.sessions(); guard sessions.indices.contains(index) else { return }; sessionID = sessions[index].id; await loadTranscript(client, id: sessions[index].id) } catch { append(.error, String(describing: error)) }
        case .mode: await modeCommand([["strict", "agent", "yolo"][index]])
        case .provider: await beginProvider(index)
        }
    }

    private func beginProvider(_ index: Int) async {
        guard let service = providerService else { return }
        do {
            let products = try await service.listConnectableProducts(); guard products.indices.contains(index) else { return }; let flowID = try await service.beginConnection(productID: products[index].id); let state = try await service.state(flowID: flowID)
            switch state { case .requestingCredential: secretInput = true; overlay = .credential(flowID: flowID); case .requestingLocalEndpoint: secretInput = false; overlay = .endpoint(flowID: flowID); default: append(.result, "Provider 连接状态: \(String(describing: state))") }
        } catch { append(.error, String(describing: error)) }
    }

    private func handleCredentialInput(_ input: InputEvent, flowID: String) async {
        switch input { case .backspace: if !composer.isEmpty { composer.removeLast() }; case let .character(c): composer.append(c); case .escape: overlay = nil; secretInput = false; composer.removeAll(); case .enter: do { _ = try await providerService?.submitCredential(flowID: flowID, credential: composer); composer.removeAll(); overlay = nil; secretInput = false; providerConfigured = true; runtimeState = "Ready"; append(.result, "Provider credential 已保存并连接") } catch { append(.error, String(describing: error)) }; default: break }
    }

    private func handleEndpointInput(_ input: InputEvent, flowID: String) async {
        switch input { case .backspace: if !composer.isEmpty { composer.removeLast() }; case let .character(c): composer.append(c); case .escape: overlay = nil; composer.removeAll(); case .enter: do { _ = try await providerService?.submitLocalEndpoint(flowID: flowID, endpoint: composer); composer.removeAll(); overlay = nil; append(.result, "Provider endpoint 已连接") } catch { append(.error, String(describing: error)) }; default: break }
    }

    private func handlePermissionInput(_ input: InputEvent) async {
        guard case let .permission(request) = overlay else { return }
        switch input { case .up, .left: await replyPermission(request, decision: .deny); case .down, .right, .enter: await replyPermission(request, decision: .allow); case .escape: await replyPermission(request, decision: .deny); default: break }
    }

    private func replyPermission(_ request: PermissionRequest, decision: PermissionDecision) async {
        do { try await client?.replyPermission(PermissionReply(permissionID: request.permissionID, decision: decision)); overlay = nil; runtimeState = "Working" } catch { append(.error, String(describing: error)) }
    }

    private func handleQuestionInput(_ input: InputEvent, request: QuestionRequest, selected: Int) async {
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
            do { let snapshot = try await client.session(id); transcript = snapshot.messages.map { message in TranscriptEntry(kind: message.role == .user ? .user : message.role == .assistant ? .assistant : .toolResult, text: message.content) } } catch { append(.error, String(describing: error)) }
    }

    private func refreshContext(_ client: LingXiClient) async {
        guard let sessionID else { return }
        do {
            contextProjection = try await client.contextProjection(sessionID)
        } catch { contextProjection = nil }
    }

    private func contextDetails(_ projection: ContextCacheProjection) -> String {
        [layerDetails(projection.l1), layerDetails(projection.l2), layerDetails(projection.l3), "Paging: \(projection.pagingActivity.rawValue)", "Compaction generation: \(projection.compactionGeneration)"].joined(separator: "\n")
    }

    private func layerDetails(_ layer: ContextLayerStatus) -> String {
        let usage = layer.usage.map(String.init) ?? "-"
        let capacity = layer.capacity.map(String.init) ?? "-"
        let percent = layer.percent.map { "\($0)%" } ?? "-"
        let pages = layer.residentPages.map(String.init) ?? "-"
        let totalPages = layer.totalPages.map(String.init) ?? "-"
        return "\(layer.layer.rawValue.uppercased()) · \(usage)/\(capacity) \(layer.unit) · \(percent) · \(layer.state.rawValue) · pages \(pages)/\(totalPages) · in \(layer.pageInCount) · out \(layer.pageOutCount)"
    }

    private func renderTree(_ node: AgentTreeNode, _ indent: String = "") -> String { let head = indent + (node.session.title ?? node.session.id.rawValue) + (node.latestRun.map { " · \($0.status.rawValue)" } ?? ""); return ([head] + node.children.map { renderTree($0, indent + "  ") }).joined(separator: "\n") }

    private func append(_ kind: TranscriptKind, _ text: String) { transcript.append(TranscriptEntry(kind: kind, text: text)) }

    private func render() {
        var lines: [String] = ["\u{1B}[2J\u{1B}[H", "LingXiAgent  ·  Session \(sessionID?.rawValue.prefix(8) ?? "-")"]
        let maxTranscript = max(1, terminal.height - 5)
        let visible = transcript.flatMap { entry in entry.text.split(separator: "\n", omittingEmptySubsequences: false).map { "\(entry.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) │ \($0)" } }.suffix(maxTranscript)
        lines.append(contentsOf: visible)
        while lines.count < terminal.height - 3 { lines.append("") }
        if let overlay { lines.append(contentsOf: overlayLines(overlay)) }
        lines.append("─".repeating(terminal.width))
        lines.append("\(composerPrefix())\(secretInput ? String(repeating: "•", count: composer.count) : composer)")
        lines.append("\(activeModel) · \(FileManager.default.currentDirectoryPath.split(separator: "/").last ?? "project") · \(gitBranchName) · \(permissionConfiguration.profile.rawValue) · \(runtimeState) · L1 \(layerCompact(contextProjection?.l1)) · L2 \(layerCompact(contextProjection?.l2)) · L3 \(layerCompact(contextProjection?.l3))")
        print(lines.map { truncate($0, width: terminal.width) }.joined(separator: "\n"), terminator: "")
        fflush(stdout)
    }

    private func overlayLines(_ overlay: Overlay) -> [String] {
        switch overlay {
        case .command: return (["", "Commands"] + commandCandidates().enumerated().map { "\($0.offset == commandSelection ? "›" : " ") /\($0.element.name)  \($0.element.description)" } + ["↑↓ navigate   Enter select   Esc cancel"])
        case let .picker(title, items, selected, _): return (["", title] + items.enumerated().map { "\($0.offset == selected ? "›" : " ") \($0.element)" } + ["↑↓ navigate   Enter select   Esc cancel"])
        case let .permission(request): return ["", "Permission Required", request.toolID.rawValue, request.resource, "← deny   Enter/→ allow   Esc deny"]
        case let .question(request, selected): return (["", "Question", request.question] + request.options.enumerated().map { "\($0.offset == selected ? "›" : " ") \($0.element)" } + [request.allowsFreeText ? "输入文本后 Enter" : "↑↓ navigate   Enter select", "Esc cancel"])
        case .credential: return ["", "Provider credential", "输入 credential（raw input，不回显）后按 Enter", "Esc cancel"]
        case .endpoint: return ["", "Provider endpoint", "输入 endpoint 后按 Enter", "Esc cancel"]
        }
    }

    private func composerPrefix() -> String { composer.first == "/" ? "> " : "  " }
    private func commandCandidates() -> [CommandDescriptor] {
        let query = composer.dropFirst().split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        return registry.filter { $0.isAvailable(hasSession: sessionID != nil) && (query.isEmpty || $0.matches(query)) }
    }
    private func layerCompact(_ layer: ContextLayerStatus?) -> String { guard let layer else { return "n/a" }; return layer.percent.map { "\($0)%" } ?? layer.state.rawValue }
    private func truncate(_ value: String, width: Int) -> String { String(value.prefix(max(0, width))) }
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
