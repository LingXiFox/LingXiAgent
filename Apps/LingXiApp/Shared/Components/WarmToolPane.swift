#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import Darwin
import LingXiClient
import LingXiProtocol

struct WarmToolPane: View {
    let tool: WarmTool
    @ObservedObject var runtime: RuntimeFrontend
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: tool.symbol).foregroundStyle(.secondary)
                Text(tool.title).font(LXType.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                    .help("收起工具面板")
                    .accessibilityLabel("收起工具面板")
            }
            .padding(.horizontal, LingXiMetrics.Space.lg)
            .frame(height: LingXiMetrics.Size.toolbar)
            LXHairline()
            Group {
                switch tool {
                case .browser: WarmBrowserPane()
                case .git: WarmGitPane(runtime: runtime)
                case .terminal: WarmTerminalPane(runtime: runtime)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LXColor.content)
        .overlay(alignment: .leading) { Rectangle().fill(LXColor.separator).frame(width: 1) }
    }
}

struct WarmTasksPane: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var inspector: RuntimeInspectorPresentationModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @State private var goalDraft = ""
    @State private var tasks: [TaskSnapshot] = []
    @State private var taskError: String?

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        inspector = runtime.inspectorModel
        conversation = runtime.conversationModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("任务目标").font(.system(size: 12.5, weight: .semibold))
                    HStack {
                        TextField("为当前任务设定目标", text: $goalDraft)
                            .textFieldStyle(.plain)
                        Button("设定") { runtime.setGoal(goalDraft) }
                            .buttonStyle(.bordered)
                            .disabled(goalDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(9)
                    .background(LXColor.window, in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("任务胶囊").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Button { loadTasks() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                    }
                    Button("从目标创建任务") { createTask() }
                        .buttonStyle(.bordered)
                        .disabled(runtime.client == nil || runtime.sidebarModel.selectedSessionID == nil || goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let taskError {
                        Text(taskError).font(.system(size: 11.5)).foregroundStyle(LXColor.danger)
                    }
                    ForEach(tasks, id: \.capsule.taskID) { snapshot in
                        let capsule = snapshot.capsule
                        VStack(alignment: .leading, spacing: 7) {
                            Text(capsule.objective)
                                .font(.system(size: 12.5, weight: .medium))
                                .textSelection(.enabled)
                            Text(capsule.state.rawValue)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.secondary)
                            HStack {
                                if capsule.state == .running {
                                    Button("暂停") { taskAction { try await $0.pause(taskID: capsule.taskID) } }
                                }
                                if capsule.state == .paused || capsule.state == .waiting {
                                    Button("继续") { taskAction { try await $0.resume(taskID: capsule.taskID) } }
                                }
                                if !capsule.state.isTerminal {
                                    Button("取消") { taskAction { try await $0.cancel(taskID: capsule.taskID) } }
                                }
                                Button("分叉") { taskAction { try await $0.fork(sourceTaskID: capsule.taskID) } }
                            }
                            .font(.system(size: 11.5))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LXColor.window, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                if let task = conversation.activeTask {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前任务").font(.system(size: 12.5, weight: .semibold))
                        Text(task.objective).font(.system(size: 12.5)).textSelection(.enabled)
                        Text(task.state).font(.system(size: 11.5)).foregroundStyle(Color.secondary)
                        if let plan = task.plan {
                            ForEach(plan.phases) { phase in
                                Text(phase.name).font(.system(size: 11.5)).textSelection(.enabled)
                            }
                        }
                        if let report = task.report {
                            Text(report.summary).font(.system(size: 11.5)).textSelection(.enabled)
                        }
                    }
                }
                if let live = inspector.live {
                    if !live.todos.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("待办事项").font(.system(size: 12.5, weight: .semibold))
                            ForEach(live.todos, id: \.id) { todo in
                                HStack(spacing: 7) {
                                    Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(todo.status == "completed" ? LXColor.success : LXColor.warning)
                                    Text(todo.title).textSelection(.enabled)
                                }
                                .font(.system(size: 11.5))
                            }
                        }
                    }
                    if !live.workflows.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("工作流").font(.system(size: 12.5, weight: .semibold))
                            ForEach(live.workflows, id: \.id) { workflow in
                                Text("\(workflow.tasks.count) 步 · \(workflow.status.rawValue)")
                                    .font(.system(size: 11.5))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !live.backgroundTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("后台任务").font(.system(size: 12.5, weight: .semibold))
                            ForEach(live.backgroundTasks, id: \.id) { task in
                                HStack {
                                    Text(task.id).lineLimit(1)
                                    Spacer()
                                    Button("停止") { runtime.terminateBackgroundTask(id: task.id) }
                                }
                                .font(.system(size: 11.5))
                            }
                        }
                    }
                    if live.todos.isEmpty && live.workflows.isEmpty && live.backgroundTasks.isEmpty && conversation.activeTask == nil {
                        Text("当前没有活动任务。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    Text("打开工作区后查看任务。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .onAppear {
            goalDraft = runtime.composerModel.goal ?? ""
            loadTasks()
        }
    }

    private func loadTasks() {
        guard let client = runtime.client else { return }
        Task {
            do {
                tasks = try await client.task.list(sessionID: runtime.sidebarModel.selectedSessionID.map(SessionID.init))
                taskError = nil
            } catch {
                taskError = error.localizedDescription
            }
        }
    }

    private func createTask() {
        guard let client = runtime.client, let id = runtime.sidebarModel.selectedSessionID else { return }
        Task {
            do {
                _ = try await client.task.create(sessionID: SessionID(id), objective: goalDraft)
                loadTasks()
            } catch {
                taskError = error.localizedDescription
            }
        }
    }

    private func taskAction(_ action: @escaping (TaskDomainClient) async throws -> CommandReceipt<TaskSnapshot>) {
        guard let client = runtime.client else { return }
        Task {
            do {
                _ = try await action(client.task)
                loadTasks()
            } catch {
                taskError = error.localizedDescription
            }
        }
    }
}

@MainActor private final class WarmBrowserModel: ObservableObject {
    @Published var address = ""
    @Published var title = "浏览器"
    @Published var hasNavigated = false
    let webView = WKWebView()

    func navigate() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let value = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        address = value
        hasNavigated = true
        webView.load(URLRequest(url: url))
    }
}

private struct WarmBrowserView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WarmBrowserPane: View {
    @StateObject private var browser = WarmBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.webView.canGoBack)
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.webView.canGoForward)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("输入网址", text: $browser.address, onCommit: browser.navigate)
                    .textFieldStyle(.roundedBorder)
                    .font(LXType.body)
                Button { browser.navigate() } label: { Image(systemName: "arrow.right") }
            }
            .buttonStyle(.plain)
            .padding(LingXiMetrics.Space.sm)
            if browser.hasNavigated {
                WarmBrowserView(webView: browser.webView)
            } else {
                VStack(spacing: LingXiMetrics.Space.sm) {
                    Image(systemName: "safari").font(.system(size: LXIcon.emptyState))
                    Text("输入网址开始浏览").font(LXType.body)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text("用户浏览器 · 独立会话").foregroundStyle(.secondary)
                Spacer()
            }
            .font(LXType.meta)
            .padding(.horizontal, LingXiMetrics.Space.md)
            .frame(height: LingXiMetrics.Size.rowList)
            .overlay(alignment: .top) { LXHairline() }
        }
    }
}

@MainActor final class WarmGitModel: ObservableObject {
    @Published var status = ""
    @Published var diff = ""
    @Published var stats = ""
    @Published var fileStats: [String: String] = [:]
    @Published var log = ""
    @Published var branch = ""
    @Published var aheadBehind: String?
    @Published var error: String?
    @Published var isBusy = false

    func refresh(at workspace: URL?) {
        guard let workspace else { return }
        isBusy = true
        Task {
            let path = workspace.path
            let statusResult = await Task.detached { Self.run(["-C", path, "status", "--short", "--branch"]) }.value
            let diffResult = await Task.detached { Self.run(["-C", path, "diff", "HEAD", "--no-ext-diff"]) }.value
            let statsResult = await Task.detached { Self.run(["-C", path, "diff", "--stat", "HEAD", "--no-ext-diff"]) }.value
            let numstatResult = await Task.detached { Self.run(["-C", path, "diff", "--numstat", "HEAD", "--no-ext-diff"]) }.value
            let logResult = await Task.detached { Self.run(["-C", path, "log", "-8", "--oneline", "--decorate"]) }.value
            let trackingResult = await Task.detached { Self.run(["-C", path, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) }.value
            status = statusResult.output
            diff = diffResult.output
            stats = statsResult.output
            fileStats = Dictionary(uniqueKeysWithValues: numstatResult.output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                return (String(parts[2]), "+\(parts[0]) −\(parts[1])")
            })
            log = logResult.output
            branch = String((statusResult.output.components(separatedBy: "\n").first ?? "").dropFirst(3))
            if trackingResult.code == 0 {
                let counts = trackingResult.output.split(whereSeparator: \.isWhitespace)
                aheadBehind = counts.count == 2 ? "↑\(counts[0]) ↓\(counts[1])" : nil
            } else {
                aheadBehind = nil
            }
            error = statusResult.code == 0 ? nil : statusResult.output
            isBusy = false
        }
    }

    func action(_ args: [String], at workspace: URL?, onSuccess: (() -> Void)? = nil) {
        guard let workspace else { return }
        isBusy = true
        Task {
            let result = await Task.detached { Self.run(["-C", workspace.path] + args) }.value
            error = result.code == 0 ? nil : result.output
            if result.code == 0 { onSuccess?() }
            refresh(at: workspace)
        }
    }

    nonisolated static func run(_ args: [String]) -> (output: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), process.terminationStatus)
        } catch {
            return (error.localizedDescription, -1)
        }
    }
}

private struct WarmGitPane: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var conversation: ConversationPresentationModel
    @StateObject private var git = WarmGitModel()
    @State private var message = ""
    @State private var showsDiff = false
    @State private var waitingForAgentReply = false
    @State private var replyStartCount = 0

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.conversation = runtime.conversationModel
    }
    private var workspace: URL? { runtime.workspaceURL }
    private var changedFiles: [(code: String, path: String)] {
        git.status.split(separator: "\n").dropFirst().compactMap { line in
            guard line.count >= 4 else { return nil }
            return (String(line.prefix(2)), String(line.dropFirst(3)))
        }
    }
    private var staged: [(code: String, path: String)] {
        changedFiles.filter { $0.code.first != " " && $0.code != "??" }
    }
    private var unstaged: [(code: String, path: String)] {
        changedFiles.filter { $0.code.last != " " || $0.code == "??" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            HStack {
                Text(git.branch.isEmpty ? "工作区变更" : git.branch)
                    .font(LXType.callout)
                    .lineLimit(1)
                if let tracking = git.aheadBehind {
                    Text(tracking).font(LXType.meta).foregroundStyle(.secondary)
                }
                Spacer()
                Button { git.refresh(at: workspace) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            HStack(spacing: LingXiMetrics.Space.md) {
                Text("\(staged.count) 已暂存")
                Text("\(unstaged.count) 未暂存")
                if git.isBusy { ProgressView().controlSize(.small) }
            }
            .font(LXType.meta)
            .foregroundStyle(.secondary)
            HStack(spacing: LingXiMetrics.Space.sm) {
                TextField("提交信息", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .font(LXType.body)
                Button("提交 \(staged.count) 个文件") {
                    git.action(["commit", "-m", message], at: workspace) { message = "" }
                }
                .buttonStyle(.lxPrimary)
                .disabled(staged.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(waitingForAgentReply ? "Agent 正在拟写…" : "让 Agent 写提交信息") {
                replyStartCount = conversation.items.count
                waitingForAgentReply = true
                runtime.sendMessage(text: "请根据当前已暂存的改动拟写一条英文 Git commit subject。只回复这一行，不执行提交。")
            }
            .buttonStyle(.plain)
            .font(LXType.body)
            .foregroundStyle(LXColor.accentText)
            .disabled(staged.isEmpty || waitingForAgentReply || conversation.isGenerating)
            ScrollView {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
                    fileSection("已暂存", files: staged)
                    fileSection("未暂存", files: unstaged)
                    if changedFiles.isEmpty {
                        Text("工作区没有未提交改动").font(LXType.meta).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("暂存全部") { git.action(["add", "-A"], at: workspace) }
                        Button("取消暂存") { git.action(["restore", "--staged", "."], at: workspace) }
                    }
                    .font(LXType.body)
                    Button(showsDiff ? "收起差异" : "查看差异") { showsDiff.toggle() }
                        .buttonStyle(.plain)
                        .font(LXType.body)
                    if showsDiff {
                        Text(git.diff.isEmpty ? "没有可显示的差异" : git.diff)
                            .font(LXType.monoSmall)
                            .textSelection(.enabled)
                    }
                    LXHairline()
                    Text("最近提交").font(LXType.sectionHead).foregroundStyle(.secondary)
                    Text(git.log.isEmpty ? "暂无提交" : git.log)
                        .font(LXType.monoSmall)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = git.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(LXColor.danger)
            }
            HStack {
                Button("获取") { git.action(["fetch"], at: workspace) }
                Button("拉取") { git.action(["pull", "--ff-only"], at: workspace) }
                Button("推送") { git.action(["push"], at: workspace) }
            }
            .font(LXType.body)
            .disabled(git.isBusy || workspace == nil)
        }
        .padding(15)
        .onAppear { git.refresh(at: workspace) }
        .onChange(of: workspace) { _, new in git.refresh(at: new) }
        .onChange(of: conversation.items) { _, items in
            guard waitingForAgentReply, items.count > replyStartCount else { return }
            guard let reply = items.dropFirst(replyStartCount).compactMap({ item -> String? in
                if case .assistant(let content, let streaming) = item.kind, !streaming { return content }
                return nil
            }).last else { return }
            let subject = reply.split(separator: "\n").map(String.init)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let subject { message = subject.trimmingCharacters(in: .whitespacesAndNewlines) }
            waitingForAgentReply = false
        }
    }

    private func fileSection(_ title: String, files: [(code: String, path: String)]) -> some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Text("\(title) · \(files.count)").font(LXType.sectionHead).foregroundStyle(.secondary)
            ForEach(files.indices, id: \.self) { index in
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(files[index].code)
                        .font(LXType.monoSmall)
                        .foregroundStyle(.secondary)
                    Text(files[index].path)
                        .font(LXType.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let counts = git.fileStats[files[index].path] {
                        Text(counts).font(LXType.meta.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: LingXiMetrics.Size.rowList)
            }
        }
    }
}

@MainActor private final class WarmTerminalModel: ObservableObject {
    @Published var output = ""
    @Published var command = ""
    @Published var isRunning = false
    @Published var error: String?
    private var process: Process?
    private var master: FileHandle?

    func start(at workspace: URL?) {
        guard !isRunning, let workspace else { return }
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            error = "无法创建 PTY"
            return
        }
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-s", "+i"]
        process.currentDirectoryURL = workspace
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "dumb", "NO_COLOR": "1"]) { _, new in new }
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        do {
            try process.run()
            self.process = process
            self.master = master
            isRunning = true
            output = ""
            master.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    let plain = text
                        .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\r", with: "")
                    self?.output += plain
                    if (self?.output.count ?? 0) > 120_000 { self?.output.removeFirst(20_000) }
                }
            }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in self?.isRunning = false }
            }
        } catch {
            self.error = error.localizedDescription
            master.closeFile()
            slave.closeFile()
        }
    }

    func send() {
        guard let master, isRunning else { return }
        let value = command + "\n"
        command = ""
        master.write(Data(value.utf8))
    }

    func interrupt() { master?.write(Data([3])) }

    func stop() {
        master?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        master?.closeFile()
        master = nil
        process = nil
        isRunning = false
    }
}

private struct WarmTerminalPane: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var conversation: ConversationPresentationModel
    @StateObject private var terminal = WarmTerminalModel()
    @State private var selectedTab = 0

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.conversation = runtime.conversationModel
    }

    private var workspace: URL? { runtime.workspaceURL }
    private var agentCommands: [ToolCallPresentation] {
        conversation.items.compactMap {
            guard case .tool(let call) = $0.kind,
                  ["shell", "terminal", "exec", "command", "bash", "zsh"].contains(where: {
                      call.toolName.localizedCaseInsensitiveContains($0)
                  }) else { return nil }
            return call
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("终端会话", selection: $selectedTab) {
                Text("用户 Shell").tag(0)
                Text("Agent 运行记录").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(LingXiMetrics.Space.sm)
            if selectedTab == 0 {
            HStack {
                Text(workspace?.path ?? "未打开工作区")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("中断") { terminal.interrupt() }.disabled(!terminal.isRunning)
                Button(terminal.isRunning ? "结束" : "启动") {
                    if terminal.isRunning { terminal.stop() } else { terminal.start(at: workspace) }
                }
                .disabled(workspace == nil)
            }
            .font(.system(size: 11.5))
            .padding(10)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.output.isEmpty ? "终端已就绪" : terminal.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(terminal.output.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("tail")
                        .padding(12)
                }
                .background(LXColor.window)
                .onChange(of: terminal.output.count) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            }
            if let error = terminal.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(LXColor.danger)
            }
            HStack {
                TextField("输入命令并回车", text: $terminal.command, onCommit: terminal.send)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                Button { terminal.send() } label: { Image(systemName: "arrow.up") }
                    .disabled(!terminal.isRunning || terminal.command.isEmpty)
            }
            .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.lg) {
                        ForEach(agentCommands, id: \.callID) { call in
                            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                                HStack {
                                    Text(call.summary).font(LXType.monoSmall).lineLimit(2)
                                    Spacer()
                                    Text(call.status).font(LXType.meta).foregroundStyle(.secondary)
                                }
                                if let output = call.output, !output.isEmpty {
                                    Text(output).font(LXType.monoSmall).textSelection(.enabled)
                                }
                                if let stderr = call.stderr, !stderr.isEmpty {
                                    Text(stderr).font(LXType.monoSmall).foregroundStyle(LXColor.danger)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if agentCommands.isEmpty {
                            Text("当前会话还没有 Agent 终端运行记录")
                                .font(LXType.meta).foregroundStyle(.secondary)
                        }
                    }
                    .padding(LingXiMetrics.Space.md)
                }
            }
        }
        .onAppear { terminal.start(at: workspace) }
        .onDisappear { terminal.stop() }
    }
}
#endif
