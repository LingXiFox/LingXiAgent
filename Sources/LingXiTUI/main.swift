import Darwin
import Foundation
import LingXiFrontendProtocol

nonisolated(unsafe) var resizePending = false

private final class EventQueue<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private let signal = DispatchSemaphore(value: 0)

    func push(_ item: Element) {
        lock.lock(); items.append(item); lock.unlock()
        signal.signal()
    }

    func drain() -> [Element] {
        lock.lock()
        let drained = items
        items.removeAll(keepingCapacity: true)
        lock.unlock()
        return drained
    }

    func wait(milliseconds: Int) {
        _ = signal.wait(timeout: .now() + .milliseconds(milliseconds))
    }
}

private final class CoreClient: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var nextID = 1

    let lines = EventQueue<Data>()
    let errors = EventQueue<String>()

    init(executable: URL) throws {
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["LINGXI_FRONTEND"] = "stdio"
        environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        drain(stdout, into: lines)
        drainText(stderr, into: errors)
    }

    private func drain(_ pipe: Pipe, into queue: EventQueue<Data>) {
        DispatchQueue.global().async {
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { queue.push(Data(line)) }
                }
            }
        }
    }

    private func drainText(_ pipe: Pipe, into queue: EventQueue<String>) {
        DispatchQueue.global().async {
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { queue.push(line) }
                }
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    func send(_ method: FrontendMethod, sessionID: String? = nil, model: String? = nil,
              text: String? = nil, runID: String? = nil, bundleID: String? = nil,
              provider: String? = nil, secret: String? = nil) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        var request = FrontendRequest(id: id, method: method)
        request.sessionID = sessionID
        request.model = model
        request.text = text
        request.runID = runID
        request.bundleID = bundleID
        request.provider = provider
        request.secret = secret
        if let data = try? JSONEncoder().encode(request) {
            stdin.fileHandleForWriting.write(data + Data([UInt8(ascii: "\n")]))
        }
        return id
    }

    func stop() {
        if process.isRunning {
            stdin.fileHandleForWriting.closeFile()
            process.terminate()
        }
    }
}

private enum Pending {
    case hello
    case plugins
    case sessions
    case history
    case enable(String)
    case disable(String)
    case auth(String, String)
}

private struct SecretInput {
    let provider: String
    let label: String
    var characters: [Character] = []
    var invalidPaste = false
}

private struct App {
    var messages: [Message] = []
    var input: [Character] = []
    var cursor = 0
    var scroll = 0
    var sessions: [SessionSummary] = []
    var models: [String] = []
    var plugins: [PluginSummary] = []
    var activeSession: String?
    var model: String?
    var runID: String?
    var running = false
    var cancelling = false
    var pending: [Int: Pending] = [:]
    var feedback: Message?
    var picker: Picker?
    var completionIndex = 0
    var coreGone = false
    var secretInput: SecretInput?
    var authBusy = false
    var pasting = false
    var discardInputBatch = false

    var sessionTitle: String {
        guard let activeSession else { return "新会话" }
        return sessions.first { $0.id == activeSession }?.title ?? "会话"
    }

    var header: String {
        let modelName = model ?? "无模型"
        let pluginCount = plugins.filter(\.running).count
        return "\(modelName)  ·  \(sessionTitle)  ·  插件 \(pluginCount)"
    }

    var status: String {
        if coreGone { return "Core 已退出；按 Ctrl-C 退出" }
        if let secretInput { return "\(secretInput.label)：隐藏输入中 · Enter 保存 · Esc 取消" }
        if authBusy { return "正在处理凭据…" }
        if cancelling { return "正在取消…" }
        if running { return "生成中…  Esc 取消" }
        return "Enter 发送    / 命令    Ctrl-P 命令面板    PgUp/PgDn 滚动    Ctrl-C 退出"
    }

    mutating func notice(_ text: String) {
        feedback = Message(role: .system, text: text)
    }

    mutating func error(_ text: String) {
        feedback = Message(role: .error, text: text)
    }
}

// MARK: - entry

private func coreExecutable() -> URL {
    if let override = ProcessInfo.processInfo.environment["LINGXI_CORE_HOST"] {
        return URL(fileURLWithPath: override)
    }
    let selfURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    return selfURL.deletingLastPathComponent().appendingPathComponent("LingXiCoreHost")
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LingXiTUI: \(message)\n".utf8))
    exit(1)
}

signal(SIGWINCH) { _ in resizePending = true }
signal(SIGPIPE, SIG_IGN)

guard let original = Terminal.enableRawMode() else {
    fail("this terminal does not support raw mode")
}

private let client: CoreClient
do {
    client = try CoreClient(executable: coreExecutable())
} catch {
    Terminal.restore(original)
    fail("could not start the Core: \(error)")
}

private let keys = EventQueue<Key>()
nonisolated(unsafe) private let parser = KeyParser()
InputReader { bytes in
    for key in parser.feed(bytes) { keys.push(key) }
}.start()

private let output = FileHandle.standardOutput
output.write(Data("\u{1B}[?2004h\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J\u{1B}[H".utf8))
output.write(Data(Theme.charcoal.bg.utf8))
output.write(Data(Theme.cream.fg.utf8))

private var app = App()
private var needsRender = true
private let helloID = client.send(.hello)
app.pending[helloID] = .hello

@MainActor
func draw() {
    let size = Terminal.size()
    let renderer = Renderer(columns: size.columns, rows: size.rows)
    let frame = renderer.frame(
        messages: app.messages, scrollFromBottom: app.scroll,
        input: app.secretInput == nil ? app.input : [], cursor: app.secretInput == nil ? app.cursor : 0,
        header: app.header, status: app.status,
        workspace: FileManager.default.currentDirectoryPath,
        feedback: app.feedback, picker: app.picker ?? slashPicker(),
        auth: app.secretInput.map { AuthPrompt(label: $0.label, characterCount: $0.characters.count) }
    )
    output.write(Data(frame.utf8))
    needsRender = false
}

@MainActor
func shutdown() {
    app.secretInput = nil
    _ = client.send(.shutdown)
    client.stop()
    output.write(Data(("\u{1B}[0m\u{1B}[?7h\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l").utf8))
    Terminal.restore(original)
}

@MainActor
func handleReply(_ reply: FrontendReply) {
    let pending = app.pending.removeValue(forKey: reply.id)
    if let models = reply.models { app.models = models }
    if let sessions = reply.sessions { app.sessions = sessions }
    if let plugins = reply.plugins { app.plugins = plugins }

    switch pending {
    case .hello:
        if app.model == nil || !(app.models.contains(app.model!)) { app.model = app.models.first }
        if app.models.isEmpty {
            app.notice("没有可用模型。请安装并启用 Provider 插件；本地构建的插件需要显式设置 LINGXI_PLUGIN_POLICY=development。用 /plugins 查看状态。")
        } else if !app.sessions.isEmpty {
            app.notice("欢迎回来。已有 \(app.sessions.count) 个会话，用 /sessions 查看、/switch <序号> 切换，或直接输入开始新对话。")
        } else {
            app.notice("首次使用：/auth 连接模型。已有 Key 只需配置一次。")
        }
    case .plugins:
        app.picker = Picker(title: "插件", items: app.plugins.map {
            MenuItem(title: $0.bundleID, detail: ($0.running ? "运行中 · Enter 禁用" : "已禁用 · Enter 启用")
                + " · " + $0.capabilities.joined(separator: ", "), command: ($0.running ? "/disable " : "/enable ") + $0.bundleID)
        })
    case .sessions:
        app.picker = Picker(title: "切换会话", items: app.sessions.enumerated().map { index, session in
            MenuItem(title: session.title, detail: "\(session.turns) 轮 · \(session.id)", command: "/switch \(index + 1)")
        })
    case .history:
        if let history = reply.history {
            app.messages = history.map { entry in
                switch entry.kind {
                case "tool": Message(role: .tool, text: entry.text)
                case "toolCall": Message(role: .tool, text: entry.text)
                default: Message(role: entry.role == "user" ? .user : .assistant, text: entry.text)
                }
            }
            if app.messages.isEmpty { app.notice("该会话还没有消息。") }
        }
    case .enable(let bundleID):
        if !reply.ok {
            app.error("插件操作失败：\(reply.error ?? "未知错误")")
        } else {
            app.notice("已启用 \(bundleID)。")
        }
    case .disable(let bundleID):
        if !reply.ok {
            app.error("插件操作失败：\(reply.error ?? "未知错误")")
        } else {
            app.notice("已禁用 \(bundleID)。")
        }
    case .auth(let provider, let action):
        app.authBusy = false
        if !reply.ok {
            app.error("凭据操作失败：\(reply.error ?? "未知错误")")
        } else if let state = reply.credentials?.first {
            if action == "set" || action == "update" {
                if state.configured && action == "set" {
                    app.notice("\(provider) 已配置（\(state.source)）。更新请用 /auth \(provider) update。")
                } else {
                    app.secretInput = SecretInput(provider: provider, label: state.label)
                    app.feedback = nil
                }
            } else {
                let stateText = state.configured ? "已配置（\(state.source)）" : "未配置"
                app.notice("\(provider)：\(stateText)。" + (action == "saved" ? "可立即发送新请求。" : ""))
            }
        }
    case nil:
        if !reply.ok {
            app.error(reply.error ?? "请求失败")
        }
    }
    needsRender = true
}

@MainActor
func handleEvent(_ event: FrontendEvent) {
    switch event.event {
    case "delta":
        guard let delta = event.delta else { break }
        if let last = app.messages.indices.last, app.messages[last].role == .assistant, app.messages[last].streaming {
            app.messages[last].text += delta
        } else {
            app.messages.append(Message(role: .assistant, text: delta, streaming: true))
        }
        app.scroll = 0
    case "run.state":
        if let status = event.status, status == "running" {
            app.running = true
            app.cancelling = false
            app.runID = event.runID
        }
    case "run.terminal":
        app.running = false
        app.cancelling = false
        app.runID = nil
        if let last = app.messages.indices.last, app.messages[last].streaming {
            app.messages[last].streaming = false
        }
        if let sessions = event.sessions { app.sessions = sessions }
        if event.status != "completed" {
            let cause = event.cause ?? "unknown"
            let detail = event.detail.map { " — \($0)" } ?? ""
            app.error("运行结束：\(event.status ?? "failed") / \(cause)\(detail)")
        }
    case "plugins.changed":
        if let plugins = event.plugins {
            app.plugins = plugins
        }
    case "models.changed":
        if let models = event.models {
            app.models = models
            if let current = app.model, !models.contains(current) {
                app.model = models.first
                app.notice("模型 \(current) 已不可用；当前模型：\(app.model ?? "无")")
            }
        }
    default:
        break
    }
    needsRender = true
}

@MainActor
func submit(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if trimmed.hasPrefix("/") {
        runCommand(trimmed)
        return
    }
    guard !app.running else {
        app.notice("仍在上一次生成中；按 Esc 取消。")
        return
    }
    guard let model = app.model else {
        // Startup may still be activating plugins; do not swallow what the user typed.
        app.input = Array(trimmed)
        app.cursor = app.input.count
        app.notice("模型正在加载，请稍候再发送。")
        return
    }
    app.messages.append(Message(role: .user, text: trimmed))
    app.scroll = 0
    let id = client.send(.chatSend, sessionID: app.activeSession, model: model, text: trimmed)
    app.pending[id] = nil
}

@MainActor
func runCommand(_ raw: String) {
    let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
    let command = parts[0]
    let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    switch command {
    case "/help":
        app.picker = Picker(title: "命令", items: commandItems)
    case "/sessions":
        let id = client.send(.sessionsList); app.pending[id] = .sessions
    case "/switch":
        guard let index = Int(argument), index >= 1, index <= app.sessions.count else {
            app.error("用法：/switch <序号>，先 /sessions 查看。")
            return
        }
        let session = app.sessions[index - 1]
        app.activeSession = session.id
        let id = client.send(.sessionHistory, sessionID: session.id)
        app.pending[id] = .history
    case "/new":
        app.activeSession = nil
        app.messages = []
        app.notice("新会话。输入消息开始。")
    case "/models":
        app.picker = Picker(title: "切换模型", items: app.models.map {
            MenuItem(title: $0, detail: $0 == app.model ? "当前模型" : "Enter 使用此模型", command: "/model " + $0)
        })
    case "/model":
        guard app.models.contains(argument) else { app.error("用法：/model <id>，可选：\(app.models.joined(separator: ", "))"); return }
        app.model = argument
        app.notice("模型已切换为 \(argument)。")
    case "/plugins":
        let id = client.send(.pluginsList); app.pending[id] = .plugins
    case "/enable", "/disable":
        guard !argument.isEmpty else { app.error("用法：\(command) <bundle id>"); return }
        let id = command == "/enable"
            ? client.send(.pluginEnable, bundleID: argument)
            : client.send(.pluginDisable, bundleID: argument)
        app.pending[id] = command == "/enable" ? .enable(argument) : .disable(argument)
        app.notice("正在\(command == "/enable" ? "启用" : "禁用") \(argument)…")
    case "/auth":
        let fields = argument.split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.isEmpty {
            let providers = Set(app.plugins.flatMap(\.capabilities).filter { $0.hasPrefix("provider.") }.map { String($0.dropFirst(9)) }).sorted()
            app.picker = Picker(title: "连接模型", items: providers.map {
                MenuItem(title: $0, detail: "配置 API Key · macOS Keychain", command: "/auth " + $0)
            })
            return
        }
        guard (1...2).contains(fields.count),
              fields.count == 1 || ["update", "remove", "status"].contains(fields[1]) else {
            app.error("用法：/auth <provider> [update|remove|status]。Key 必须在专用隐藏输入中填写。")
            return
        }
        let provider = fields[0]
        let action = fields.count == 1 ? "set" : fields[1]
        app.authBusy = true
        let id = client.send(action == "remove" ? .authRemove : .authStatus, provider: provider)
        app.pending[id] = .auth(provider, action)
    case "/clear":
        app.messages = []
        app.scroll = 0
        app.notice("已清屏。会话历史仍保留；/new 开新会话。")
    case "/quit", "/exit":
        shutdown()
        exit(0)
    default:
        app.error("未知命令：\(command)。用 /help 查看。")
    }
}

private let commandItems: [MenuItem] = [
    .init(title: "连接模型", detail: "/auth · 安全设置 API Key", command: "/auth"),
    .init(title: "切换模型", detail: "/models · 选择已启用的模型", command: "/models"),
    .init(title: "切换会话", detail: "/sessions · 继续之前的对话", command: "/sessions"),
    .init(title: "插件", detail: "/plugins · 启用或禁用插件", command: "/plugins"),
    .init(title: "新建会话", detail: "/new · 开始新的对话", command: "/new"),
    .init(title: "清屏", detail: "/clear · 保留会话历史", command: "/clear"),
    .init(title: "退出", detail: "/quit · 关闭 TUI", command: "/quit"),
]

@MainActor
func slashPicker() -> Picker? {
    let query = String(app.input)
    guard query.hasPrefix("/"), !query.contains(where: \.isWhitespace) else { return nil }
    let items = commandItems.filter { $0.command.hasPrefix(query) }
    guard !items.isEmpty else { return nil }
    return Picker(title: "命令", items: items, selected: min(app.completionIndex, items.count - 1))
}

@MainActor
func handleKey(_ key: Key) {
    if key == .pasteStart { app.pasting = true; return }
    if key == .pasteEnd { app.pasting = false; return }
    if app.discardInputBatch { return }
    if app.authBusy {
        if key == .interrupt { shutdown(); exit(0) }
        return
    }
    if app.secretInput != nil {
        switch key {
        case .character(let character):
            if character.isWhitespace || app.secretInput!.characters.count >= 8192 {
                app.secretInput?.invalidPaste = true
            } else { app.secretInput?.characters.append(character) }
        case .backspace: _ = app.secretInput?.characters.popLast()
        case .clearLine:
            app.secretInput?.characters = []
            app.secretInput?.invalidPaste = false
        case .enter:
            if app.pasting { app.secretInput?.invalidPaste = true; break }
            guard let input = app.secretInput, !input.characters.isEmpty, !input.invalidPaste else {
                app.secretInput?.characters = []
                app.secretInput?.invalidPaste = false
                app.error("Key 不能为空或包含空白，最长 8192 字符。请重新输入。")
                break
            }
            app.secretInput = nil
            app.authBusy = true
            let id = client.send(.authSet, provider: input.provider, secret: String(input.characters))
            app.pending[id] = .auth(input.provider, "saved")
        case .escape, .interrupt, .endOfInput:
            app.secretInput = nil
            app.discardInputBatch = true
            app.notice("已取消凭据输入。")
        default: break
        }
        needsRender = true
        return
    }
    if var picker = app.picker {
        switch key {
        case .character(let character): picker.query.append(character); picker.selected = 0
        case .backspace: _ = picker.query.popLast(); picker.selected = 0
        case .clearLine: picker.query = ""; picker.selected = 0
        case .up: picker.selected = max(0, picker.selected - 1)
        case .down: picker.selected = min(max(0, picker.filtered.count - 1), picker.selected + 1)
        case .enter:
            app.picker = nil
            if app.input.first == "/" { app.input = []; app.cursor = 0; app.completionIndex = 0 }
            if picker.filtered.indices.contains(picker.selected) { runCommand(picker.filtered[picker.selected].command) }
            needsRender = true
            return
        case .escape, .interrupt, .commandPalette: app.picker = nil; needsRender = true; return
        default: break
        }
        app.picker = picker
        needsRender = true
        return
    }
    let completion = slashPicker()
    switch key {
    case .character(let character):
        app.completionIndex = 0
        if app.cursor >= app.input.count { app.input.append(character) } else { app.input.insert(character, at: app.cursor) }
        app.cursor += 1
    case .enter:
        if let completion, completion.items.indices.contains(completion.selected) {
            app.input = []; app.cursor = 0; app.completionIndex = 0
            runCommand(completion.items[completion.selected].command)
            break
        }
        let text = String(app.input)
        app.input = []
        app.cursor = 0
        submit(text)
    case .backspace:
        guard app.cursor > 0 else { break }
        app.input.remove(at: app.cursor - 1)
        app.cursor -= 1
    case .delete:
        guard app.cursor < app.input.count else { break }
        app.input.remove(at: app.cursor)
    case .left: app.cursor = max(0, app.cursor - 1)
    case .right: app.cursor = min(app.input.count, app.cursor + 1)
    case .home: app.cursor = 0
    case .end: app.cursor = app.input.count
    case .clearLine: app.input = []; app.cursor = 0
    case .up:
        if completion != nil { app.completionIndex = max(0, app.completionIndex - 1) } else { app.scroll += 1 }
    case .down:
        if let completion { app.completionIndex = min(completion.items.count - 1, app.completionIndex + 1) }
        else { app.scroll = max(0, app.scroll - 1) }
    case .pageUp: app.scroll += 8
    case .pageDown: app.scroll = max(0, app.scroll - 8)
    case .escape:
        if app.running, let runID = app.runID {
            _ = client.send(.runCancel, runID: runID)
            app.cancelling = true
        } else {
            app.input = []; app.cursor = 0
        }
    case .interrupt:
        if app.running, let runID = app.runID {
            _ = client.send(.runCancel, runID: runID)
            app.cancelling = true
        } else {
            shutdown()
            exit(0)
        }
    case .endOfInput:
        if app.input.isEmpty { shutdown(); exit(0) }
    case .commandPalette:
        app.picker = Picker(title: "命令", items: commandItems)
    case .tab:
        if let completion, completion.items.indices.contains(completion.selected) {
            app.input = Array(completion.items[completion.selected].command); app.cursor = app.input.count
            break
        }
        for _ in 0..<2 { app.input.insert(" ", at: app.cursor); app.cursor += 1 }
    case .unknown, .pasteStart, .pasteEnd:
        break
    }
    needsRender = true
}

// MARK: - loop

draw()
while true {
    if resizePending {
        resizePending = false
        needsRender = true
    }
    keys.wait(milliseconds: 30)
    app.discardInputBatch = false
    for key in keys.drain() { handleKey(key) }
    for line in client.lines.drain() {
        if let reply = try? JSONDecoder().decode(FrontendReply.self, from: line) {
            handleReply(reply)
        } else if let event = try? JSONDecoder().decode(FrontendEvent.self, from: line) {
            handleEvent(event)
        }
    }
    for errorLine in client.errors.drain() {
        app.error("Core: \(errorLine)")
    }
    if !client.isRunning && !app.coreGone {
        app.secretInput = nil
        app.authBusy = false
        app.coreGone = true
        app.running = false
        app.error("Core 进程已退出。按 Ctrl-C 退出。")
    }
    if needsRender { draw() }
}
