import Darwin
import Foundation
import LingXiFrontendProtocol
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

/// Runs the real TUI inside a PTY (via /usr/bin/script) against a real Core and the real MiMo
/// plugin process, replaying a recorded cassette. No part of the UI is mocked.
final class PTYProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var captured = Data()

    init(environment: [String: String], columns: Int = 120, rows: Int = 30) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c",
            "/bin/stty cols \"$1\" rows \"$2\"; exec \"$3\"", "tui-test",
            String(columns), String(rows), builtProduct("LingXiTUI").path]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = output
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().async { [weak self] in
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return }
                self?.lock.lock(); self?.captured.append(chunk); self?.lock.unlock()
            }
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            while true {
                let chunk = self.output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                self.lock.lock(); self.captured.append(chunk); self.lock.unlock()
            }
        }
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    var latestFrame: String {
        let text = transcript
        guard let end = text.range(of: "\u{1B}[?2026l", options: .backwards),
              let start = text[..<end.lowerBound].range(of: "\u{1B}[?2026h", options: .backwards) else { return "" }
        return String(text[start.upperBound..<end.lowerBound])
    }

    var screenText: String {
        latestFrame.replacingOccurrences(of: "\u{1B}\\[[0-9]+;1H", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
    }

    func write(_ text: String) {
        stdin.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitFor(_ text: String, after start: Int = 0, timeout: Duration = .seconds(90)) async -> Bool {
        await waitUntil(timeout: timeout) { self.transcript.dropFirst(start).contains(text) }
    }

    func terminate() {
        if process.isRunning {
            // `script` does not guarantee forwarding SIGTERM to its child. Exit the TUI first.
            write("\u{03}\u{03}/quit\r")
            if !waitForProcessExit(process, timeout: 3) { kill(process.processIdentifier, SIGKILL) }
        }
        #expect(waitForProcessExit(process, timeout: 2), "PTY test process did not exit after cleanup")
    }

    var isRunning: Bool { process.isRunning }
    var status: Int32? { process.isRunning ? nil : process.terminationStatus }
}

func seedTUI(_ directory: URL, turns: Int = 1, slow: Bool = false) async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"), capabilities: ["provider.mimo", "settings.view.v1"]
    )
    var cassette = Bundle.module.url(forResource: "mimo-chat-tui", withExtension: "json", subdirectory: "Fixtures")!
    if turns > 1 {
        var fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cassette)) as? [String: Any])
        let exchanges = try #require(fixture["exchanges"] as? [[String: Any]])
        fixture["exchanges"] = Array(repeating: exchanges, count: turns).flatMap { $0 }
        cassette = directory.appendingPathComponent("tui-cassette.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: cassette)
    }
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0", bundlePath: bundle.url.path,
        enabled: true, grants: ["vcr=\(cassette.path)"] + (slow ? ["fault.slow"] : [])
    ))
}

@Test("TUI-003 multiline paste stays a draft, reasoning toggles, and follow-up prompts reuse the session", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_003_editorAndSessionContinuity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tui-editor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory, turns: 2, slow: true)
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment.removeValue(forKey: "MIMO_API_KEY")
    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })

    // Mixed terminal newlines normalize once; none may submit or invoke the pasted command.
    let prompt = "第一行 e\u{301}🙂\n/quit\n第三行"
    tui.write("\u{1B}[200~第一行 e\u{301}🙂\r\n/quit\n第三行\u{1B}[201~")
    try #require(await waitUntil { tui.screenText.contains("3 行") && tui.screenText.contains("第三行") })
    #expect(tui.screenText.contains("泠溪 · 2.0"))
    #expect(tui.isRunning)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.jsonl").path))
    // Edit the previous logical line using real cursor keys, then undo that insertion.
    tui.write("\u{1B}[A\u{1B}[H!\u{7F}\u{1B}[B\u{1B}[F")
    tui.write("\r")
    try #require(await waitUntil { tui.screenText.contains("生成中") })
    tui.write("后续草稿\r")
    try #require(await waitUntil { tui.screenText.contains("草稿已保留") })
    try #require(await waitUntil { tui.screenText.contains("pong") && !tui.screenText.contains("生成中") })
    #expect(!tui.screenText.contains("Simple request."))
    tui.write("\u{14}")
    try #require(await waitUntil { tui.screenText.contains("Simple request.") })
    tui.write("\u{14}")
    try #require(await waitUntil { !tui.screenText.contains("Simple request.") })

    // Prompt recall restores an unsent draft on the way back down.
    tui.write("\u{1B}[A")
    try #require(await waitUntil { tui.screenText.contains("3 行") })
    tui.write("\u{1B}[B")
    try #require(await waitUntil { tui.screenText.contains("后续草稿") })
    tui.write("\u{15}第二轮\u{0A}继续\u{1B}[13;2u测试")
    try #require(await waitUntil { tui.screenText.contains("3 行") && tui.screenText.contains("测试") })
    tui.write("\r")
    try #require(await waitUntil { tui.screenText.components(separatedBy: "pong").count == 3 && !tui.screenText.contains("生成中") })
    tui.write("/sessions\r")
    try #require(await waitUntil { tui.screenText.contains("2 轮") && tui.screenText.contains("esc 关闭") })
    // A title containing newlines must never write a raw LF into a cell-addressed row.
    #expect(!tui.latestFrame.contains("\n"))
    tui.write("\u{1B}")
    try #require(await waitUntil { !tui.screenText.contains("esc 关闭") })
    tui.write("/quit\r")
    try #require(await waitUntil { !tui.isRunning })
    #expect(tui.status == 0)

    // Verify the durable Core state after a fresh process starts, rather than trusting the label.
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    let hello = try #require(await core.waitReply(core.send(.hello)))
    let sessions = try #require(hello.sessions)
    #expect(sessions.count == 1)
    #expect(sessions.first?.turns == 2)
    let session = try #require(sessions.first)
    let history = try #require(await core.waitReply(core.send(.sessionHistory, sessionID: session.id)))
    #expect(history.history?.filter { $0.role == "user" }.map(\.text) == [prompt, "第二轮\n继续\n测试"])
}

@Test("TUI-001 the real TUI chats with MiMo over a PTY, shows plugins and exits cleanly", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_001_ptyChatWithMiMo() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)

    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
    environment.removeValue(forKey: "LINGXI_FRONTEND")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }

    // The Core activates plugins at startup; wait until the greeting reports a live model.
    #expect(await tui.waitFor("mimo-v2.6-flash"), "startup transcript tail: \(tui.transcript.suffix(800))")
    #expect(tui.transcript.contains("mimo-v2.6-flash"))

    // Chinese input goes through the real key parser; the reply streams from the recorded provider.
    tui.write("你好\r")
    if !(await tui.waitFor("pong")) {
        let clean = tui.transcript.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
        Issue.record("TRANSCRIPT=[\(clean.suffix(2500))]")
    }

    // The reply footer carries model and cassette token usage from the new `usage` event.
    #expect(await waitUntil { tui.screenText.contains("↑89") && tui.screenText.contains("↓7") },
            "footer missing: \(tui.screenText)")

    tui.write("/plugins\r")
    #expect(await tui.waitFor("site.lingxi.provider.mimo"), "plugins transcript tail: \(tui.transcript.suffix(1500))")
    #expect(tui.transcript.contains("provider.mimo"))
    try #require(await waitUntil { tui.screenText.contains("运行中") })
    // Space toggles immediately; the list detail reports the committed state.
    tui.write(" ")
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("已禁用") })
    tui.write(" ")
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("运行中") })
    #expect(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") }, "model did not return after enabling")

    // Enter opens the plugin-owned settings page, not a save action.
    tui.write("\r")
    try #require(await tui.waitFor("MiMo Provider"))
    try #require(await tui.waitFor("Connection"))
    // Right/down/Enter selects Responses in MiMo's own page; Ctrl-S commits through Core.
    tui.write("\u{1B}[C\u{1B}[B\r")
    try #require(await waitUntil { tui.screenText.contains("Responses") })
    tui.write("\u{13}")
    try #require(await tui.waitFor("设置已保存"))
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    let savedSettings = try String(
        contentsOf: directory.appendingPathComponent("plugin-settings/site.lingxi.provider.mimo.json"),
        encoding: .utf8
    )
    #expect(savedSettings.contains("\"protocolKind\":\"responses\""))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { tui.isRunning == false })
    #expect(tui.status == 0, "transcript tail: \(tui.transcript.suffix(800))")
}

@Test("TUI-002 complete cell-bounded frames erase command remnants and support keyboard pickers", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_002_frameAndPickers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tui-frame-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    // Core boot includes the existing 30-second plugin handshake.
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })
    #expect(tui.screenText.contains("泠溪 · 2.0"))

    tui.write("/auth mimo")
    try #require(await waitUntil { tui.screenText.contains("/auth mimo") })
    tui.write("\r")
    try #require(await waitUntil { tui.screenText.contains("隐藏输入中") })
    #expect(!tui.screenText.contains("/auth mimo"))
    #expect(tui.screenText.contains("Keychain"))
    let sentinel = "hidden-input-frame-sentinel"
    tui.write(sentinel)
    try #require(await waitUntil { tui.screenText.contains("已输入 \(sentinel.count) 个字符") })
    #expect(!tui.transcript.contains(sentinel))
    for row in 1...30 { #expect(tui.latestFrame.contains("\u{1B}[\(row);1H")) }
    #expect(tui.latestFrame.components(separatedBy: "\u{1B}[2K").count == 31)
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("已取消凭据输入") })
    #expect(!tui.screenText.contains("隐藏输入中"))

    // The real cursor sits in the editor (for IME placement); a panel hides it.
    #expect(tui.latestFrame.hasSuffix("\u{1B}[?25h"))
    // Readline editing: Ctrl-W deletes a word, Ctrl-A goes to line start, SS3 arrows move.
    tui.write("alpha beta")
    try #require(await waitUntil { tui.screenText.contains("alpha beta") })
    tui.write("\u{17}")
    try #require(await waitUntil { tui.screenText.contains("alpha ") && !tui.screenText.contains("beta") })
    tui.write("\u{01}X\u{1B}OCY")
    try #require(await waitUntil { tui.screenText.contains("XaYlpha") })
    tui.write("\u{01}\u{0B}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    // Kitty keyboard reports (CSI u) and the backslash-Enter fallback both edit, never send.
    tui.write("one\\\rtwo\u{1B}[13;2uthree")
    try #require(await waitUntil { tui.screenText.contains("3 行") && tui.screenText.contains("three") })
    tui.write("\u{1B}[117;5u")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })

    tui.write("\u{10}切换模型\r")
    try #require(await waitUntil { tui.screenText.contains("mimo-v2.6-pro") && tui.screenText.contains("esc 关闭") })
    #expect(tui.latestFrame.hasSuffix("\u{1B}[?25l"))
    tui.write("\u{1B}[200~pro\r\u{1B}[201~")
    try #require(await waitUntil { tui.screenText.contains("› pro ") })
    #expect(tui.screenText.contains("esc 关闭"))
    tui.write("\u{1B}[B\r")
    try #require(await waitUntil { tui.screenText.contains("模型已切换为 mimo-v2.6-pro") })
    #expect(!tui.screenText.contains("esc 关闭"))

    tui.write(String(repeating: "中e\u{301}🙂", count: 100))
    try #require(await waitUntil { tui.screenText.contains("中e\u{301}🙂") })
    for line in tui.screenText.split(separator: "\n") {
        // This fixture uses ASCII, box drawing, CJK, combining accents and emoji.
        let cells = line.reduce(0) { $0 + ($1.unicodeScalars.contains { $0.value >= 0x2E80 } ? 2 : 1) }
        #expect(cells <= 120)
    }
    tui.write("\u{15}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    #expect(!tui.screenText.contains("中e\u{301}🙂"))
    tui.write("/quit\r")
    #expect(await waitUntil { !tui.isRunning })
    #expect(tui.status == 0)

    // A separate small PTY checks that row addressing never relies on an 80-column fallback.
    let narrow = try PTYProcess(environment: environment, columns: 40, rows: 12)
    defer { narrow.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { narrow.screenText.contains("mimo-v2.6-flash") })
    #expect(narrow.latestFrame.components(separatedBy: "\u{1B}[2K").count == 13)
    narrow.write("/quit\r")
    #expect(await waitUntil { !narrow.isRunning })
}

@Test("TUI-010 the footer shows live provider state, /reasoning switches thinking, /perf explains a run and the wheel scrolls", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_010_footerReasoningDiagnosticsAndWheel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tui-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory, turns: 3)
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    // A short terminal keeps the conversation scrollable with only a couple of turns.
    let tui = try PTYProcess(environment: environment, columns: 120, rows: 20)
    defer { tui.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })

    // Nothing has run yet, so there is nothing to diagnose; a wheel report without /mouse is ignored.
    tui.write("/perf\r")
    try #require(await tui.waitFor("还没有运行诊断"))
    tui.write(sgrWheel(up: true, row: 10, column: 10))
    try await Task.sleep(for: .milliseconds(300))
    #expect(!tui.screenText.contains("已向上滚动"))

    // The footer's protocol and thinking mode come from the Core's provider state, not from a guess.
    #expect(tui.screenText.contains("协议 "))

    let prompt = "诊断探针TUI010"
    tui.write(prompt + "\r")
    try #require(await waitUntil { tui.screenText.contains("pong") && !tui.screenText.contains("生成中") })

    // A compact, numbers-only diagnostic sits under the reply meta: upstream, thinking and local cost.
    try #require(await waitUntil { tui.screenText.contains("本地 ") && tui.screenText.contains("帧") })
    #expect(tui.screenText.contains("运行结束") == false)

    // /perf expands that into the full breakdown and never repeats the prompt or the reply text.
    tui.write("/perf\r")
    try #require(await tui.waitFor("性能诊断"))
    #expect(tui.screenText.contains("Core 准备"))
    #expect(tui.screenText.contains("运行总计"))
    #expect(tui.screenText.contains("TUI 渲染"))
    let rows = frameRows(tui.latestFrame)
    let perf = try #require(rows.firstIndex { $0.text.contains("性能诊断") })
    for row in rows[perf..<min(perf + 5, rows.count)] {
        #expect(!row.text.contains(prompt))
        #expect(!row.text.contains("pong"))
    }

    // /reasoning lists the current model's own declared levels plus "follow the plugin's settings".
    tui.write("/reasoning\r")
    try #require(await tui.waitFor("跟随插件设置"))
    #expect(tui.screenText.contains("思考模式"))
    tui.write("\u{1B}[B\r")
    try #require(await tui.waitFor("已临时切换思考模式"))
    try #require(await waitUntil { tui.screenText.contains("·临时") })
    tui.write("/reasoning follow\r")
    try #require(await tui.waitFor("已恢复跟随插件"))
    try #require(await waitUntil { !tui.screenText.contains("·临时") })

    // A second turn makes the conversation taller than the body, so the wheel has somewhere to go.
    // The earlier reply may already have scrolled out of a short terminal, so wait on the transcript.
    let mark = tui.transcript.count
    tui.write("继续\r")
    try #require(await tui.waitFor("pong", after: mark))
    try #require(await waitUntil { !tui.screenText.contains("生成中") })

    // With the conversation long enough to scroll, the wheel moves it and the status line reports it.
    tui.write("/mouse\r")
    try #require(await tui.waitFor("已开启鼠标"))
    tui.write(sgrWheel(up: true, row: 10, column: 10))
    try #require(await waitUntil { tui.screenText.contains("已向上滚动") })
    tui.write(String(repeating: sgrWheel(up: false, row: 10, column: 10), count: 40))
    try #require(await waitUntil { !tui.screenText.contains("已向上滚动") })

    // Mouse is additive: the keyboard still edits the draft with capture on.
    tui.write("abc")
    try #require(await waitUntil { tui.screenText.contains("abc") })
    tui.write("\u{15}")
    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)
}
