import Darwin
import Foundation
import LingXiFrontendProtocol
import LingXiSettingsProtocol

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
              provider: String? = nil, secret: String? = nil,
              settingsSessionID: String? = nil, settingsInput: SettingsInput? = nil,
              viewport: SettingsViewport? = nil, settingsCredentialAction: String? = nil,
              settingsCredentialConfirmed: Bool? = nil,
              reasoningLevel: String? = nil, clearReasoning: Bool? = nil) -> Int {
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
        request.settingsSessionID = settingsSessionID
        request.settingsInput = settingsInput
        request.viewport = viewport
        request.settingsCredentialAction = settingsCredentialAction
        request.settingsCredentialConfirmed = settingsCredentialConfirmed
        request.reasoningLevel = reasoningLevel
        request.clearReasoning = clearReasoning
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
    case history(String)
    case chat(String)
    case enable(String)
    case disable(String)
    case auth(String, String)
    case settingsOpen
    case settingsInput
    case settingsResize
    case settingsSave
    /// A no-change resize used only to ask the Core whether a settings session still exists. The
    /// session id is carried so a late reply can never touch a panel that was reopened since.
    case settingsVerify(String)
    case settingsCancel
    case settingsCredential(String)
    /// A temporary thinking selection; `nil` is the "follow the plugin's own settings" clear.
    case reasoning(String?)
}

private struct SettingsPanel {
    var snapshot: SettingsSnapshot
    var busy = false
    var error: String?
}

struct Confirmation {
    let title: String
    let message: String
    let providerID: String
    let settingsSessionID: String
    /// 0 = confirm, 1 = cancel. Enter confirms by default, which is the pre-existing behaviour.
    var selected = 0
}

/// The host-owned "unsaved changes" prompt shown when Escape would discard a dirty settings draft.
/// The plugin cannot be trusted to ask on the host's behalf, so the window is host chrome.
struct ExitDialog {
    /// Button titles in drawing order.
    static let buttons = ["保存", "放弃", "继续编辑"]
    /// Selected button. "继续编辑" is the safe default: a stray Enter neither saves nor discards.
    var selected = 2
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
    /// Plugin-declared metadata for each offered model, keyed by model id.
    var modelDetails: [String: ModelSummary] = [:]
    var plugins: [PluginSummary] = []
    var activeSession: String?
    var model: String?
    var runID: String?
    var running = false
    var cancelling = false
    var pending: [Int: Pending] = [:]
    var feedback: Message?
    /// Notices fade after a few seconds; errors stay until something replaces them.
    var feedbackExpiry: Date?
    var picker: Picker?
    /// `/plugins` uses the picker chrome for a two-level navigation: Enter opens settings, Space
    /// toggles the selected plugin immediately.
    var pluginList = false
    var settings: SettingsPanel?
    var settingsInputQueue: [SettingsInput] = []
    var settingsSavePending = false
    var confirmation: Confirmation?
    /// Host-owned prompt for a dirty settings draft; drawn above the settings panel.
    var exitDialog: ExitDialog?
    var settingsCredentialRefresh = false
    var completionIndex = 0
    var coreGone = false
    var secretInput: SecretInput?
    var authBusy = false
    var pasting = false
    var pastedText: [Character] = []
    var discardPaste = false
    var discardInputBatch = false
    var showThinking = false
    var mouse = false
    // Chat prompts only, bounded to this process. Commands and hidden input never enter recall.
    var promptHistory: [String] = []
    var historyIndex: Int?
    var historyDraft: [Character] = []
    // Per-run accounting for the footer under each reply.
    var runStarted: Date?
    var runModel: String?
    var runFirstMessage = 0
    var runInputTokens: Int?
    var runOutputTokens: Int?
    var lastFrame = FrameInfo()
    /// Live per-provider state from the Core: protocol family, effective thinking, and whether a
    /// temporary selection is in force. This is the footer's source of truth.
    var providerStates: [ProviderStateSummary] = []
    /// Timing for the run in progress, replaced by every `timing` event.
    var runTiming: RunTiming?
    /// TUI render cost accumulated while the run was live, in nanoseconds (sub-millisecond frames
    /// must still add up) and the number of frames drawn.
    var runRenderNanos: UInt64 = 0
    var runFrames = 0
    /// The most recently finished run's diagnostics, for /perf.
    var lastDiagnostics: RunDiagnostics?

    mutating func insert(_ text: String) {
        let prefix = String(input.prefix(cursor)) + text
        input = Array(prefix + String(input.dropFirst(cursor)))
        cursor = min(prefix.count, input.count)
        historyIndex = nil
    }

    mutating func recall(_ direction: Int) {
        guard !promptHistory.isEmpty else { return }
        if historyIndex == nil {
            guard direction < 0 else { return }
            historyDraft = input
        }
        let next = min(promptHistory.count, max(0, (historyIndex ?? promptHistory.count) + direction))
        input = next == promptHistory.count ? historyDraft : Array(promptHistory[next])
        cursor = input.count
        historyIndex = next == promptHistory.count ? nil : next
    }

    /// Word boundaries are whitespace-delimited; CJK text without spaces moves one run at a time.
    func wordBoundary(_ direction: Int) -> Int {
        var index = cursor
        if direction < 0 {
            while index > 0, input[index - 1].isWhitespace { index -= 1 }
            while index > 0, !input[index - 1].isWhitespace { index -= 1 }
        } else {
            while index < input.count, input[index].isWhitespace { index += 1 }
            while index < input.count, !input[index].isWhitespace { index += 1 }
        }
        return index
    }

    /// Display text for a model's thinking levels: the plugin-declared default when present,
    /// otherwise the declared set. `nil` means the plugin declared no levels.
    func thinkingLabel(for id: String) -> String? {
        guard let summary = modelDetails[id], !summary.thinkingLevels.isEmpty else { return nil }
        // Only a declared default is a claim about the effective request. A provider that declares
        // a set without a default (MiMo) is configured in its own settings page, so the composer
        // must not imply one level is active.
        guard let fallback = summary.defaultThinkingLevel,
              let level = summary.thinkingLevels.first(where: { $0.id == fallback }) else {
            return nil
        }
        return level.label
    }

    /// Live state of the provider that owns `model`, as reported by the Core. `nil` when the provider
    /// declares no state view, or has not reported yet: the footer then shows the model alone rather
    /// than inventing a protocol or a thinking level.
    func providerState(for model: String) -> ProviderStateSummary? {
        guard let provider = modelDetails[model]?.provider else { return nil }
        return providerStates.first { $0.providerID == provider }
    }

    /// The thinking mode the Core reports as effective for the current model. `axis` is the plugin's
    /// own ladder name (`effort`), so the footer can read `effort: high` instead of a vague mode.
    /// The temporary flag distinguishes a frontend selection from the plugin's own configuration.
    var thinkingStatus: (label: String, axis: String?, temporary: Bool)? {
        guard let model, let state = providerState(for: model), let label = state.thinkingLabel else {
            return nil
        }
        return (label, state.thinkingAxisLabel, state.overridden == true)
    }

    /// Protocol of the current model's provider, when the plugin reports one. The display name is
    /// plugin-owned: the footer shows `protocolLabel` and falls back to the raw kind, never a
    /// prettified id of the TUI's own making.
    var modelProtocol: String? {
        guard let model, let state = providerState(for: model) else { return nil }
        return state.protocolLabel ?? state.protocolKind
    }

    var sessionTitle: String {
        if let activeSession, let title = sessions.first(where: { $0.id == activeSession })?.title { return title }
        // A brand-new session is not in the list until its first run ends.
        if let first = messages.first(where: { $0.role == .user })?.text {
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
        return "新会话"
    }

    var status: StatusLine {
        if coreGone { return StatusLine(left: [Span("● Core 已退出", .color(Theme.error))], right: "Ctrl-C 退出") }
        if let secretInput {
            return StatusLine(left: [Span("● ", .color(Theme.fox)), Span("\(secretInput.label)：隐藏输入中", .color(Theme.dim))],
                              right: "Enter 保存 · Esc 取消")
        }
        if authBusy { return StatusLine(left: [Span("● 正在处理凭据…", .color(Theme.fox))], right: "") }
        if cancelling { return StatusLine(left: [Span("● 正在取消…", .color(Theme.fox))], right: "") }
        if running {
            let seconds = Int(Date().timeIntervalSince(runStarted ?? Date()))
            return StatusLine(left: [Span("● ", .color(Theme.fox)), Span("生成中", .color(Theme.cream)),
                                     Span("  \(seconds)s", .color(Theme.dim))], right: "Esc 取消")
        }
        if scroll > 0 {
            return StatusLine(left: [Span("↑ 已向上滚动 \(scroll) 行", .color(Theme.fox))], right: "End 回到底部")
        }
        return StatusLine(left: [Span("● ", .color(Theme.success)), Span("就绪", .color(Theme.dim))], right: "Ctrl-P 命令")
    }

    mutating func notice(_ text: String, sticky: Bool = false) {
        feedback = Message(role: .system, text: text)
        feedbackExpiry = sticky ? nil : Date().addingTimeInterval(6)
    }

    mutating func error(_ text: String) {
        feedback = Message(role: .error, text: text)
        feedbackExpiry = nil
    }
}

private func formatTokens(_ count: Int) -> String {
    count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
}

// MARK: - run diagnostics

/// One finished run's numbers. Everything here is a duration or a count: no field can carry prompt
/// or response text, so a diagnostic line is safe to draw and safe to log.
struct RunDiagnostics {
    var model: String?
    var timing: RunTiming
    /// Frames the TUI drew while this run was live, and how much of the run went into drawing them.
    var frames: Int
    var renderMs: Int
}

/// Time from the first reasoning delta to the first text delta. It is **not** the model's full
/// thinking time: the first reasoning byte may arrive late and thinking continues while text is
/// produced. The report labels it as a boundary gap, never as "thinking duration".
private func thinkingMilliseconds(_ timing: RunTiming) -> Int? {
    guard let text = timing.firstTextMs else { return nil }
    if let reasoning = timing.firstReasoningMs { return max(0, text - reasoning) }
    if let response = timing.firstResponseMs { return max(0, text - response) }
    return nil
}

private func renderLabel(_ diagnostics: RunDiagnostics) -> String {
    diagnostics.renderMs < 1 ? "<1ms" : "\(diagnostics.renderMs)ms"
}

/// The compact line under a reply's meta: upstream latency, thinking time and the TUI's own cost,
/// kept apart so a slow answer is never blamed on the renderer.
private func compactDiagnostic(_ diagnostics: RunDiagnostics) -> String? {
    var parts: [String] = []
    if let upstream = diagnostics.timing.firstResponseMs { parts.append("上游 \(upstream)ms") }
    if let thinking = thinkingMilliseconds(diagnostics.timing) { parts.append("思考→首字 \(thinking)ms") }
    parts.append("本地 \(renderLabel(diagnostics))/\(diagnostics.frames) 帧")
    return parts.joined(separator: " · ")
}

/// The full /perf breakdown, grouped the way the numbers are actually caused.
private func performanceLines(_ diagnostics: RunDiagnostics) -> [String] {
    let timing = diagnostics.timing
    var lines = ["性能诊断 · \(diagnostics.model ?? "未知模型") · 仅数字，不含提示词或回复内容"]
    var local: [String] = []
    if let value = timing.corePrepareMs { local.append("Core 准备 \(value)ms") }
    if let value = timing.prepareMs { local.append("插件准备 \(value)ms") }
    if let value = timing.httpSendMs { local.append("HTTP 发送 \(value)ms") }
    if !local.isEmpty { lines.append("本地阶段：" + local.joined(separator: " · ")) }
    var upstream: [String] = []
    if let value = timing.firstResponseMs { upstream.append("首响应 \(value)ms") }
    if let value = timing.firstSSEMs { upstream.append("首 SSE \(value)ms") }
    if let value = timing.firstReasoningMs { upstream.append("首思考 \(value)ms") }
    if let value = timing.firstTextMs { upstream.append("首文本 \(value)ms") }
    if !upstream.isEmpty { lines.append("上游延迟：" + upstream.joined(separator: " · ")) }
    var kernel: [String] = []
    if let value = timing.assemblyMs { kernel.append("上下文装配 \(value)ms") }
    if let value = timing.budgetMs { kernel.append("预算规划 \(value)ms") }
    let hookMs = (timing.contextHookMs ?? 0) + (timing.requestHookMs ?? 0)
    if hookMs > 0 || timing.contextHookMs != nil || timing.requestHookMs != nil {
        kernel.append("Hook \(hookMs)ms")
    }
    if let value = timing.credentialMs, value > 0 { kernel.append("凭据解析 \(value)ms") }
    if let value = timing.providerWaitMs { kernel.append("等待 Provider \(value)ms") }
    if let value = timing.toolMs { kernel.append("工具执行 \(value)ms") }
    if let value = timing.logWriteMs { kernel.append("日志写入+同步 \(value)ms") }
    if let value = timing.terminalCommitMs { kernel.append("终态提交 \(value)ms") }
    if let value = timing.providerCleanupMs { kernel.append("Provider 清理 \(value)ms") }
    if !kernel.isEmpty { lines.append("内核阶段：" + kernel.joined(separator: " · ")) }
    // The kernel's own residual plus whatever happened outside `run` (request queueing and the
    // final frontend emission) must both be visible; otherwise a new hidden wait could hide again.
    var residual: [String] = []
    if let value = timing.unaccountedMs { residual.append("内核未分解 \(value)ms") }
    if let total = timing.runTotalMs, let loopTotal = timing.loopTotalMs {
        let outside = total - (timing.corePrepareMs ?? 0) - loopTotal
        if outside > 0 { residual.append("Core 队列/收尾 \(outside)ms") }
    }
    if !residual.isEmpty { lines.append(residual.joined(separator: " · ")) }
    var totals: [String] = []
    if let thinking = thinkingMilliseconds(timing) { totals.append("首思考→首字 \(thinking)ms") }
    if let value = timing.providerTotalMs {
        if let calls = timing.providerCalls, calls > 1 {
            let last = timing.providerLastCallMs.map { "，最后 \($0)ms" } ?? ""
            totals.append("插件总计 \(value)ms（\(calls) 次\(last)）")
        } else {
            totals.append("插件总计 \(value)ms")
        }
    }
    if let steps = timing.steps, steps > 0 { totals.append("\(steps) 步") }
    if let value = timing.runTotalMs { totals.append("运行总计 \(value)ms") }
    totals.append("TUI 渲染 \(renderLabel(diagnostics))/\(diagnostics.frames) 帧")
    lines.append("总计：" + totals.joined(separator: " · "))
    return lines
}

/// Copy of a run's timing with the TUI's own render cost merged in. Render cost is local-only: the
/// Core never sees it, and the wire type documents that.
private func timing(_ timing: RunTiming, renderMs: Int) -> RunTiming {
    RunTiming(
        corePrepareMs: timing.corePrepareMs, prepareMs: timing.prepareMs,
        httpSendMs: timing.httpSendMs, firstResponseMs: timing.firstResponseMs,
        firstSSEMs: timing.firstSSEMs, firstReasoningMs: timing.firstReasoningMs,
        firstTextMs: timing.firstTextMs, providerTotalMs: timing.providerTotalMs,
        runTotalMs: timing.runTotalMs, renderMs: renderMs
    )
}

/// A plugin save/result notice outranks the automatic "model went away" notice: both come from the
/// same save, and the plugin result is the one the user asked for.
private func isPluginFeedback(_ feedback: Message?) -> Bool {
    guard let text = feedback?.text else { return false }
    return text.hasPrefix("正在保存") || text.hasPrefix("已启用 ") || text.hasPrefix("已禁用 ") || text == "插件未修改。"
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
output.write(Data("\u{1B}[>1u\u{1B}[?2004h\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J\u{1B}[H".utf8))
output.write(Data(Theme.charcoal.bg.utf8))
output.write(Data(Theme.cream.fg.utf8))

private var app = App()
private var needsRender = true
private let lineCache = LineCache()
private var windowTitle = ""
private var renderedSecond = -1
private let helloID = client.send(.hello)
app.pending[helloID] = .hello

@MainActor
func draw() {
    // Two clock reads per draw: the TUI's own render cost is part of the run diagnostics, and only
    // measured while a run is live so idle redraws never skew it.
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let size = Terminal.size()
    let renderer = Renderer(columns: size.columns, rows: size.rows)
    var view = ViewState()
    view.messages = app.messages
    view.scroll = app.scroll
    view.input = app.secretInput == nil ? app.input : []
    view.cursor = app.secretInput == nil ? app.cursor : 0
    view.model = app.model
    let thinking = app.thinkingStatus
    view.modelThinking = thinking?.label
    view.modelThinkingAxis = thinking?.axis
    view.modelThinkingTemporary = thinking?.temporary ?? false
    view.modelProtocol = app.modelProtocol
    view.sessionTitle = app.sessionTitle
    view.workspace = FileManager.default.currentDirectoryPath
    view.status = app.status
    view.feedback = app.feedback
    view.picker = app.picker
    view.completion = app.picker == nil ? slashPicker() : nil
    view.settings = app.settings?.snapshot
    view.settingsBusy = app.settings?.busy ?? false
    view.settingsError = app.settings?.error
    view.confirmation = app.confirmation
    view.exitDialog = app.exitDialog
    view.auth = app.secretInput.map { AuthPrompt(label: $0.label, characterCount: $0.characters.count) }
    view.showThinking = app.showThinking
    view.running = app.running
    var frame = renderer.frame(view, cache: lineCache)
    // Scrolled-back readers keep their place while new lines arrive below.
    let grown = frame.info.bodyLines - app.lastFrame.bodyLines
    let limit = max(0, frame.info.bodyLines - frame.info.bodyHeight)
    if app.scroll > 0, grown > 0 {
        app.scroll = min(limit, app.scroll + grown)
        view.scroll = app.scroll
        frame = renderer.frame(view, cache: lineCache)
    } else if app.scroll > limit {
        app.scroll = limit
    }
    app.lastFrame = frame.info
    let title = "泠溪 · " + app.sessionTitle
    if title != windowTitle {
        windowTitle = title
        let safe = title.unicodeScalars.filter { $0.properties.generalCategory != .control }
        output.write(Data(("\u{1B}]0;" + String(String.UnicodeScalarView(safe)) + "\u{07}").utf8))
    }
    output.write(Data(frame.text.utf8))
    // Only frames drawn while a run is live belong to that run's local cost.
    if app.running {
        app.runRenderNanos += DispatchTime.now().uptimeNanoseconds - startedAt
        app.runFrames += 1
    }
    needsRender = false
}

@MainActor
func shutdown() {
    app.secretInput = nil
    _ = client.send(.shutdown)
    client.stop()
    output.write(Data(("\u{1B}[<u\u{1B}[0m\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?7h\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l").utf8))
    Terminal.restore(original)
}

@MainActor
func settingsViewport() -> SettingsViewport {
    let size = Terminal.size()
    let width = min(100, max(24, size.columns - 8))
    let height = min(30, max(8, size.rows - 8))
    func hex(_ color: RGB) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }
    return SettingsViewport(
        width: width, height: height, focus: true,
        theme: [
            "charcoal": hex(Theme.charcoal), "charcoalRaised": hex(Theme.charcoalRaised),
            "overlay": hex(Theme.overlay), "selection": hex(Theme.selection),
            "cream": hex(Theme.cream), "fox": hex(Theme.fox), "dim": hex(Theme.dim),
            "muted": hex(Theme.muted), "error": hex(Theme.error), "success": hex(Theme.success),
            "link": hex(Theme.link), "string": hex(Theme.string), "number": hex(Theme.number),
            "type": hex(Theme.type),
        ]
    )
}

@MainActor
func showPluginList() {
    app.picker = Picker(title: "插件", items: app.plugins.map { plugin in
        let state = plugin.enabled ? (plugin.running ? "运行中" : "已启用") : "已禁用"
        return MenuItem(
            title: plugin.bundleID,
            detail: "v\(plugin.version) · \(state) · \(plugin.capabilities.joined(separator: ", "))",
            command: plugin.bundleID
        )
    })
    app.pluginList = true

}

@MainActor
func openPluginSettings(_ bundleID: String) {
    app.picker = nil
    app.pluginList = false
    let id = client.send(.pluginSettingsOpen, bundleID: bundleID, viewport: settingsViewport())
    app.pending[id] = .settingsOpen
    app.notice("正在打开插件设置…")
    needsRender = true
}

@MainActor
func togglePlugin(_ bundleID: String) {
    guard let plugin = app.plugins.first(where: { $0.bundleID == bundleID }) else { return }
    let enable = !plugin.enabled
    let id = client.send(enable ? .pluginEnable : .pluginDisable, bundleID: bundleID)
    app.pending[id] = enable ? .enable(bundleID) : .disable(bundleID)
    app.notice(enable ? "正在启用 \(bundleID)…" : "正在禁用 \(bundleID)…")
}

@MainActor
func sendSettingsInput(_ input: SettingsInput) {
    guard let panel = app.settings else { return }
    if panel.busy {
        // Keep fast arrow-key runs in order instead of dropping every key after the first.
        app.settingsInputQueue.append(input)
        return
    }
    let id = client.send(
        .pluginSettingsInput, settingsSessionID: panel.snapshot.sessionID, settingsInput: input
    )
    app.pending[id] = .settingsInput
    app.settings?.busy = true
    needsRender = true
}

@MainActor
func saveSettings() {
    guard let panel = app.settings else { return }
    if panel.busy {
        app.settingsSavePending = true
        return
    }
    let id = client.send(.pluginSettingsSave, settingsSessionID: panel.snapshot.sessionID)
    app.pending[id] = .settingsSave
    app.settings?.busy = true
    needsRender = true
}

@MainActor
func cancelSettings() {
    guard let panel = app.settings else { return }
    // The host keeps the final word: close the container immediately even if the plugin is busy
    // or its cancellation call is slow. Core tears the settings host down independently.
    app.settings = nil
    app.exitDialog = nil
    app.settingsInputQueue.removeAll()
    app.settingsSavePending = false
    app.settingsCredentialRefresh = false
    _ = client.send(.pluginSettingsCancel, settingsSessionID: panel.snapshot.sessionID)
    needsRender = true
}

/// Closes the settings window after the Core reported that its session or plugin host is gone. A
/// dead session can never be driven again, and leaving the panel up would swallow every later key
/// press — including the ones needed to get back to /quit.
@MainActor
func closeSettingsAfterHostFailure(_ reason: String) {
    guard app.settings != nil else { return }
    app.settings = nil
    app.exitDialog = nil
    app.confirmation = nil
    app.settingsInputQueue.removeAll()
    app.settingsSavePending = false
    app.settingsCredentialRefresh = false
    app.authBusy = false
    app.notice("插件设置已关闭：\(reason)", sticky: true)
    needsRender = true
}

/// The Core reports settings failures as text only (there is no error code on the wire yet), so the
/// frontend recognises exactly the descriptions that mean "this settings session can never work again":
/// the session is gone, or the settings host itself failed. A failure the Core wrapped in one of its
/// own settings errors ("settings could not be applied: ...") came from the plugin or from another
/// host, and the window can still be driven, so the draft stays on screen.
func isSettingsSessionLost(_ error: String?) -> Bool {
    guard let error else { return false }
    if error.contains("the settings session is no longer open") { return true }
    // Raw `String(describing:)` of PluginSession.SessionError: the settings host died or timed out.
    return error.hasPrefix("hostFailed(") || error.hasPrefix("notRunning")
}

/// Asks the Core whether the open settings session survived a failed save. The save reply reports one
/// error string without saying which host produced it, and the two cases need opposite behaviour: a
/// dead settings host must close the window, a rejected draft must keep it. A resize to the current
/// viewport is the cheapest request that answers exactly that question without touching the plugin's
/// own state.
@MainActor
func verifySettingsSession() {
    guard let panel = app.settings, !app.settingsSavePending else { return }
    let id = client.send(
        .pluginSettingsResize, settingsSessionID: panel.snapshot.sessionID,
        viewport: panel.snapshot.viewport
    )
    app.pending[id] = .settingsVerify(panel.snapshot.sessionID)
}

@MainActor
func handleSettingsKey(_ key: Key) {
    if app.exitDialog != nil {
        handleExitDialogKey(key)
        return
    }
    switch key {
    case .escape:
        // A clean draft closes at once. A dirty one — or one the plugin does not track, which is
        // reported as nil — asks first instead of silently discarding the user's edits.
        if app.settings?.snapshot.dirty == false {
            cancelSettings()
        } else {
            app.exitDialog = ExitDialog()
            needsRender = true
        }
    case .saveSettings:
        saveSettings()
    case .up: sendSettingsInput(SettingsInput(kind: .key, key: "up"))
    case .down: sendSettingsInput(SettingsInput(kind: .key, key: "down"))
    case .left: sendSettingsInput(SettingsInput(kind: .key, key: "left"))
    case .right: sendSettingsInput(SettingsInput(kind: .key, key: "right"))
    case .tab: sendSettingsInput(SettingsInput(kind: .key, key: "tab"))
    case .enter, .newline: sendSettingsInput(SettingsInput(kind: .key, key: "enter"))
    case .backspace: sendSettingsInput(SettingsInput(kind: .key, key: "backspace"))
    case .delete: sendSettingsInput(SettingsInput(kind: .key, key: "delete"))
    case .pageUp: sendSettingsInput(SettingsInput(kind: .key, key: "pageUp"))
    case .pageDown: sendSettingsInput(SettingsInput(kind: .key, key: "pageDown"))
    case .scrollUp: sendSettingsInput(SettingsInput(kind: .mouse, delta: 1))
    case .scrollDown: sendSettingsInput(SettingsInput(kind: .mouse, delta: -1))
    case .character(let character):
        sendSettingsInput(SettingsInput(kind: .key, key: "char", char: String(character)))
    case .interrupt:
        shutdown()
        exit(0)
    default:
        break
    }
}

/// Keyboard for the host-owned unsaved-changes prompt: Left/Right/Tab move, Enter confirms the
/// selected button, Escape goes back to editing (the same as choosing 继续编辑).
@MainActor
func handleExitDialogKey(_ key: Key) {
    guard var dialog = app.exitDialog else { return }
    switch key {
    case .left:
        dialog.selected = (dialog.selected + ExitDialog.buttons.count - 1) % ExitDialog.buttons.count
    case .right, .tab:
        dialog.selected = (dialog.selected + 1) % ExitDialog.buttons.count
    case .enter, .newline:
        app.exitDialog = nil
        confirmExitDialog(dialog.selected)
        return
    case .escape:
        // Escape is "keep editing": the dialog closes and the draft stays exactly as it was.
        app.exitDialog = nil
        needsRender = true
        return
    case .interrupt:
        shutdown()
        exit(0)
    default:
        break
    }
    app.exitDialog = dialog
    needsRender = true
}

@MainActor
func confirmExitDialog(_ button: Int) {
    switch button {
    case 0:
        // Keep the window: a failed save must leave the draft and the error visible.
        saveSettings()
    case 1:
        cancelSettings()
    default:
        break
    }
    needsRender = true
}

@MainActor
func handleSettingsCommand(_ command: SettingsCommand?) {
    guard let command, let panel = app.settings else { return }
    // A plugin command is newer than the host's own "unsaved changes" prompt, so it takes the screen:
    // the two host-owned modals never stack, which keeps mouse routing and drawing order identical.
    app.exitDialog = nil
    let provider = command.providerID ?? ""
    switch command.type {
    case "credential.update":
        app.authBusy = true
        let id = client.send(
            .pluginSettingsCredential, provider: provider,
            settingsSessionID: panel.snapshot.sessionID,
            settingsCredentialAction: "update"
        )
        app.pending[id] = .settingsCredential("update")
    case "credential.remove":
        app.confirmation = Confirmation(
            title: "删除凭据",
            message: "插件请求删除 \(provider) 的 API Key。确认后无法恢复。",
            providerID: provider,
            settingsSessionID: panel.snapshot.sessionID
        )
    default:
        app.notice("插件请求了未知操作：\(command.type)")
    }
}

@MainActor
func handleConfirmationKey(_ key: Key) {
    guard var confirmation = app.confirmation else { return }
    switch key {
    case .left, .right, .tab:
        confirmation.selected = confirmation.selected == 0 ? 1 : 0
        app.confirmation = confirmation
    case .enter:
        confirmCredentialRemoval(confirmation)
        return
    case .escape, .interrupt:
        app.confirmation = nil
        app.notice("已取消删除凭据。")
    default:
        break
    }
    needsRender = true
}

/// Commits a host-owned confirmation dialog. Index 0 is 确认, 1 is 取消; the mouse routes here too so
/// a click and Enter can never disagree about which button was chosen.
@MainActor
func confirmCredentialRemoval(_ confirmation: Confirmation) {
    app.confirmation = nil
    switch confirmation.selected {
    case 0:
        app.authBusy = true
        let id = client.send(
            .pluginSettingsCredential, provider: confirmation.providerID,
            settingsSessionID: confirmation.settingsSessionID,
            settingsCredentialAction: "remove",
            settingsCredentialConfirmed: true
        )
        app.pending[id] = .settingsCredential("remove")
    default:
        app.notice("已取消删除凭据。")
    }
    needsRender = true
}

/// Credential state lives behind the host's secure input flow. Reopening the settings session is
/// the simplest way to give the plugin the new status-only view without ever showing it a secret.
@MainActor
func refreshSettingsAfterCredential() {
    guard let panel = app.settings else {
        app.settingsCredentialRefresh = false
        return
    }
    let bundleID = panel.snapshot.bundleID
    let sessionID = panel.snapshot.sessionID
    app.settings = nil
    app.settingsCredentialRefresh = false
    _ = client.send(.pluginSettingsCancel, settingsSessionID: sessionID)
    openPluginSettings(bundleID)
}

@MainActor
func handleReply(_ reply: FrontendReply) {
    let pending = app.pending.removeValue(forKey: reply.id)
    if let models = reply.models { app.models = models }
    if let details = reply.modelDetails {
        app.modelDetails = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    if let sessions = reply.sessions { app.sessions = sessions }
    if let plugins = reply.plugins { app.plugins = plugins }
    // Provider state is the Core's answer, never a local guess: it also carries a temporary
    // thinking selection merged in front of the plugin's own configuration.
    if let states = reply.providerStates { app.providerStates = states }

    switch pending {
    case .hello:
        if app.model == nil || !(app.models.contains(app.model!)) { app.model = app.models.first }
        if let preferred = reply.preferredModel, app.models.contains(preferred) { app.model = preferred }
        if app.models.isEmpty {
            app.notice("没有可用模型。请安装并启用 Provider 插件；本地构建的插件需要显式设置 LINGXI_PLUGIN_POLICY=development。用 /plugins 查看状态。", sticky: true)
        } else if !app.sessions.isEmpty {
            app.notice("欢迎回来。已有 \(app.sessions.count) 个会话，用 /sessions 继续，或直接输入开始新对话。", sticky: true)
        } else {
            app.notice("首次使用：/auth 连接模型。已有 Key 只需配置一次。", sticky: true)
        }
    case .plugins:

        showPluginList()
    case .sessions:
        app.picker = Picker(title: "切换会话", items: app.sessions.enumerated().map { index, session in
            MenuItem(title: session.title, detail: (session.id == app.activeSession ? "当前 · " : "") + "\(session.turns) 轮",
                     command: "/switch \(index + 1)")
        })
    case .chat(let text):
        if reply.ok {
            app.activeSession = reply.sessionID
            app.runID = reply.runID
        } else {
            app.running = false
            if app.messages.last?.role == .user { app.messages.removeLast() }
            if app.input.isEmpty { app.input = Array(text); app.cursor = app.input.count }
            app.error(reply.error ?? "发送失败")
        }
    case .history(let sessionID):
        guard app.activeSession == sessionID else { return }
        app.scroll = 0
        if let history = reply.history {
            app.messages = history.map { entry in
                switch entry.kind {
                case "tool": Message(role: .toolResult, text: entry.text)
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
        if app.pluginList { showPluginList() }
    case .disable(let bundleID):
        if !reply.ok {
            app.error("插件操作失败：\(reply.error ?? "未知错误")")
        } else {
            app.notice("已禁用 \(bundleID)。")
        }
        if app.pluginList { showPluginList() }
    case .settingsOpen:
        if let snapshot = reply.settings {
            app.settings = SettingsPanel(snapshot: snapshot)
            app.settingsInputQueue.removeAll()
            app.settingsSavePending = false
            app.pluginList = false
            handleSettingsCommand(snapshot.command)
        } else {
            app.error(reply.error ?? "无法打开插件设置。")
        }
    case .settingsInput, .settingsResize:
        if let snapshot = reply.settings {
            app.settings?.snapshot = snapshot
            app.settings?.busy = false
            app.settings?.error = nil
            handleSettingsCommand(snapshot.command)
            if !app.settingsInputQueue.isEmpty, app.settings != nil {
                let next = app.settingsInputQueue.removeFirst()
                sendSettingsInput(next)
            } else if app.settingsSavePending, app.settings != nil {
                app.settingsSavePending = false
                saveSettings()
            }
        } else {
            // Core drops a settings session on any input failure: the plugin host is gone or its
            // frame was invalid. The window is unusable, so close it rather than swallow keys.
            app.settings?.busy = false
            closeSettingsAfterHostFailure(reply.error ?? "插件设置进程已退出。")
        }
    case .settingsSave:

        if reply.ok {
            app.settings = nil
            app.exitDialog = nil
            app.settingsInputQueue.removeAll()
            app.settingsSavePending = false
            app.settingsCredentialRefresh = false
            if let preferred = reply.preferredModel, app.models.contains(preferred) { app.model = preferred }
            app.notice("设置已保存。")
        } else if isSettingsSessionLost(reply.error) {
            app.settings?.busy = false
            closeSettingsAfterHostFailure(reply.error ?? "插件设置进程已退出。")
        } else {
            // A rejected draft is not a dead session: keep the window, the draft and the error, then
            // let the Core say whether the session is still there.
            let message = reply.error ?? "设置保存失败。"
            app.settings?.busy = false
            app.settings?.error = message
            app.error(message)
            verifySettingsSession()
        }
    case .settingsVerify(let sessionID):
        guard app.settings?.snapshot.sessionID == sessionID, app.settings?.busy != true else { break }
        if let snapshot = reply.settings {
            // The session survived the save attempt, so the draft window and its error stay.
            app.settings?.snapshot = snapshot
            app.settings?.busy = false
        } else {
            closeSettingsAfterHostFailure(reply.error ?? "插件设置进程已退出。")
        }
    case .settingsCancel:
        app.settings = nil
        app.exitDialog = nil
        app.settingsCredentialRefresh = false
    case .settingsCredential(let action):
        app.authBusy = false
        if !reply.ok {
            if isSettingsSessionLost(reply.error) {
                closeSettingsAfterHostFailure(reply.error ?? "插件设置进程已退出。")
            } else {
                app.error(reply.error ?? "凭据操作被拒绝。")
            }
        } else if let state = reply.credentials?.first {
            if action == "update" {
                app.settingsCredentialRefresh = true
                app.secretInput = SecretInput(provider: state.providerID, label: state.label)
                app.feedback = nil
            } else if action == "remove" {
                refreshSettingsAfterCredential()
            }
        }
    case .reasoning(let level):
        if reply.ok {
            let label = level.flatMap { id in
                app.model.flatMap { model -> String? in
                    let summary = app.modelDetails[model]
                    let declared = (summary?.thinkingProfiles ?? []).flatMap(\.levels) + (summary?.thinkingLevels ?? [])
                    return declared.first { $0.id == id }?.label
                }
            }
            if let label {
                app.notice("已临时切换思考模式：\(label)。Ctrl-S 不会保存它；/reasoning 可恢复跟随插件。")
            } else {
                app.notice("已恢复跟随插件的思考设置。")
            }
        } else {
            app.error("思考模式未切换：\(reply.error ?? "未知错误")")
        }
    case .auth(let provider, let action):
        app.authBusy = false
        if !reply.ok {
            app.error("凭据操作失败：\(reply.error ?? "未知错误")")
        } else if let state = reply.credentials?.first {
            if action == "set" || action == "update" || action == "settings-update" {
                if state.configured && action == "set" {
                    app.notice("\(provider) 已配置（\(state.source)）。更新请用 /auth \(provider) update。")
                } else {
                    app.secretInput = SecretInput(provider: provider, label: state.label)
                    app.feedback = nil
                }
            } else {
                let stateText = state.configured ? "已配置（\(state.source)）" : "未配置"
                app.notice("\(provider)：\(stateText)。" + (action == "saved" ? "可立即发送新请求。" : ""))
                if action == "settings-remove" || action == "settings-saved" {
                    refreshSettingsAfterCredential()
                }
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
    case "delta", "reasoning":
        guard app.running, event.runID == app.runID else { break }
        let role: Role = event.event == "reasoning" ? .reasoning : .assistant
        guard let delta = role == .reasoning ? event.reasoning : event.delta else { break }
        if let last = app.messages.indices.last, app.messages[last].role == role, app.messages[last].streaming {
            app.messages[last].text += delta
        } else {
            if let last = app.messages.indices.last { app.messages[last].streaming = false }
            app.messages.append(Message(role: role, text: delta, streaming: true))
        }
    case "tool":
        guard app.running, event.runID == app.runID, let name = event.tool else { break }
        let text = name + (event.detail.map { "  " + $0 } ?? "")
        if event.status == "requested",
           let index = app.messages.indices.last(where: { app.messages[$0].role == .tool && app.messages[$0].streaming }) {
            app.messages[index].text = text
            app.messages[index].streaming = false
        } else {
            if let last = app.messages.indices.last { app.messages[last].streaming = false }
            app.messages.append(Message(role: .tool, text: text, streaming: event.status == "started"))
        }
    case "usage":
        guard event.runID == app.runID, let usage = event.usage else { break }
        if let input = usage.inputTokens { app.runInputTokens = (app.runInputTokens ?? 0) + input }
        if let output = usage.outputTokens { app.runOutputTokens = (app.runOutputTokens ?? 0) + output }
    case "run.state":
        if let status = event.status, status == "running" {
            app.running = true
            app.cancelling = false
            app.runID = event.runID
            app.activeSession = event.sessionID
        }
    case "run.terminal":
        guard event.runID == app.runID else { break }
        app.running = false
        app.cancelling = false
        app.runID = nil
        for index in app.messages.indices { app.messages[index].streaming = false }
        if let sessions = event.sessions { app.sessions = sessions }
        app.feedback = nil
        var meta: [String] = []
        if let model = app.model { meta.append(model) }
        if let started = app.runStarted { meta.append(String(format: "%.1fs", Date().timeIntervalSince(started))) }
        if let input = app.runInputTokens { meta.append("↑" + formatTokens(input)) }
        if let output = app.runOutputTokens { meta.append("↓" + formatTokens(output)) }
        if event.status != "completed" {
            let cause = event.cause ?? "unknown"
            let detail = event.detail.map { " — \($0)" } ?? ""
            meta.append(event.status == "cancelled" ? "已取消" : "未完成")
            app.messages.append(Message(role: .error, text: "运行结束：\(event.status ?? "failed") / \(cause)\(detail)"))
        }
        // Diagnostics belong to this run only: the record is replaced, never accumulated.
        let renderMs = Int(app.runRenderNanos / 1_000_000)
        let diagnostics = app.runTiming.map {
            RunDiagnostics(
                model: app.runModel ?? app.model, timing: timing($0, renderMs: renderMs),
                frames: app.runFrames, renderMs: renderMs
            )
        }
        app.lastDiagnostics = diagnostics
        if let index = app.messages.indices.last(where: { $0 >= app.runFirstMessage && app.messages[$0].role == .assistant }) {
            app.messages[index].meta = meta.joined(separator: "  ·  ")
            if let diagnostics { app.messages[index].diagnostics = compactDiagnostic(diagnostics) }
        }
        app.runStarted = nil
    case "timing":
        guard event.runID == app.runID, let timing = event.timing else { break }
        app.runTiming = timing
    case "providers.state":
        if let states = event.providerStates { app.providerStates = states }
    case "plugins.changed":
        if let plugins = event.plugins {
            app.plugins = plugins
        }
    case "models.changed":
        if let details = event.modelDetails {
            app.modelDetails = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let states = event.providerStates { app.providerStates = states }
        if let models = event.models {
            app.models = models
            if let current = app.model, !models.contains(current) {
                app.model = models.first
                if !isPluginFeedback(app.feedback) {
                    app.notice("模型 \(current) 已不可用；当前模型：\(app.model ?? "无")")
                }
            }
            if app.model == nil, let preferred = event.preferredModel, models.contains(preferred) {
                app.model = preferred
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
    if app.promptHistory.last != trimmed { app.promptHistory.append(trimmed) }
    if app.promptHistory.count > 100 { app.promptHistory.removeFirst() }
    app.historyIndex = nil
    app.historyDraft = []
    app.feedback = nil
    app.scroll = 0
    app.running = true
    app.runStarted = Date()
    app.runModel = model
    app.runFirstMessage = app.messages.count
    app.runInputTokens = nil
    app.runOutputTokens = nil
    app.runTiming = nil
    app.runRenderNanos = 0
    app.runFrames = 0
    let id = client.send(.chatSend, sessionID: app.activeSession, model: model, text: trimmed)
    app.pending[id] = .chat(trimmed)
}

/// Applies a saved plugin list: only entries whose checkbox differs from the registry are sent.
@MainActor
func savePlugins(_ items: [MenuItem]) {
    var enabled: [String] = []
    var disabled: [String] = []
    for item in items {
        guard let checked = item.checked, let plugin = app.plugins.first(where: { $0.bundleID == item.command }),
              checked != plugin.enabled else { continue }
        let id = checked ? client.send(.pluginEnable, bundleID: item.command) : client.send(.pluginDisable, bundleID: item.command)
        app.pending[id] = checked ? .enable(item.command) : .disable(item.command)
        if checked { enabled.append(item.command) } else { disabled.append(item.command) }
    }
    if enabled.isEmpty && disabled.isEmpty {
        app.notice("插件未修改。")
    } else {
        app.notice("正在保存：" + (enabled.isEmpty ? "" : "启用 " + enabled.joined(separator: ", ") + "  ")
            + (disabled.isEmpty ? "" : "禁用 " + disabled.joined(separator: ", ")))
    }
}

@MainActor
func setMouse(_ enabled: Bool) {
    app.mouse = enabled
    output.write(Data((enabled ? "\u{1B}[?1000h\u{1B}[?1006h" : "\u{1B}[?1000l\u{1B}[?1006l").utf8))
}

// MARK: - mouse

/// The region under a terminal cell, from the last drawn frame. Hit regions are produced by the
/// renderer because it owns layout; this loop never re-derives panel geometry.
@MainActor
func hitRegion(row: Int, column: Int) -> HitRegion? {
    // Later regions are drawn on top of earlier ones, so the last match is the visible target: a
    // dialog button above the settings panel wins over the plugin frame behind it, and a toggle
    // checkbox wins over the row it sits in.
    app.lastFrame.hits.last { $0.contains(row: row, column: column) }
}

/// Routes one mouse report. Wheel first: it is the only event a host chrome cell may honour (scroll),
/// and it never activates anything. Presses follow the same modality order as the keyboard.
@MainActor
func handleMouse(_ event: MouseEvent) {
    guard app.mouse, !app.authBusy, app.secretInput == nil, !app.coreGone else { return }
    if app.confirmation != nil {
        guard event.button == .left, event.pressed else { return }
        clickedDialogButton(event) { index in
            guard var confirmation = app.confirmation else { return }
            confirmation.selected = index
            app.confirmation = confirmation
            confirmCredentialRemoval(confirmation)
        }
        return
    }
    if app.settings != nil {
        if app.exitDialog != nil {
            guard event.button == .left, event.pressed else { return }
            clickedDialogButton(event) { index in
                guard var dialog = app.exitDialog else { return }
                dialog.selected = index
                app.exitDialog = nil
                confirmExitDialog(dialog.selected)
            }
            return
        }
        forwardSettingsMouse(event)
        return
    }
    if app.pluginList || app.picker != nil {
        if event.isWheel {
            movePickerSelection(event.delta)
            return
        }
        guard event.button == .left, event.pressed else { return }
        clickedPickerRow(event)
        return
    }
    if event.isWheel {
        // Main view: the wheel scrolls the conversation, exactly like the keyboard scroll keys.
        scrollBy(event.delta * 3)
        needsRender = true
        return
    }
    guard event.button == .left, event.pressed else { return }
    // Host-owned composer/status controls are ordinary hit regions, never hardcoded coordinates.
    if let region = hitRegion(row: event.row, column: event.column) {
        switch region.kind {
        case .sendButton:
            submitDraft()
            return
        case .modelName:
            openModelPicker()
            return
        case .thinkingStatus:
            reasoningCommand("")
            return
        case .commandHint:
            app.picker = Picker(title: "命令", items: commandItems)
            needsRender = true
            return
        default:
            break
        }
    }
    // A left press anywhere else may land on the slash-command completion list; that handler ignores
    // every region it does not own, so no extra layout knowledge is needed here.
    clickedPickerRow(event)
}

/// The send button's action is the same as Enter: it submits the draft through the one send path.
/// While a run is live the renderer emits no send region, and this guard keeps a stale frame from
/// submitting too.
@MainActor
func submitDraft() {
    guard !app.running else {
        app.notice("仍在上一次生成中；按 Esc 取消。草稿已保留。")
        return
    }
    if let completion = slashPicker(), completion.items.indices.contains(completion.selected) {
        app.input = []
        app.cursor = 0
        app.completionIndex = 0
        runCommand(completion.items[completion.selected].command)
        return
    }
    let text = String(app.input)
    app.input = []
    app.cursor = 0
    submit(text)
}

/// The model picker is shared by `/models` and a click on the composer's model name.
@MainActor
func openModelPicker() {
    app.picker = Picker(title: "切换模型", items: app.models.map { model in
        let status = [model == app.model ? "当前模型" : nil, app.thinkingLabel(for: model).map { "思考 " + $0 }]
            .compactMap { $0 }.joined(separator: " · ")
        return MenuItem(title: model, detail: status, command: "/model " + model)
    }, selected: app.models.firstIndex { $0 == app.model } ?? 0)
    needsRender = true
}

/// Forwards a press or wheel notch inside the plugin frame as a SettingsInput(.mouse). Coordinates
/// become relative to the frame's first cell; anything on host chrome is dropped.
@MainActor
func forwardSettingsMouse(_ event: MouseEvent) {
    guard let panel = app.settings else { return }
    // SettingsInput has no press/release flag, so a release must never be forwarded: the plugin would
    // act on the same cell twice and a toggle would cancel itself out.
    guard event.isWheel || event.pressed else { return }
    guard let region = hitRegion(row: event.row, column: event.column), region.kind == .settingsFrame else {
        return
    }
    let row = event.row - region.row
    let column = event.column - region.column
    guard row >= 0, row < min(panel.snapshot.viewport.height, region.rows),
          column >= 0, column < min(panel.snapshot.viewport.width, region.columns) else { return }
    sendSettingsInput(SettingsInput(
        kind: .mouse, row: row, column: column, delta: event.isWheel ? event.delta : nil
    ))
}

/// A click on a host-owned dialog button. Buttons are drawn in a known order, so the hit region's
/// index is the decision.
@MainActor
func clickedDialogButton(_ event: MouseEvent, action: (Int) -> Void) {
    guard let region = hitRegion(row: event.row, column: event.column),
          case .dialogButton(let index) = region.kind else { return }
    action(index)
    needsRender = true
}

/// A click on a picker, plugin-list or completion row: select it in the same index the keyboard uses,
/// then run the row's default action. A click on a toggle checkbox is Space; anywhere else is Enter.
@MainActor
func clickedPickerRow(_ event: MouseEvent) {
    guard let region = hitRegion(row: event.row, column: event.column) else { return }
    switch region.kind {
    case .completionRow(let index):
        guard let completion = slashPicker(), completion.items.indices.contains(index) else { return }
        app.completionIndex = index
        app.input = []
        app.cursor = 0
        app.completionIndex = 0
        runCommand(completion.items[index].command)
    case .pickerRow(let index, let checkbox):
        if app.pluginList, var picker = app.picker {
            picker.selected = index
            app.picker = picker
            guard picker.filtered.indices.contains(index) else { return }
            if checkbox {
                togglePlugin(picker.filtered[index].command)
            } else {
                openPluginSettings(picker.filtered[index].command)
            }
        } else if var picker = app.picker {
            picker.selected = index
            app.picker = picker
            guard picker.filtered.indices.contains(index) else { return }
            if picker.isToggleList, checkbox,
               let item = picker.items.firstIndex(where: { $0.command == picker.filtered[index].command }) {
                app.picker?.items[item].checked?.toggle()
            } else if picker.isToggleList {
                app.picker = nil
                savePlugins(picker.items)
            } else {
                app.picker = nil
                if app.input.first == "/" { app.input = []; app.cursor = 0; app.completionIndex = 0 }
                runCommand(picker.filtered[index].command)
            }
        }
    case .dialogButton, .settingsFrame, .modelName, .thinkingStatus, .commandHint, .sendButton:
        return
    }
    needsRender = true
}

@MainActor
func movePickerSelection(_ direction: Int) {
    guard var picker = app.picker else { return }
    let count = max(0, picker.filtered.count)
    picker.selected = min(max(0, picker.selected + direction), max(0, count - 1))
    app.picker = picker
    needsRender = true
}

@MainActor
func copyLastReply() {
    guard let reply = app.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) else {
        app.error("还没有可复制的回复。")
        return
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    process.standardInput = pipe
    do {
        try process.run()
        pipe.fileHandleForWriting.write(Data(reply.text.utf8))
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        app.notice("已复制最后一条回复（\(reply.text.count) 字）。")
    } catch {
        app.error("复制失败：\(error.localizedDescription)")
    }
}

@MainActor
func runCommand(_ raw: String) {
    let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
    let command = parts[0]
    let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    if app.running, ["/switch", "/new", "/clear"].contains(command) {
        app.notice("请先按 Esc 取消当前生成，再切换或清理会话。")
        return
    }
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
        app.pending[id] = .history(session.id)
    case "/new":
        app.activeSession = nil
        app.messages = []
        app.scroll = 0
        app.notice("新会话。输入消息开始。")
    case "/models":
        openModelPicker()
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
                MenuItem(title: $0, detail: "API Key · Keychain", command: "/auth " + $0)
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
    case "/thinking":
        app.showThinking.toggle()
    case "/reasoning":
        reasoningCommand(argument)
    case "/perf":
        performanceCommand()
    case "/copy":
        copyLastReply()
    case "/mouse":
        setMouse(!app.mouse)
        app.notice(app.mouse ? "已开启鼠标：滚轮滚动、点击选择。终端原生选择需按住 fn（Terminal）或 ⌥（iTerm2）拖动；/mouse 关闭。"
                             : "已关闭鼠标捕获，可直接拖选复制。")
    case "/quit", "/exit":
        shutdown()
        exit(0)
    default:
        app.error("未知命令：\(command)。用 /help 查看。")
    }
}

// MARK: - reasoning

/// `/reasoning` offers the current model's own declared thinking levels plus one explicit
/// "follow the plugin's settings" entry. The labels come from the plugin's declaration; the TUI never
/// knows a vendor vocabulary and never invents a level.
@MainActor
func reasoningCommand(_ argument: String) {
    guard let model = app.model else {
        app.error("当前没有可用模型，无法切换思考模式。")
        return
    }
    let provider = app.modelDetails[model]?.provider
    let summary = app.modelDetails[model]
    let state = app.providerState(for: model)
    // Pick the ladder for the protocol that is live right now. Falling back to a single declared
    // profile keeps a provider usable before it has reported state; never merge two ladders.
    let profile: ModelThinkingProfile? = {
        guard let profiles = summary?.thinkingProfiles, !profiles.isEmpty else { return nil }
        if let kind = state?.protocolKind, let matched = profiles.first(where: { $0.protocolKind == kind }) {
            return matched
        }
        return profiles.count == 1 ? profiles[0] : nil
    }()
    let levels = profile?.levels ?? summary?.thinkingLevels ?? []
    let axis = profile?.axisLabel ?? state?.thinkingAxisLabel
    if argument.isEmpty {
        guard !levels.isEmpty else {
            if let profiles = summary?.thinkingProfiles, profiles.count > 1, state?.protocolKind == nil {
                app.notice("插件为多个协议声明了思考档位，但尚未报告当前协议；稍后再试或先发送一次消息。")
            } else {
                app.notice("当前模型没有声明思考级别，无法临时切换。")
            }
            return
        }
        let current = state
        let override = current?.overridden == true ? current?.thinkingLevel : nil
        var items: [MenuItem] = [MenuItem(
            title: "跟随插件设置",
            detail: override == nil ? "当前" : "",
            command: "/reasoning follow"
        )]
        items += levels.map { level in
            MenuItem(
                title: level.label,
                detail: level.id == override ? "当前 · 临时" : "临时 · \(level.id)",
                command: "/reasoning \(level.id)"
            )
        }
        let title: String
        if let axis {
            title = "推理强度 · \(axis) · \(profile?.protocolLabel ?? state?.protocolLabel ?? "当前协议")"
        } else {
            title = "思考模式 · \(profile?.protocolLabel ?? state?.protocolLabel ?? model)"
        }
        app.picker = Picker(
            title: title, items: items, note: profile?.note,
            selected: override.flatMap { id in levels.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        )
        needsRender = true
        return
    }
    guard let provider else {
        app.error("模型 \(model) 没有所属 Provider，无法切换思考模式。")
        return
    }
    if argument == "follow" {
        let id = client.send(.providerReasoningSet, provider: provider, clearReasoning: true)
        app.pending[id] = .reasoning(nil)
        app.notice("正在恢复跟随插件设置…")
        return
    }
    // Accept any id the model declared for any protocol: the plugin decides whether it applies to
    // the protocol it is about to speak, and an unknown id there is ignored safely.
    let declared = (summary?.thinkingProfiles ?? []).flatMap(\.levels) + (summary?.thinkingLevels ?? [])
    guard declared.contains(where: { $0.id == argument }) else {
        app.error("模型 \(model) 没有声明思考级别 \(argument)；可用：\(levels.map(\.id).joined(separator: ", "))")
        return
    }
    let id = client.send(
        .providerReasoningSet, model: model, provider: provider, reasoningLevel: argument
    )
    app.pending[id] = .reasoning(argument)
    app.notice("正在切换思考模式…")
}

// MARK: - diagnostics

/// `/perf` prints the last run's numbers: Core preparation, plugin phases, upstream first-byte and
/// first-token latencies, and the TUI's own render cost. Numbers only, never prompt or reply text.
@MainActor
func performanceCommand() {
    if app.running {
        app.notice("本轮仍在进行中，结束后可用 /perf 查看完整诊断。")
        return
    }
    guard let diagnostics = app.lastDiagnostics else {
        app.notice("还没有运行诊断。先发送一次消息。")
        return
    }
    for line in performanceLines(diagnostics) {
        app.messages.append(Message(role: .system, text: line))
    }
    app.scroll = 0
    needsRender = true
}

private let commandItems: [MenuItem] = [
    .init(title: "连接模型", detail: "/auth", command: "/auth"),
    .init(title: "切换模型", detail: "/models", command: "/models"),
    .init(title: "切换思考模式", detail: "/reasoning", command: "/reasoning"),
    .init(title: "切换会话", detail: "/sessions", command: "/sessions"),
    .init(title: "新建会话", detail: "/new", command: "/new"),
    .init(title: "复制最后一条回复", detail: "/copy", command: "/copy"),
    .init(title: "展开 / 收起思考", detail: "/thinking · Ctrl-T", command: "/thinking"),
    .init(title: "性能诊断", detail: "/perf", command: "/perf"),
    .init(title: "插件", detail: "/plugins", command: "/plugins"),
    .init(title: "鼠标捕获", detail: "/mouse", command: "/mouse"),
    .init(title: "清屏", detail: "/clear", command: "/clear"),
    .init(title: "退出", detail: "/quit", command: "/quit"),
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

    if key == .pasteStart { app.pasting = true; app.pastedText = []; return }
    if key == .pasteEnd {
        if app.pasting, !app.authBusy, !app.discardInputBatch, !app.discardPaste, app.secretInput == nil {
            let text = String(app.pastedText).replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            if app.settings != nil {
                sendSettingsInput(SettingsInput(kind: .paste, text: text))
            } else if app.picker != nil {
                app.picker?.query += text.replacingOccurrences(of: "\n", with: " ")
                app.picker?.selected = 0
            } else { app.insert(text) }
        }
        app.pasting = false
        app.pastedText = []
        app.discardPaste = false
        needsRender = true
        return
    }
    if app.discardInputBatch || app.discardPaste { return }
    // Mouse is routed before the key chain so a click always follows the modality priority below,
    // and so the secret-input and credential states can refuse it outright.
    if case .mouse(let event) = key {
        handleMouse(event)
        return
    }
    if key == .redraw {
        output.write(Data("\u{1B}[2J".utf8))
        needsRender = true
        return
    }
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
        case .clearLine, .deleteWordBack:
            app.secretInput?.characters = []
            app.secretInput?.invalidPaste = false
        case .newline:
            app.secretInput?.invalidPaste = true
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
            let id = client.send(
                .authSet, provider: input.provider, secret: String(input.characters),
                settingsSessionID: app.settings?.snapshot.sessionID
            )
            app.pending[id] = .auth(input.provider, app.settingsCredentialRefresh ? "settings-saved" : "saved")
        case .escape, .interrupt, .endOfInput:
            app.secretInput = nil
            app.discardPaste = app.pasting
            app.discardInputBatch = true
            app.notice("已取消凭据输入。")
        default: break
        }
        needsRender = true
        return
    }
    if app.confirmation != nil {
        handleConfirmationKey(key)
        return
    }
    if app.settings != nil {
        handleSettingsKey(key)
        needsRender = true
        return
    }
    // Bracketed paste is text, never an action, even inside a picker.
    if app.pasting {
        switch key {
        case .character(let character): app.pastedText.append(character)
        case .enter: app.pastedText.append("\r")
        case .newline: app.pastedText.append("\n")
        case .tab: app.pastedText += [" ", " "]
        default: break
        }
        needsRender = true
        return
    }
    if app.pluginList, var picker = app.picker {
        switch key {
        case .up, .scrollUp: picker.selected = max(0, picker.selected - 1)
        case .down, .scrollDown: picker.selected = min(max(0, picker.filtered.count - 1), picker.selected + 1)
        case .pageUp: picker.selected = max(0, picker.selected - 8)
        case .pageDown: picker.selected = min(max(0, picker.filtered.count - 1), picker.selected + 8)
        case .character(" "):
            if picker.filtered.indices.contains(picker.selected) {
                togglePlugin(picker.filtered[picker.selected].command)
            }
        case .enter:
            if picker.filtered.indices.contains(picker.selected) {
                openPluginSettings(picker.filtered[picker.selected].command)
            }
            needsRender = true
            return
        case .escape, .interrupt, .commandPalette:
            app.picker = nil
            app.pluginList = false
            needsRender = true
            return
        default:
            break
        }
        app.picker = picker
        needsRender = true
        return
    }
    if var picker = app.picker {
        switch key {
        case .character(" ") where picker.isToggleList:
            let items = picker.filtered
            if items.indices.contains(picker.selected),
               let index = picker.items.firstIndex(where: { $0.command == items[picker.selected].command }) {
                picker.items[index].checked?.toggle()
            }
        case .enter where picker.isToggleList:
            app.picker = nil
            savePlugins(picker.items)
            needsRender = true
            return
        case .character(let character): picker.query.append(character); picker.selected = 0
        case .backspace: _ = picker.query.popLast(); picker.selected = 0
        case .clearLine, .deleteWordBack: picker.query = ""; picker.selected = 0
        case .up, .scrollUp: picker.selected = max(0, picker.selected - 1)
        case .down, .scrollDown: picker.selected = min(max(0, picker.filtered.count - 1), picker.selected + 1)
        case .pageUp: picker.selected = max(0, picker.selected - 8)
        case .pageDown: picker.selected = min(max(0, picker.filtered.count - 1), picker.selected + 8)
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
        app.insert(String(character))
    case .newline:
        app.insert("\n")
    case .enter:

        if app.running, !String(app.input).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            app.notice("仍在生成中；草稿已保留，按 Esc 取消。")
            break
        }
        if let completion, completion.items.indices.contains(completion.selected) {
            app.input = []; app.cursor = 0; app.completionIndex = 0
            runCommand(completion.items[completion.selected].command)
            break
        }
        if app.cursor > 0, app.input[app.cursor - 1] == "\\" {
            app.input[app.cursor - 1] = "\n"
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
        app.completionIndex = 0
    case .delete:
        guard app.cursor < app.input.count else { break }
        app.input.remove(at: app.cursor)
    case .deleteWordBack:
        let start = app.wordBoundary(-1)
        app.input.removeSubrange(start..<app.cursor)
        app.cursor = start
        app.completionIndex = 0
    case .killToEnd:
        let end = app.input[app.cursor...].firstIndex(of: "\n") ?? app.input.count
        app.input.removeSubrange(app.cursor..<(end == app.cursor && end < app.input.count ? end + 1 : end))
    case .left: app.cursor = max(0, app.cursor - 1)
    case .right: app.cursor = min(app.input.count, app.cursor + 1)
    case .wordLeft: app.cursor = app.wordBoundary(-1)
    case .wordRight: app.cursor = app.wordBoundary(1)
    case .home, .lineStart:
        app.cursor = (app.input[..<app.cursor].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
    case .end, .lineEnd:
        if key == .end, app.scroll > 0 { app.scroll = 0 }
        else { app.cursor = app.input[app.cursor...].firstIndex(of: "\n") ?? app.input.count }
    case .clearLine: app.input = []; app.cursor = 0; app.historyIndex = nil
    case .up:
        if completion != nil { app.completionIndex = max(0, app.completionIndex - 1) }
        else { moveInputVertically(-1) }
    case .down:
        if let completion { app.completionIndex = min(completion.items.count - 1, app.completionIndex + 1) }
        else { moveInputVertically(1) }
    case .pageUp: scrollBy(max(1, app.lastFrame.bodyHeight - 2))
    case .pageDown: scrollBy(-max(1, app.lastFrame.bodyHeight - 2))
    case .scrollUp: scrollBy(3)
    case .scrollDown: scrollBy(-3)
    case .escape:
        if app.running, let runID = app.runID {
            _ = client.send(.runCancel, runID: runID)
            app.cancelling = true
        } else {
            app.input = []; app.cursor = 0; app.historyIndex = nil
        }
    case .interrupt:
        if app.running, let runID = app.runID {
            _ = client.send(.runCancel, runID: runID)
            app.cancelling = true
        } else if !app.input.isEmpty {
            app.input = []; app.cursor = 0; app.historyIndex = nil
            app.notice("已清空输入。再按 Ctrl-C 退出。")
        } else {
            shutdown()
            exit(0)
        }
    case .endOfInput:
        if app.input.isEmpty { shutdown(); exit(0) }
        if app.cursor < app.input.count { app.input.remove(at: app.cursor) }
    case .commandPalette:
        app.picker = Picker(title: "命令", items: commandItems)
    case .toggleThinking: app.showThinking.toggle()
    case .tab:
        if let completion, completion.items.indices.contains(completion.selected) {
            app.input = Array(completion.items[completion.selected].command); app.cursor = app.input.count
            break
        }
        for _ in 0..<2 { app.input.insert(" ", at: app.cursor); app.cursor += 1 }
    case .unknown, .pasteStart, .pasteEnd, .redraw, .saveSettings, .mouse:
        break
    }
    needsRender = true
}

@MainActor
func scrollBy(_ lines: Int) {
    let limit = max(0, app.lastFrame.bodyLines - app.lastFrame.bodyHeight)
    app.scroll = min(limit, max(0, app.scroll + lines))
}

@MainActor
func moveInputVertically(_ direction: Int) {
    let start = (app.input[..<app.cursor].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
    let end = app.input[app.cursor...].firstIndex(of: "\n") ?? app.input.count
    let column = app.cursor - start
    if direction < 0, start > 0 {
        let previous = (app.input[..<(start - 1)].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
        app.cursor = min(previous + column, start - 1)
    } else if direction > 0, end < app.input.count {
        let nextEnd = app.input[(end + 1)...].firstIndex(of: "\n") ?? app.input.count
        app.cursor = min(end + 1 + column, nextEnd)
    } else {
        app.recall(direction)
    }
}

// MARK: - loop

draw()
while true {
    if resizePending {
        resizePending = false
        needsRender = true
        if let panel = app.settings, !panel.busy {
            let viewport = settingsViewport()
            if viewport.width != panel.snapshot.viewport.width || viewport.height != panel.snapshot.viewport.height {
                let id = client.send(
                    .pluginSettingsResize, settingsSessionID: panel.snapshot.sessionID, viewport: viewport
                )
                app.pending[id] = .settingsResize
                app.settings?.busy = true
            }
        }
    }
    keys.wait(milliseconds: 30)
    app.discardInputBatch = false
    for key in keys.drain() {
        // Two clicks can arrive in one batch; redraw first so the second click is hit-tested against
        // the frame it is actually pointing at.
        if case .mouse = key, needsRender { draw() }
        handleKey(key)
    }
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
        // A settings window can never be driven again once its Core is gone; close it instead of
        // leaving a modal that swallows every key, /quit included.
        if app.settings != nil {
            app.settings = nil
            app.exitDialog = nil
            app.confirmation = nil
            app.settingsInputQueue.removeAll()
            app.notice("Core 进程已退出，插件设置窗口已关闭。", sticky: true)
        } else {
            app.error("Core 进程已退出。按 Ctrl-C 退出。")
        }
    }
    if let expiry = app.feedbackExpiry, Date() >= expiry {
        app.feedback = nil
        app.feedbackExpiry = nil
        needsRender = true
    }
    // The elapsed-time counter in the status bar advances once per second while a run is live.
    if app.running, let started = app.runStarted {
        let second = Int(Date().timeIntervalSince(started))
        if second != renderedSecond { renderedSecond = second; needsRender = true }
    }
    if needsRender { draw() }
}
