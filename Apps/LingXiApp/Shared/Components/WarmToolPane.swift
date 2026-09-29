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

    /// size-tool-panel: a bg-content floating panel (radius-panel, 1px ring)
    /// with a title row — icon, name, close. Never an overlay drawer.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: tool.symbol)
                    .font(.system(size: LXIcon.row))
                    .foregroundStyle(.secondary)
                Text(tool.title).font(LXType.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                    .help("收起\(tool.title)面板")
                    .accessibilityLabel("收起\(tool.title)面板")
            }
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .frame(height: LingXiMetrics.Size.sidebarHead)
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
        .lxPanel(LXColor.content)
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    Text("任务目标").font(LXType.sectionHead)
                    HStack {
                        TextField("为当前任务设定目标", text: $goalDraft)
                            .textFieldStyle(.plain)
                        Button("设定") { runtime.setGoal(goalDraft) }
                            .buttonStyle(LXButtonStyle(.secondary, size: .small))
                            .disabled(goalDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(LingXiMetrics.Space.sm)
                    .background(LXColor.fillQuinary, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
                }
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    HStack {
                        Text("任务胶囊").font(LXType.sectionHead)
                        Spacer()
                        Button { loadTasks() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                    }
                    Button("从目标创建任务") { createTask() }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                        .disabled(runtime.client == nil || runtime.sidebarModel.selectedSessionID == nil || goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let taskError {
                        Text(taskError).font(LXType.meta).foregroundStyle(LXColor.danger)
                    }
                    ForEach(tasks, id: \.capsule.taskID) { snapshot in
                        let capsule = snapshot.capsule
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                            Text(capsule.objective)
                                .font(LXType.body.weight(.medium))
                                .textSelection(.enabled)
                            Text(capsule.state.rawValue)
                                .font(LXType.meta)
                                .foregroundStyle(Color.secondary)
                            HStack {
                                if capsule.state == .running {
                                    Button("标记暂停") { taskAction { try await $0.pause(taskID: capsule.taskID) } }
                                }
                                if capsule.state == .paused || capsule.state == .waiting {
                                    Button("标记继续") { taskAction { try await $0.resume(taskID: capsule.taskID) } }
                                }
                                if !capsule.state.isTerminal {
                                    Button("标记取消") { taskAction { try await $0.cancel(taskID: capsule.taskID) } }
                                }
                                Button("复制胶囊") { taskAction { try await $0.fork(sourceTaskID: capsule.taskID) } }
                            }
                            .font(LXType.meta)
                        }
                        .padding(LingXiMetrics.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LXColor.fillQuinary, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
                    }
                    Text("这些操作只更新任务记录；停止正在运行的 Agent 请使用输入框的停止按钮。")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
                if let task = conversation.activeTask {
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                        Text("最近的任务胶囊").font(LXType.sectionHead)
                        Text(task.objective).font(LXType.body).textSelection(.enabled)
                        Text(task.state).font(LXType.meta).foregroundStyle(Color.secondary)
                        if let plan = task.plan {
                            ForEach(plan.phases) { phase in
                                Text(phase.name).font(LXType.meta).textSelection(.enabled)
                            }
                        }
                        if let report = task.report {
                            Text(report.summary).font(LXType.meta).textSelection(.enabled)
                        }
                    }
                }
                if let live = inspector.live {
                    if !live.todos.isEmpty {
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                            Text("待办事项").font(LXType.sectionHead)
                            ForEach(live.todos, id: \.id) { todo in
                                HStack(spacing: LingXiMetrics.Space.sm) {
                                    Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(todo.status == "completed" ? LXColor.success : LXColor.warning)
                                    Text(todo.title).textSelection(.enabled)
                                }
                                .font(LXType.meta)
                            }
                        }
                    }
                    if !live.workflows.isEmpty {
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                            Text("工作流").font(LXType.sectionHead)
                            ForEach(live.workflows, id: \.id) { workflow in
                                Text("\(workflow.tasks.count) 步 · \(workflow.status.rawValue)")
                                    .font(LXType.meta)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !live.backgroundTasks.isEmpty {
                        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                            Text("后台任务").font(LXType.sectionHead)
                            ForEach(live.backgroundTasks, id: \.id) { task in
                                HStack {
                                    Text(task.id).lineLimit(1)
                                    Spacer()
                                    Button("停止") { runtime.terminateBackgroundTask(id: task.id) }
                                }
                                .font(LXType.meta)
                            }
                        }
                    }
                    if live.todos.isEmpty && live.workflows.isEmpty && live.backgroundTasks.isEmpty && conversation.activeTask == nil {
                        Text("当前没有活动任务。")
                            .font(LXType.body)
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    Text("打开工作区后查看任务。")
                        .font(LXType.body)
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LingXiMetrics.Space.lg)
        }
        .task(id: runtime.sidebarModel.selectedSessionID) {
            goalDraft = runtime.composerModel.goal ?? ""
            loadTasks()
        }
    }

    private func loadTasks() {
        guard runtime.client != nil else { tasks = []; return }
        let sessionID = runtime.sidebarModel.selectedSessionID
        Task {
            do {
                let result = try await runtime.refreshTasks()
                guard runtime.sidebarModel.selectedSessionID == sessionID else { return }
                tasks = result
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
            HStack(spacing: LingXiMetrics.Space.sm) {
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
                    Image(systemName: "globe").font(.system(size: LXIcon.emptyState))
                    Text("输入网址开始浏览。").font(LXType.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text("独立浏览会话 · 尚未连接 Agent 的浏览器会话").foregroundStyle(.secondary)
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
    @Published var fileStats: [String: (additions: Int, deletions: Int)] = [:]
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
            let statusResult = await Task.detached { Self.run(["-C", path, "status", "--short", "--branch", "--untracked-files=all"]) }.value
            let diffResult = await Task.detached { Self.run(["-C", path, "diff", "HEAD", "--no-ext-diff"]) }.value
            let numstatResult = await Task.detached { Self.run(["-C", path, "diff", "--numstat", "HEAD", "--no-ext-diff"]) }.value
            let untracked = await Task.detached { Self.untrackedDiffs(at: path) }.value
            let logResult = await Task.detached { Self.run(["-C", path, "log", "-8", "--format=%h%x09%s"]) }.value
            let trackingResult = await Task.detached { Self.run(["-C", path, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) }.value
            status = statusResult.output
            diff = [diffResult.output, untracked.patches].filter { !$0.isEmpty }.joined(separator: "\n")
            var counts: [String: (additions: Int, deletions: Int)] = Dictionary(uniqueKeysWithValues: numstatResult.output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let add = Int(parts[0]), let del = Int(parts[1]) else { return nil }
                return (String(parts[2]), (add, del))
            })
            counts.merge(untracked.counts) { _, latest in latest }
            fileStats = counts
            log = logResult.output
            // "## main...origin/main [ahead 1]" → "main"
            let head = String((statusResult.output.components(separatedBy: "\n").first ?? "").dropFirst(3))
            branch = head.components(separatedBy: "...").first?.components(separatedBy: " ").first ?? head
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

    nonisolated static func untrackedDiffs(at workspace: String) ->
        (patches: String, counts: [String: (additions: Int, deletions: Int)]) {
        // ponytail: One Git process per untracked file; batch only if large workspaces make refresh slow.
        let files = run(["-C", workspace, "ls-files", "--others", "--exclude-standard", "-z"])
        guard files.code == 0 else { return ("", [:]) }
        var patches: [String] = []
        var counts: [String: (additions: Int, deletions: Int)] = [:]
        for file in files.output.split(separator: "\0") {
            let path = String(file)
            let patch = run(["-C", workspace, "diff", "--no-index", "--", "/dev/null", path])
            if patch.code == 1 { patches.append(patch.output) }
            let stat = run(["-C", workspace, "diff", "--no-index", "--numstat", "--", "/dev/null", path])
            let parts = stat.output.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, let add = Int(parts[0]), let del = Int(parts[1]) {
                counts[path] = (add, del)
            }
        }
        return (patches.joined(separator: "\n"), counts)
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

    private var commits: [(hash: String, subject: String)] {
        git.log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Branch + ahead/behind, remote actions behind one menu.
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: LXIcon.small))
                Text(git.branch.isEmpty ? "工作区变更" : git.branch).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: LingXiMetrics.Space.sm)
                if git.isBusy { ProgressView().controlSize(.mini) }
                if let tracking = git.aheadBehind { Text(tracking).monospacedDigit() }
                Menu {
                    Button("刷新") { git.refresh(at: workspace) }
                    Divider()
                    Button("暂存全部") { git.action(["add", "-A"], at: workspace) }
                    Button("取消暂存全部") { git.action(["restore", "--staged", "."], at: workspace) }
                    Divider()
                    Button("获取") { git.action(["fetch"], at: workspace) }
                    Button("拉取") { git.action(["pull", "--ff-only"], at: workspace) }
                    Button("推送") { git.action(["push"], at: workspace) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: LXIcon.status))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(git.isBusy || workspace == nil)
                .accessibilityLabel("Git 操作")
            }
            .font(LXType.meta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .padding(.top, LingXiMetrics.Space.md)

            VStack(alignment: .trailing, spacing: LingXiMetrics.Space.sm) {
                TextField("提交信息", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(LXType.body)
                    .lineLimit(2...5)
                    .padding(LingXiMetrics.Space.sm)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                    .background(LXColor.content,
                                in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous))
                    .lxRing(cornerRadius: LingXiMetrics.Radius.control)
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Button(waitingForAgentReply ? "Agent 正在拟写…" : "让 Agent 写提交信息") {
                        replyStartCount = conversation.items.count
                        waitingForAgentReply = true
                        runtime.sendMessage(text: "请根据当前已暂存的改动拟写一条英文 Git commit subject。只回复这一行，不执行提交。")
                    }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    .disabled(staged.isEmpty || waitingForAgentReply || conversation.isGenerating)
                    Button("提交 \(staged.count) 个文件") {
                        git.action(["commit", "-m", message], at: workspace) { message = "" }
                    }
                    .buttonStyle(LXButtonStyle(.primary, size: .small))
                    .disabled(staged.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(LingXiMetrics.Space.panelInset)

            if let error = git.error {
                LXStatusText(error.trimmingCharacters(in: .whitespacesAndNewlines),
                             systemImage: "exclamationmark.triangle", tone: .danger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, LingXiMetrics.Space.panelInset)
                    .padding(.bottom, LingXiMetrics.Space.sm)
            }
            LXHairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if changedFiles.isEmpty {
                        PlaceholderLine("工作区没有未提交改动。")
                            .padding(.vertical, LingXiMetrics.Space.md)
                    } else {
                        fileSection("已暂存", files: staged)
                        fileSection("未暂存", files: unstaged)
                    }
                    LXSection("最近提交", separated: !changedFiles.isEmpty) {
                        if commits.isEmpty {
                            PlaceholderLine("还没有提交。")
                        }
                        ForEach(commits, id: \.hash) { commit in
                            HStack(spacing: LingXiMetrics.Space.sm) {
                                Text(commit.hash).font(LXType.monoSmall).foregroundStyle(.secondary)
                                Text(commit.subject).font(LXType.body).lineLimit(1)
                            }
                            .frame(minHeight: 26)
                        }
                    }
                    if showsDiff {
                        LXSection("差异") {
                            OutputBlock(text: git.diff.isEmpty ? "没有可显示的差异" : git.diff, isDiff: !git.diff.isEmpty)
                        }
                    }
                    Button(showsDiff ? "收起差异" : "查看差异") { showsDiff.toggle() }
                        .buttonStyle(LXButtonStyle(.plain, size: .small))
                        .padding(.vertical, LingXiMetrics.Space.sm)
                        .disabled(changedFiles.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LingXiMetrics.Space.panelInset)
            }
        }
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

    /// Status letter · mono path · `+a −d` counts. No per-type colours.
    private func fileSection(_ title: String, files: [(code: String, path: String)]) -> some View {
        LXSection(title, separated: title != "已暂存") {
            Text("\(files.count)")
        } content: {
            if files.isEmpty {
                PlaceholderLine(title == "已暂存" ? "还没有暂存的文件。" : "没有未暂存的改动。")
            }
            ForEach(files.indices, id: \.self) { index in
                let file = files[index]
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(file.code.trimmingCharacters(in: .whitespaces) == "??" ? "?" :
                            String(title == "已暂存" ? file.code.prefix(1) : file.code.suffix(1)))
                        .font(LXType.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    Text(file.path)
                        .font(LXType.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: LingXiMetrics.Space.sm)
                    if let counts = git.fileStats[file.path] {
                        LXDiffCount(additions: counts.additions, deletions: counts.deletions)
                            .font(LXType.meta)
                    }
                }
                .frame(minHeight: 26)
                .help(file.path)
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

    private var agentRunning: Bool {
        agentCommands.contains { EventStatus($0.status) == .running }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session tabs: the agent's command record and the user's own shell.
            HStack(spacing: LingXiMetrics.Space.xs) {
                sessionTab(1, title: agentCommands.last.map { "Agent · \($0.summary)" } ?? "Agent", running: agentRunning)
                sessionTab(0, title: "zsh", running: false)
                Spacer(minLength: 0)
                if selectedTab == 0 {
                    Button { terminal.interrupt() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                        .disabled(!terminal.isRunning)
                        .help("中断 (⌃C)")
                        .accessibilityLabel("中断")
                    Button {
                        if terminal.isRunning { terminal.stop() } else { terminal.start(at: workspace) }
                    } label: { Image(systemName: terminal.isRunning ? "xmark.circle" : "play.circle") }
                        .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                        .disabled(workspace == nil)
                        .help(terminal.isRunning ? "结束 shell" : "启动 shell")
                        .accessibilityLabel(terminal.isRunning ? "结束 shell" : "启动 shell")
                }
            }
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .padding(.vertical, 6)
            LXHairline()

            if selectedTab == 0 {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(terminal.output.isEmpty ? "终端已就绪" : terminal.output)
                            .font(LXType.monoSmall)
                            .lineSpacing(3)
                            .foregroundStyle(terminal.output.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(LingXiMetrics.Space.md)
                            .id("tail")
                    }
                    .onChange(of: terminal.output.count) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                }
                if let error = terminal.error {
                    LXStatusText(error, systemImage: "exclamationmark.triangle", tone: .danger)
                        .padding(.horizontal, LingXiMetrics.Space.md)
                }
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text("$").font(LXType.monoSmall).foregroundStyle(.secondary)
                    TextField("输入命令并回车", text: $terminal.command, onCommit: terminal.send)
                        .textFieldStyle(.plain)
                        .font(LXType.monoSmall)
                        .disabled(!terminal.isRunning)
                }
                .padding(.horizontal, LingXiMetrics.Space.md)
                .frame(height: LingXiMetrics.Size.rowList)
                .overlay(alignment: .top) { LXHairline() }
                footer(workspace.map { "你的 shell · \($0.lastPathComponent)" } ?? "未打开工作区")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
                        ForEach(agentCommands, id: \.callID) { call in
                            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                                HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
                                    Text("$ \(call.summary)").font(LXType.monoSmall).lineLimit(2)
                                    Spacer(minLength: LingXiMetrics.Space.sm)
                                    EventStatusGlyph(status: EventStatus(call.status))
                                }
                                if let output = call.output, !output.isEmpty {
                                    Text(output).font(LXType.monoSmall).lineSpacing(3).textSelection(.enabled)
                                }
                                if let stderr = call.stderr, !stderr.isEmpty {
                                    Text(stderr).font(LXType.monoSmall).lineSpacing(3)
                                        .foregroundStyle(LXColor.danger)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if agentCommands.isEmpty {
                            PlaceholderLine("本会话还没有 Agent 执行过终端命令。")
                        }
                    }
                    .padding(LingXiMetrics.Space.md)
                }
                footer(agentRunning ? "Agent 正在使用终端 · 输出实时更新" : "Agent 的命令记录 · 只读")
            }
        }
        .onAppear {
            selectedTab = agentCommands.isEmpty ? 0 : 1
            terminal.start(at: workspace)
        }
        .onDisappear { terminal.stop() }
    }

    /// 24pt tab: fill-control when selected; the agent tab carries the 6pt
    /// running dot while it executes.
    private func sessionTab(_ tag: Int, title: String, running: Bool) -> some View {
        Button { selectedTab = tag } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                if running {
                    Circle().fill(LXColor.running).frame(width: LXControl.dot, height: LXControl.dot)
                        .accessibilityLabel("执行中")
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .font(LXType.meta)
            .foregroundStyle(selectedTab == tag ? .primary : .secondary)
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(minHeight: LXControl.tab)
            .fixedSize()
            .background(selectedTab == tag ? LXColor.fillControl : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tag ? [.isButton, .isSelected] : .isButton)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(LXType.meta)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.md)
            .frame(height: LingXiMetrics.Size.rowList)
            .overlay(alignment: .top) { LXHairline() }
    }
}
#endif
