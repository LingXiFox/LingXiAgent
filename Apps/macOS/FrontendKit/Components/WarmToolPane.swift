#if os(macOS)
import AppKit
import SwiftUI
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
                case .browser: WarmBrowserPane(runtime: runtime)
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
    /// Artifacts and report are read from Core on demand; they are not part of the capsule the
    /// list already carries, and caching them here would show a stale view of a finished task.
    @State private var artifacts: [TaskArtifact] = []
    @State private var loadedReport: TaskReport?

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
                    // §7: the capsule alone left four Core task RPCs unreachable from the GUI.
                    // Objective, criteria, state, plan, artifacts and report are all shown from
                    // Core's data, and every action below is command → receipt → reload; none of
                    // them edit `conversation.activeTask` locally.
                    VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                        Text("任务详情").font(LXType.sectionHead)
                        Text(task.objective).font(LXType.body).textSelection(.enabled)
                        Text(task.state).font(LXType.meta).foregroundStyle(Color.secondary)

                        if !task.criteria.isEmpty {
                            Text("验收标准").font(LXType.meta).foregroundStyle(.secondary)
                            ForEach(task.criteria, id: \.criterionID) { criterion in
                                HStack(alignment: .top, spacing: LingXiMetrics.Space.xs) {
                                    Image(systemName: criterion.isSatisfied
                                                  ? "checkmark.circle" : "circle.dashed")
                                        .foregroundStyle(criterion.isSatisfied ? Color.green : Color.secondary)
                                    Text(criterion.description).font(LXType.meta).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }

                        if let plan = task.plan {
                            Text("阶段").font(LXType.meta).foregroundStyle(.secondary)
                            ForEach(plan.phases) { phase in
                                Text(phase.name).font(LXType.meta).textSelection(.enabled)
                            }
                        }

                        Text("产物").font(LXType.meta).foregroundStyle(.secondary)
                        if artifacts.isEmpty {
                            Text("该任务目前没有登记产物。").font(LXType.meta).foregroundStyle(.secondary)
                        } else {
                            ForEach(artifacts, id: \.ordinal) { artifact in
                                HStack(spacing: LingXiMetrics.Space.xs) {
                                    Image(systemName: "doc.badge.ellipsis")
                                    // `kind` is the label and `ref` addresses the content; there is
                                    // no filename on an artifact, so the ref tail is shown rather
                                    // than invented.
                                    Text(artifact.kind).font(LXType.meta)
                                    Text(String(artifact.ref.prefix(10)))
                                        .font(LXType.meta).foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                    Text("v\(artifact.version)").font(LXType.meta).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }

                        if let report = loadedReport {
                            Text("报告").font(LXType.meta).foregroundStyle(.secondary)
                            Text(report.summary).font(LXType.meta).textSelection(.enabled)
                        }

                        HStack(spacing: LingXiMetrics.Space.sm) {
                            // Only actions Core actually supports are offered; nothing here is a
                            // button that changes a local field and calls it done.
                            if !terminalTaskStates.contains(task.state) {
                                // Core maps finalize to exactly one of two transitions — discard
                                // cancels, anything else completes — so `accept` and `finish` are
                                // not different outcomes and are not offered as two buttons.
                                Button("标记完成") {
                                    taskAction { try await $0.finalize(taskID: TaskID(task.taskID),
                                                                       action: .finish) }
                                }
                                Button("放弃任务") {
                                    taskAction { try await $0.finalize(taskID: TaskID(task.taskID),
                                                                       action: .discard) }
                                }
                            }
                            Button("重新读取") { Task { await loadTaskSurface(taskID: task.taskID) } }
                        }
                        .font(LXType.meta)
                    }
                    .task(id: task.taskID) { await loadTaskSurface(taskID: task.taskID) }
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

    /// `TaskPresentation.state` is the display string the capsule was projected into, so
    /// finalizability is judged on that rather than reaching back for the enum.
    private var terminalTaskStates: Set<String> { ["completed", "failed", "cancelled", "discarded"] }

    private func loadTaskSurface(taskID: String) async {
        guard let client = runtime.client else { return }
        let id = TaskID(taskID)
        do {
            artifacts = try await client.task.listArtifacts(taskID: id)
        } catch {
            artifacts = []
            taskError = "读取任务产物失败：\(error.localizedDescription)"
        }
        do {
            loadedReport = try await client.task.getReport(taskID: id)
        } catch {
            loadedReport = nil
            taskError = "读取任务报告失败：\(error.localizedDescription)"
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

/// Agent Browser Monitor.
///
/// This panel does not browse. It shows the browser sessions the *Agent* owns, read back from
/// Core over `browser.sessions` / `browser.capture`. An earlier version carried its own
/// `WKWebView` with an address bar, so the product had two browser states: the one the Agent
/// was driving and an unrelated one in the sidebar that looked like the agent's page. A
/// right-hand surface that disagrees with the runtime is worse than an empty one (§4.1).
@MainActor final class WarmBrowserModel: ObservableObject {
    @Published var sessions: [BrowserSessionStatus] = []
    @Published var selectedID: String?
    @Published var capture: BrowserCapture?
    @Published var error: String?
    @Published var isLoading = false

    var selected: BrowserSessionStatus? {
        sessions.first { $0.sessionID == selectedID } ?? sessions.first
    }

    func refresh(client: LingXiClientVNext?) async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await client.browser.sessions()
            sessions = found
            if selectedID == nil { selectedID = found.first?.sessionID }
            if let keep = selectedID, !found.contains(where: { $0.sessionID == keep }) {
                selectedID = found.first?.sessionID
                capture = nil
            }
            error = nil
        } catch {
            // A failed read is reported, not shown as "no sessions" — those mean different things.
            self.error = error.localizedDescription
        }
    }

    func loadCapture(client: LingXiClientVNext?, for sessionID: String) async {
        guard let client else { return }
        do {
            capture = try await client.browser.capture(sessionID: sessionID)
            error = nil
        } catch {
            capture = nil
            self.error = "读取最新页面截图失败：\(error.localizedDescription)"
        }
    }
}

private struct WarmBrowserPane: View {
    @ObservedObject var runtime: RuntimeFrontend
    @StateObject private var browser = WarmBrowserModel()

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Text("Agent 浏览器会话").font(LXType.headline)
                if !browser.sessions.isEmpty {
                    Text("\(browser.sessions.count)").font(LXType.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                Button {
                    Task {
                        await browser.refresh(client: runtime.client)
                        if let id = browser.selected?.sessionID {
                            await browser.loadCapture(client: runtime.client, for: id)
                        }
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(browser.isLoading || runtime.client == nil)
            }
            .padding(LingXiMetrics.Space.sm)
            .overlay(alignment: .bottom) { LXHairline() }

            if let error = browser.error {
                HStack(alignment: .top, spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                }
                .font(LXType.callout)
                .foregroundStyle(.red)
                .padding(LingXiMetrics.Space.sm)
                .overlay(alignment: .bottom) { LXHairline() }
            }

            if runtime.client == nil {
                emptyState("未连接 Core", "连接后这里显示 Agent 正在驱动的浏览器会话。")
            } else if browser.sessions.isEmpty {
                emptyState("没有 Agent 浏览器会话",
                           browser.isLoading ? "正在向 Core 查询…" : "Agent 调用 browser_navigate 之后，会话会出现在这里。")
            } else {
                sessionList
            }
        }
        .onAppear { Task { await browser.refresh(client: runtime.client) } }
        // A run is what creates and moves browser sessions, so the monitor follows it instead
        // of requiring the user to poll by hand. It stops the moment the run does.
        .task(id: runtime.conversationModel.isGenerating) {
            guard runtime.conversationModel.isGenerating else { return }
            while !Task.isCancelled, runtime.conversationModel.isGenerating {
                await browser.refresh(client: runtime.client)
                if let id = browser.selected?.sessionID {
                    await browser.loadCapture(client: runtime.client, for: id)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: LingXiMetrics.Space.sm) {
            Image(systemName: "desktopkit").font(.system(size: LXIcon.emptyState))
            Text(title).font(LXType.callout)
            Text(detail).font(LXType.meta).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder private var sessionList: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: LingXiMetrics.Space.xs) {
                    ForEach(browser.sessions) { session in
                        Button {
                            browser.selectedID = session.sessionID
                            Task { await browser.loadCapture(client: runtime.client, for: session.sessionID) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title.isEmpty ? session.url : session.title)
                                    .font(LXType.body).lineLimit(1)
                                Text(session.url)
                                    .font(LXType.meta).foregroundStyle(.secondary).lineLimit(1)
                                Text(detailLine(for: session))
                                    .font(LXType.meta).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LingXiMetrics.Space.sm)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(browser.selected?.sessionID == session.sessionID
                                          ? Color.accentColor.opacity(0.16) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(LingXiMetrics.Space.xs)
            }
            .frame(maxWidth: 260)
            .overlay(alignment: .trailing) { LXHairline() }

            captureSurface
        }
    }

    @ViewBuilder private var captureSurface: some View {
        VStack(spacing: LingXiMetrics.Space.xs) {
            if let image = captureImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let path = browser.capture?.savedPath {
                VStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "photo").font(.system(size: LXIcon.emptyState))
                    Text("截图已保存到 \(path)").font(LXType.meta)
                }
                .foregroundStyle(.secondary)
            } else {
                VStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "camera").font(.system(size: LXIcon.emptyState))
                    Text(browser.capture == nil ? "尚无截图，点「刷新」向 Agent 的会话取一张。" : "取图中…")
                        .font(LXType.meta)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LingXiMetrics.Space.sm)
    }

    private var captureImage: NSImage? {
        guard let base64 = browser.capture?.base64JPEG, !base64.isEmpty,
              let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    private func detailLine(for session: BrowserSessionStatus) -> String {
        var parts: [String] = []
        if let tab = session.tabID { parts.append("tab \(tab)") }
        if let version = session.observationVersion { parts.append("v\(version)") }
        parts.append("\(session.observedElementCount) 元素")
        if let at = session.observedAt { parts.append(Self.timeFormatter.string(from: at)) }
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Git 面板的每一次读写都经 Core 的 Git RPC。
///
/// 前端不再启动 git：状态、分支、upstream、ahead/behind 来自 `git.status`，
/// 逐文件行数与 patch 来自同一个 `git.diff`，暂存/提交/远程同步来自结构化 mutation RPC
/// （契约第八、九、十一节）。这里没有任何 raw git 兜底路径。
@MainActor final class WarmGitModel: ObservableObject {
    /// Core 解析 porcelain records 后的逐文件明细。
    @Published var files: [GitFileChange] = []
    @Published var diff = ""
    /// 路径 → 行变化。来自 `git.diff` 的 files[]，不是另跑一次 numstat。
    @Published var fileStats: [String: GitFileChange] = [:]
    @Published var log = ""
    @Published var branch = ""
    @Published var ahead: Int?
    @Published var behind: Int?
    /// 用户可见的工作区变化徽标唯一来源：去重后的变化路径数（契约第二十节）。
    @Published var dirtyPathCount: Int?
    @Published var error: String?
    @Published var isBusy = false
    /// Core 未回答过一次之前，面板不得声称工作区是干净的。
    @Published private(set) var hasLoaded = false
    @Published private(set) var isDiffLoading = false

    private var client: LingXiClientVNext?
    private var workspacePath: String?

    var aheadBehind: String? {
        guard let ahead, let behind else { return nil }
        return "\u{2191}\(ahead) \u{2193}\(behind)"
    }

    func refresh(at workspace: URL?, client: LingXiClientVNext?) {
        self.workspacePath = workspace?.path
        self.client = client
        guard let client else {
            isBusy = false
            return
        }
        isBusy = true
        Task {
            let statusResult = try? await client.git.status()
            let logResult = try? await client.git.log(limit: 8)
            guard !Task.isCancelled else { return }
            if let statusResult {
                self.files = statusResult.files
                self.branch = statusResult.branchName ?? ""
                self.ahead = statusResult.ahead
                self.behind = statusResult.behind
                self.dirtyPathCount = statusResult.dirtyPathCount
                self.error = nil
                self.hasLoaded = true
            } else {
                self.error = "Core 未能读取 Git 状态"
            }
            if let logResult { self.log = logResult.text }
            self.isBusy = false
        }
    }

    /// patch 与行数来自同一次 `git.diff`：范围一致，数字描述的正是屏幕上这段 patch。
    /// 未跟踪文件的行数同样由 Core 算好放进 `git.diff` 的 files[]：前端不读文件、不数行。
    func loadDiff() async {
        guard let client, !isDiffLoading else { return }
        isDiffLoading = true
        defer { isDiffLoading = false }
        guard let result = try? await client.git.diff(scope: .head) else {
            error = "Core 未能读取差异"
            return
        }
        guard !Task.isCancelled else { return }
        diff = result.patch ?? ""
        fileStats = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })
    }

    // MARK: - 写操作

    func stageAll() {
        mutate("暂存") { _ = try await $0.git.add(all: true) }
    }

    func unstageAll() {
        mutate("取消暂存") { _ = try await $0.git.restore(paths: ["."], stagedOnly: true) }
    }

    func commit(message: String, onSuccess: @escaping () -> Void) {
        mutate("提交", onSuccess: onSuccess) { _ = try await $0.git.commit(message: message) }
    }

    func fetch() {
        mutate("获取") { _ = try await $0.git.fetch() }
    }

    func pull() {
        mutate("拉取") { _ = try await $0.git.pull() }
    }

    func push() {
        mutate("推送") { _ = try await $0.git.push() }
    }

    private func mutate(_ label: String, onSuccess: (() -> Void)? = nil, _ operation: @escaping (LingXiClientVNext) async throws -> Void) {
        guard let client else {
            error = "尚未连接 Core"
            return
        }
        isBusy = true
        Task {
            do {
                _ = try await operation(client)
                error = nil
                onSuccess?()
            } catch let failure as CoreError {
                // 分叉是预期分支，不是故障：给出可决策的措辞，不掩盖成"命令失败"。
                error = failure.code == .gitNonFastForward
                    ? "本地与远端已分叉，无法 fast-forward。请选择 merge 或 rebase 后再拉取。"
                    : "\(label)失败：\(failure.message)"
            } catch {
                self.error = "\(label)失败：\(error.localizedDescription)"
            }
            self.refresh(at: workspacePath.map(URL.init(fileURLWithPath:)), client: client)
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
    /// 行列表直接来自 Core 解析后的 `git.status` files[]：
    /// 前端不再从 `--short` 文本里切列，也不再自己数脏文件。
    private var staged: [GitFileChange] {
        git.files.filter { !$0.isUntracked && !$0.isConflicted && $0.indexStatus != " " }
    }
    private var unstaged: [GitFileChange] {
        git.files.filter { $0.isUntracked || $0.isConflicted || $0.worktreeStatus != " " }
    }
    private var changedFiles: [GitFileChange] { git.files }

    /// Core 的 `git.log` 是 `--oneline`：hash 与 subject 以空格分隔。
    private var commits: [(hash: String, subject: String)] {
        git.log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
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
                // 徽标只认 Core 的 dirtyPathCount：同一路径 staged + unstaged 只算一个，
                // 未跟踪目录已按 -uall 展开，ignored 不计（契约第二十节）。
                if let dirty = git.dirtyPathCount, dirty > 0 {
                    Text("\(dirty)")
                        .font(LXType.meta.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(LXColor.content, in: Capsule())
                        .help("\(dirty) 个文件路径存在工作区变化")
                        .accessibilityLabel("\(dirty) 个工作区变化")
                }
                Menu {
                    Button("刷新") { git.refresh(at: workspace, client: runtime.client) }
                    Divider()
                    Button("暂存全部") { git.stageAll() }
                    Button("取消暂存全部") { git.unstageAll() }
                    Divider()
                    // 远程同步同样是结构化 RPC：fetch 更新远端引用，pull 只允许 fast-forward，
                    // push 需要 upstream 或显式目标。Core 不 force、不猜目标。
                    Button("获取") { git.fetch() }
                    Button("拉取") { git.pull() }
                    Button("推送") { git.push() }
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
                        git.commit(message: message) { message = "" }
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
                    if !git.hasLoaded {
                        PlaceholderLine(git.isBusy ? "正在读取工作区状态…" : "未打开工作区。")
                            .padding(.vertical, LingXiMetrics.Space.md)
                    } else if changedFiles.isEmpty {
                        PlaceholderLine("工作区没有未提交改动。")
                            .padding(.vertical, LingXiMetrics.Space.md)
                    } else {
                        fileSection("已暂存", files: staged)
                        fileSection("未暂存", files: unstaged)
                    }
                    LXSection("最近提交", separated: !changedFiles.isEmpty) {
                        if !git.hasLoaded {
                            PlaceholderLine(git.isBusy ? "正在读取…" : "未打开工作区。")
                        } else if commits.isEmpty {
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
                            OutputBlock(text: git.isDiffLoading ? "正在读取差异…"
                                        : (git.diff.isEmpty ? "没有可显示的差异" : git.diff),
                                        isDiff: !git.diff.isEmpty)
                        }
                    }
                    Button(showsDiff ? "收起差异" : "查看差异") {
                        showsDiff.toggle()
                        if showsDiff { Task { await git.loadDiff() } }
                    }
                    .buttonStyle(LXButtonStyle(.plain, size: .small))
                    .padding(.vertical, LingXiMetrics.Space.sm)
                    .disabled(!git.hasLoaded || changedFiles.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LingXiMetrics.Space.panelInset)
            }
        }
        .onAppear { git.refresh(at: workspace, client: runtime.client) }
        .onChange(of: workspace) { _, new in git.refresh(at: new, client: runtime.client) }
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
    private func fileSection(_ title: String, files: [GitFileChange]) -> some View {
        LXSection(title, separated: title != "已暂存") {
            Text("\(files.count)")
        } content: {
            if files.isEmpty {
                PlaceholderLine(title == "已暂存" ? "还没有暂存的文件。" : "没有未暂存的改动。")
            }
            ForEach(files.indices, id: \.self) { index in
                let file = files[index]
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(file.isUntracked ? "?" : String(title == "已暂存" ? file.indexStatus : file.worktreeStatus))
                        .font(LXType.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    Text(file.path)
                        .font(LXType.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: LingXiMetrics.Space.sm)
                    // stats 为 nil 表示 Core 判定不了（超大 / 读不到 / 编码不可靠），留空而不是猜 0。
                    if let stats = git.fileStats[file.path], let additions = stats.additions, let deletions = stats.deletions {
                        LXDiffCount(additions: additions, deletions: deletions)
                            .font(LXType.meta)
                    }
                }
                .frame(minHeight: 26)
                .help(file.path)
            }
        }
    }
}

/// Renders the terminal sessions Core owns. It starts no process and ends none:
/// collapsing the panel only stops polling, which is what keeps a session alive
/// across a view rebuild.
@MainActor private final class WarmTerminalModel: ObservableObject {
    @Published var sessions: [TerminalSessionInfo] = []
    @Published var selectedID: String?
    @Published var error: String?
    private weak var runtime: RuntimeFrontend?
    private var pollTask: Task<Void, Never>?
    private(set) var columns = 80
    private(set) var rows = 24
    /// When the user last typed or output last arrived. Polling is fast while a session is
    /// live in front of someone and backs off when it goes quiet.
    private var lastActivity = Date.distantPast

    var selected: TerminalSessionInfo? { sessions.first { $0.id == selectedID } }
    var isRunning: Bool { selected?.state == .running }

    func attach(to runtime: RuntimeFrontend) {
        self.runtime = runtime
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Opening the panel opens a shell, as opening Terminal does — unless one is already
            // running (the panel was only re-laid out). The size is measured on appear first.
            await self?.refreshSessions()
            if let self, runtime.workspaceURL != nil,
               !self.sessions.contains(where: { $0.kind == .user && $0.state == .running }) {
                try? await Task.sleep(for: .milliseconds(50))
                await self.spawnShellNow()
            }
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // The session list changes rarely; the screen of the selected one constantly.
                if tick % 10 == 0 { await self.refreshSessions() }
                await self.pollSelected()
                tick += 1
                let hot = Date().timeIntervalSince(self.lastActivity) < 3
                try? await Task.sleep(for: .milliseconds(hot ? 40 : 250))
            }
        }
    }

    /// Stops reading. The sessions themselves keep running in Core.
    func detach() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshSessions() async {
        guard let runtime else { return }
        await runtime.refreshTerminalSessions()
        sessions = runtime.terminalSessions
        if selected == nil { selectedID = sessions.first?.id }
        error = runtime.terminalError
    }

    func pollSelected() async {
        guard let runtime, let selected, selected.state == .running else { return }
        if await runtime.pollTerminalOutput(sessionID: selected.id, columns: columns, rows: rows) {
            lastActivity = Date()
        }
        error = runtime.terminalError
    }

    func select(_ id: String) {
        selectedID = id
        lastActivity = Date()
        Task { await pollSelected() }
    }

    /// The pane's size before any screen exists, so a new shell starts at the right width.
    func measured(_ size: CGSize) {
        guard selected == nil else { return }
        (columns, rows) = TerminalScreenView.gridSize(for: size)
    }

    func resized(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        lastActivity = Date()
    }

    func spawnShell() {
        Task { await spawnShellNow() }
    }

    func spawnShellNow() async {
        guard let runtime else { return }
        await runtime.spawnTerminalShell(columns: columns, rows: rows)
        await refreshSessions()
        selectedID = runtime.terminalSessions.last { $0.kind == .user && $0.state == .running }?.id ?? selectedID
        lastActivity = Date()
    }

    /// Raw keystrokes, sent as typed: the PTY echoes and edits, not this view.
    func send(_ text: String) {
        guard let runtime, let selected else { return }
        lastActivity = Date()
        Task {
            await runtime.sendTerminalInput(sessionID: selected.id, text: text)
            await pollSelected()
        }
    }

    func interrupt() {
        guard let runtime, let selected else { return }
        Task {
            await runtime.interruptTerminal(sessionID: selected.id)
            await pollSelected()
        }
    }

    func closeSession() {
        guard let runtime, let selected else { return }
        Task {
            await runtime.closeTerminalSession(selected.id)
            selectedID = nil
            await refreshSessions()
        }
    }
}

private struct WarmTerminalPane: View {
    @ObservedObject var runtime: RuntimeFrontend
    @StateObject private var terminal = WarmTerminalModel()

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            // One tab per session that actually exists right now.
            HStack(spacing: LingXiMetrics.Space.xs) {
                ForEach(terminal.sessions) { session in
                    sessionTab(session)
                }
                Spacer(minLength: 0)
                if terminal.selected != nil {
                    Button { terminal.interrupt() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                        .disabled(terminal.selected?.supportsInterrupt != true)
                        .help(terminal.selected?.supportsInterrupt == true
                              ? "中断 (Ctrl-C)" : "该进程没有连接终端，无法中断")
                        .accessibilityLabel("中断")
                    Button { terminal.closeSession() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                        .help("结束该会话")
                        .accessibilityLabel("结束会话")
                }
                Button { terminal.spawnShell() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(LXIconButtonStyle(side: LXControl.small))
                    .disabled(runtime.workspaceURL == nil)
                    .help("新建 shell")
                    .accessibilityLabel("新建 shell")
            }
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .padding(.vertical, 6)
            LXHairline()

            Group {
                if let selected = terminal.selected {
                    TerminalScreen(emulator: runtime.terminalScreen(for: selected.id),
                                   generation: runtime.terminalGeneration,
                                   isEnabled: selected.state == .running && selected.supportsInput,
                                   onInput: terminal.send,
                                   onResize: terminal.resized)
                        .id(selected.id)
                } else {
                    VStack(spacing: LingXiMetrics.Space.md) {
                        PlaceholderLine(runtime.workspaceURL == nil ? "未打开工作区。" : "还没有终端会话。")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if runtime.workspaceURL != nil {
                            Button("新建 shell") { terminal.spawnShell() }
                                .buttonStyle(LXButtonStyle(.secondary, size: .small))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { terminal.measured(geometry.size) }
                        .onChange(of: geometry.size) { _, size in terminal.measured(size) }
                }
            }
            if let error = terminal.error {
                LXStatusText(error, systemImage: "exclamationmark.triangle", tone: .danger)
                    .padding(.horizontal, LingXiMetrics.Space.md)
            }
            footer(terminal.selected.map(Self.describe) ?? "没有会话 · 点击 ⊕ 新建 shell")
        }
        .onAppear { terminal.attach(to: runtime) }
        // Collapsing the panel stops reading. It never ends a session.
        .onDisappear { terminal.detach() }
    }

    /// 24pt tab: fill-control when selected; a running session carries the 6pt dot.
    private func sessionTab(_ session: TerminalSessionInfo) -> some View {
        let isSelected = terminal.selectedID == session.id
        return Button { terminal.select(session.id) } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                if session.state == .running {
                    Circle().fill(LXColor.running).frame(width: LXControl.dot, height: LXControl.dot)
                        .accessibilityLabel("执行中")
                }
                Text(Self.tabTitle(session)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .font(LXType.meta)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(minHeight: LXControl.tab)
            .fixedSize()
            .background(isSelected ? LXColor.fillControl : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private static func tabTitle(_ session: TerminalSessionInfo) -> String {
        switch session.kind {
        case .user: (session.title as NSString).lastPathComponent
        case .agent: "Agent · \(session.title)"
        }
    }

    /// The footer states what the session is, from Core's own fields.
    private static func describe(_ session: TerminalSessionInfo) -> String {
        let state: String
        switch session.state {
        case .running: state = "运行中"
        case .exited: state = "已退出\(session.exitCode.map { " · 退出码 \($0)" } ?? "")"
        case .timedOut: state = "已超时"
        case .terminated: state = "已终止"
        }
        switch session.kind {
        case .user: return "你的 shell · \(state) · ⌘C 复制选区 · ⌘V 粘贴 · ⌘K 清屏"
        case .agent:
            let owner = session.ownerRunID.map { " · run \($0.prefix(8))" } ?? ""
            return "Agent 会话 · \(state)\(owner)"
        }
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

