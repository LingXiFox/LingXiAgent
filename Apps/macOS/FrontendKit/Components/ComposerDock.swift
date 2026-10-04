#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LingXiProtocol
import LingXiApplication

// MARK: - Dock

/// The floating execution layer at the foot of the stage: pending human
/// requests, `/` command suggestions and the composer, sharing the reading column.
struct ComposerDock: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var model: ComposerModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @State private var activeIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.composerModel
        self.conversation = runtime.conversationModel
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                if let card = current {
                    Group {
                        if card.kind == .permission {
                            PermissionSurface(card: card, position: position,
                                              policy: model.permissionPreset.label,
                                              workspaceOnly: !model.permissionPreset.isElevated) { approved in
                                runtime.resolveInteraction(interactionID: card.interactionID, approved: approved)
                                advance()
                            }
                        } else {
                            QuestionSurface(card: card, position: position) { selected, text in
                                runtime.answerQuestion(card, selected: selected, text: text)
                                advance()
                            } onCancel: {
                                runtime.cancelQuestion(card)
                                advance()
                            }
                        }
                    }
                    .id(card.id)
                    .transition(.opacity.combined(with: .offset(y: LingXiMetrics.Space.sm)))
                }

                if let suggestions, !suggestions.isEmpty {
                    CommandSuggestionList(commands: suggestions) { model.text = "/\($0.name) " }
                        .transition(.opacity)
                }

                if let goal = model.goalState {
                    GoalStatusBar(goal: goal, runtime: runtime)
                        .transition(.opacity.combined(with: .offset(y: LingXiMetrics.Space.sm)))
                }

                ComposerSurface(runtime: runtime, model: model, isGenerating: conversation.isGenerating)
            }
        }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: current?.id)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: suggestions?.count)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: model.goalState == nil)
        .onChange(of: pending.count) { _, count in
            if activeIndex >= max(count, 1) { activeIndex = 0 }
        }
    }

    private var pending: [InteractionCardPresentation] {
        conversation.items.compactMap {
            if case .interaction(let card) = $0.kind, card.status == .pending { return card }
            return nil
        }
    }

    private var current: InteractionCardPresentation? {
        guard !pending.isEmpty else { return nil }
        return pending[min(activeIndex, pending.count - 1)]
    }

    /// Real queue position, e.g. `1 / 3`.
    private var position: String {
        "\(min(activeIndex, max(pending.count - 1, 0)) + 1) / \(max(pending.count, 1))"
    }

    private func advance() {
        activeIndex = min(activeIndex + 1, max(pending.count - 1, 0))
    }

    /// `/` at the start of a single-word draft lists matching commands.
    private var suggestions: [CommandDescriptor]? {
        let text = model.text
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        let query = text.dropFirst().lowercased()
        return Array(runtime.availableCommands.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }.prefix(8))
    }
}

// MARK: - Composer surface

/// Three layers: where (context strip) → what (editor) → how (action bar).
/// The shell adds no padding; each layer owns its inset.
struct ComposerSurface: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject var model: ComposerModel
    let isGenerating: Bool

    @State private var isDropTargeted = false
    /// 目标模式：整个输入框就是目标输入框。
    ///
    /// It used to open a `GoalEditor` popover with its own text field below the composer. That
    /// was a second input box for the same job, so the popover is gone: toggling the mode
    /// retitles the composer, and ⏎ sends whatever it holds as the goal. Outside this mode the
    /// composer only ever sends messages — the goal is edited, paused and removed from the bar
    /// above it.
    private var goalMode: Bool { model.isGoalMode }
    @State private var confirmYOLO = false
    @State private var permissionBeforeYOLO: PermissionPreset?
    @State private var localBranches: [String] = []
    @State private var newBranchDraft = ""
    @State private var isCreatingBranch = false
    @State private var branchError: String?
    @State private var composerWidth: CGFloat = 0
    @State private var confirmWorktree: WorktreeConfirmation?

    private enum WorktreeConfirmation: Identifiable {
        case apply, discard
        var id: Self { self }
    }
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextStrip
            editor
            actionBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous))
        .lxFloating()
        .overlay {
            if isDropTargeted || goalMode {
                RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous)
                    .strokeBorder(isDropTargeted ? LXColor.accentText : LXColor.accent,
                                  lineWidth: isDropTargeted ? 1 : 1.5)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            files.forEach(addAttachment(url:))
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .confirmationDialog("开启 YOLO 完全访问？", isPresented: $confirmYOLO) {
            Button("开启 YOLO", role: .destructive) {
                permissionBeforeYOLO = model.permissionPreset
                model.permissionPreset = .yoloFullAccess
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本会话将以 YOLO 完全访问运行。Agent 不再逐项请求授权，并可在工作区外读写文件、执行命令；Core 的硬性安全限制仍然生效。")
        }
        .alert("新建分支", isPresented: $isCreatingBranch) {
            TextField("分支名称", text: $newBranchDraft)
            Button("创建并切换") { changeBranch(newBranchDraft, create: true) }
            Button("取消", role: .cancel) {}
        }
        .alert("无法切换分支", isPresented: Binding(
            get: { branchError != nil },
            set: { if !$0 { branchError = nil } }
        )) {
            Button("好") { branchError = nil }
        } message: {
            Text(branchError ?? "")
        }
        .task(id: runtime.workspaceURL) { await loadBranches() }
        .confirmationDialog(confirmWorktree == .apply ? "把 Worktree 的改动应用到主工作区？" : "丢弃此 Worktree？",
                            isPresented: Binding(get: { confirmWorktree != nil }, set: { if !$0 { confirmWorktree = nil } }),
                            presenting: confirmWorktree) { choice in
            if choice == .apply {
                Button("应用") { Task { await runtime.applyCurrentWorktree() } }
            } else {
                Button("丢弃", role: .destructive) { Task { await runtime.discardCurrentWorktree() } }
            }
            Button("取消", role: .cancel) {}
        } message: { choice in
            Text(choice == .apply
                 ? "改动会以「已暂存、未提交」的形式落到主工作区，由你审阅后提交；随后移除此 Worktree 并回到主工作区。"
                 : "Worktree 目录与分支 \(workspace.worktreeBranch ?? "") 会被删除，其中未应用的改动无法恢复。")
        }
        .alert("Worktree", isPresented: errorBinding(\RuntimeFrontend.worktreeError)) {
            Button("好") { runtime.worktreeError = nil }
        } message: {
            Text(runtime.worktreeError ?? "")
        }
        .alert("操作未完成", isPresented: errorBinding(\RuntimeFrontend.actionError)) {
            Button("好") { runtime.actionError = nil }
        } message: {
            Text(runtime.actionError ?? "")
        }
    }

    // MARK: Layer 1 — where

    /// Always present, in every state: Local · workspace · branch · execution
    /// environment. 24pt borderless menus with a 10pt caret; while a run is in
    /// flight they keep their value but lock (no caret, not clickable).
    private var contextStrip: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            // Core only runs locally today: a plain label, not a menu.
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: "desktopcomputer").font(.system(size: LXIcon.strip))
                Text("Local")
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("运行位置 本地")

            Menu {
                Section("最近的工作区") {
                    ForEach(RecentWorkspaces.all.filter { FileManager.default.fileExists(atPath: $0.path) },
                            id: \.path) { url in
                        Button(url.lastPathComponent) { Task { await runtime.openWorkspace(url) } }
                    }
                }
                Divider()
                Button("打开工作区…") { WorkspacePicker.choose(runtime) }
                    .keyboardShortcut("o", modifiers: .command)
            } label: {
                StripMenuLabel(symbol: "folder",
                               text: runtime.workspaceURL?.lastPathComponent ?? workspace.name,
                               locked: isGenerating)
            }
            .stripMenu(locked: isGenerating)
            .help(runtime.workspaceURL?.path ?? workspace.name)
            .accessibilityLabel("工作区 \(runtime.workspaceURL?.lastPathComponent ?? workspace.name)")

            if let branch = workspace.gitBranch ?? runtime.inspectorModel.live?.branch, !branch.isEmpty {
                Menu {
                    Section("本地分支") {
                        ForEach(localBranches, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { name == branch }, set: { _ in changeBranch(name) }))
                        }
                    }
                    Divider()
                    Button("新建分支…") {
                        newBranchDraft = ""
                        isCreatingBranch = true
                    }
                } label: {
                    StripMenuLabel(symbol: "arrow.triangle.branch", text: branch, locked: isGenerating)
                }
                .stripMenu(locked: isGenerating)
                .accessibilityLabel("分支 \(branch)")
            }

            Menu {
                let inWorktree = workspace.worktreeBranch != nil
                Section("执行环境") {
                    Toggle(isOn: Binding(get: { !inWorktree },
                                         set: { if $0 { Task { await runtime.returnToMainWorkspace() } } })) {
                        Text("当前目录")
                        Text("改动直接写入工作区，放弃时回滚到 Core 的备份")
                    }
                    Toggle(isOn: Binding(get: { inWorktree },
                                         set: { if $0 { Task { await runtime.enterNewWorktree() } } })) {
                        Text("独立 Worktree")
                        Text("改动在隔离的 Worktree 中进行，接受后才落到工作区")
                    }
                    .disabled(workspace.gitBranch == nil)
                }
                if inWorktree {
                    Divider()
                    Button("应用到主工作区…") { confirmWorktree = .apply }
                    Button("丢弃此 Worktree…", role: .destructive) { confirmWorktree = .discard }
                }
            } label: {
                StripMenuLabel(symbol: "square.stack.3d.up",
                               text: workspace.worktreeBranch == nil ? "当前目录" : "独立 Worktree",
                               locked: isGenerating)
            }
            .stripMenu(locked: isGenerating)
            .accessibilityLabel("执行环境")

            Spacer(minLength: 0)
            if isGenerating {
                // Named what it locks instead of just saying 「不可切换」: the three menus to
                // the left are what a run freezes, and a bare hint never said which. Same 24pt
                // box as those menus, or the label sat on a different baseline than its own row.
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: "lock").font(.system(size: LXIcon.strip))
                    Text("工作区已锁定")
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .accessibilityLabel("运行中，工作区、分支与执行环境已锁定")
            }
        }
        .font(LXType.meta)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LingXiMetrics.Space.sm)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { LXHairline() }
    }

    private var workspace: WorkspaceSummaryPresentation { runtime.sidebarModel.workspace }

    /// 分支列表来自 Core 的 `git.branch`：前端不再跑 git，也不再自己解析仓库状态。
    private func loadBranches() async {
        guard let client = runtime.client else { localBranches = []; return }
        guard let result = try? await client.git.branch() else { localBranches = []; return }
        localBranches = result.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).replacingOccurrences(of: "* ", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 切分支是 Git mutation：走 RPC 进 ToolMutationCoordinator 与 PermissionEngine，
    /// 与 Agent 的写操作共用同一条串行化路径（契约第十五、十六节）。
    private func changeBranch(_ branch: String, create: Bool = false) {
        guard let client = runtime.client, !isGenerating else { return }
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else { return }
        Task {
            do {
                _ = try await client.git.switch(branch: name, createBranch: create)
                await loadBranches()
                runtime.refreshRuntimeDetails()
            } catch let failure as CoreError {
                branchError = failure.message
            } catch {
                branchError = error.localizedDescription
            }
        }
    }

    // MARK: Layer 2 — what

    private var editor: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            if !model.attachments.isEmpty { AttachmentStrip(attachments: model.attachments) }
            MacNativeTextView(text: $model.text,
                              placeholder: goalMode ? "写下要达成的目标，⏎ 发出并开始…" : "给 Agent 发消息…",
                              submitRequiresCommand: sendKey == .commandReturn,
                              onSubmit: submit,
                              wantsInitialFocus: false,
                              presentationRevision: model.automationPending ? model.draftRevision : nil,
                              focusRevision: model.automationPending ? model.draftRevision : nil,
                              onPresented: runtime.automationController.composerPresented,
                              onCancel: { runtime.automationController.cancel() })
                .frame(height: editorHeight)
                .accessibilityLabel(goalMode ? "任务目标输入框" : "消息输入框")
                .help(goalMode ? "⏎ 发出目标并开始执行，Esc 回到发消息" : "@ 引用文件，/ 命令与技能，# 引用符号")
        }
        .frame(maxWidth: .infinity, minHeight: LingXiMetrics.composerMinHeight, alignment: .topLeading)
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.md)
        .background { if goalMode { LXColor.accentSoft } }
        .onExitCommand { if goalMode { exitGoalMode() } }
    }

    /// Grows with the draft from 2 to 8 lines, then scrolls inside.
    private var editorHeight: CGFloat {
        let lines = model.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(max(lines, 2), LingXiMetrics.composerMaxLines)) * MacNativeTextView.bodyLineHeight
    }

    // MARK: Layer 3 — how

    /// Left group collapses to 28×28 icon chips only when the composer itself is
    /// narrower than 560pt (stage squeezed by a tool panel). Width, not content,
    /// decides: a longer label such as 「YOLO 已开启」 must never flip the mode.
    private var actionBar: some View {
        actionRow(compact: composerWidth > 0 && composerWidth < LingXiMetrics.Column.composerCompact)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { composerWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in composerWidth = width }
                }
            }
    }

    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                LXChipMenu("添加", symbol: "plus.circle", help: "添加文件或引用", iconOnly: compact) {
                    Button("文件或图片…", systemImage: "paperclip", action: pickFiles)
                    // 「引用文件 @」「引用符号 #」两项已移除：它们只在输入框里插入一个字符，
                    // Core 与 Application 侧都没有 @-mention 或符号解析，插入的 `@` 没有任何含义。
                    // 引用真实文件现在走上面的附件项，会真的上传并进入本轮上下文。
                }
                Button(action: goalMode ? exitGoalMode : enterGoalMode) {
                    Group {
                        if compact { Image(systemName: goalMode ? "xmark" : "target") }
                        else { Label(goalMode ? "退出目标" : "目标", systemImage: goalMode ? "xmark" : "target") }
                    }
                        .font(LXType.body.weight(.medium))
                        .foregroundStyle(goalMode ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.primary))
                        .padding(.horizontal, compact ? 0 : 10)
                        .frame(width: compact ? LXControl.regular : nil)
                        .frame(height: LXControl.regular)
                        .background(goalMode ? LXColor.accentSoft : LXColor.fillControl,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control))
                }
                .buttonStyle(.plain)
                .help(goalMode ? "退出目标模式，回到发消息" : "把输入框切成目标输入框")
                .accessibilityValue(goalMode ? "目标模式开启" : "目标模式关闭")
                Button {
                    if model.permissionPreset == .yoloFullAccess {
                        model.permissionPreset = permissionBeforeYOLO ?? .askWorkspace
                    } else {
                        confirmYOLO = true
                    }
                } label: {
                    Group {
                        if compact { Image(systemName: "bolt") }
                        else {
                            Label(model.permissionPreset == .yoloFullAccess ? "YOLO 已开启" : "YOLO",
                                  systemImage: "bolt")
                        }
                    }
                        .font(LXType.body.weight(.medium))
                        .foregroundStyle(model.permissionPreset == .yoloFullAccess ? LXColor.warning : .primary)
                        .padding(.horizontal, compact ? 0 : 10)
                        .frame(width: compact ? LXControl.regular : nil)
                        .frame(height: LXControl.regular)
                        .background(LXColor.fillControl,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control))
                        .overlay {
                            if model.permissionPreset == .yoloFullAccess {
                                RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control)
                                    .strokeBorder(LXColor.warning, lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(model.permissionPreset == .yoloFullAccess ? "关闭 YOLO" : "开启 YOLO 完全访问")
                .accessibilityValue(model.permissionPreset == .yoloFullAccess ? "已开启" : "已关闭")
            }
            Spacer(minLength: 0)
            HStack(spacing: LingXiMetrics.Space.sm) {
                LXChipMenu(model.selectedMode.rawValue, symbol: modeSymbol,
                           help: "Build 执行改动 · Plan 只规划 · Explore 只读探索") {
                    Picker("模式", selection: $model.selectedMode) {
                        Label("Build 执行改动", systemImage: "hammer").tag(AgentRunMode.build)
                        Label("Plan 只规划", systemImage: "list.bullet.rectangle").tag(AgentRunMode.plan)
                        Label("Explore 只读探索", systemImage: "binoculars").tag(AgentRunMode.explore)
                    }
                    .pickerStyle(.inline)
                }
                LXChipMenu(modelLabel, symbol: runtime.providerStatus?.configured == false ? "exclamationmark.triangle" : "cpu",
                           help: runtime.providerStatus?.configured == false ? "Provider 未就绪，请在设置中连接账户" : "选择模型：\(modelLabel)") {
                    modelMenu
                }
                LXChipMenu(model.reasoningLabel(model.reasoningEffort), symbol: "sparkle", help: "思考等级") {
                    Picker("思考等级", selection: $model.reasoningEffort) {
                        ForEach(model.reasoningMenuLevels, id: \.self) { level in
                            Text(model.reasoningLabel(level)).tag(level)
                                .disabled(!model.availableReasoningLevels.contains(level))
                        }
                    }
                    .pickerStyle(.inline)
                }
                sendButton
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.top, LingXiMetrics.Space.xs)
        .padding(.bottom, LingXiMetrics.Space.md)
    }

    @ViewBuilder
    private var modelMenu: some View {
        if runtime.providerStatus?.configured == false {
            Text("Provider 未就绪，请在设置中连接账户")
        }
        let groups = Dictionary(grouping: model.models.filter(\.configured), by: \.providerID)
        if groups.isEmpty {
            Text("Core 还没有返回可用模型")
        }
        ForEach(groups.keys.sorted(), id: \.self) { provider in
            Section(provider) {
                ForEach(groups[provider] ?? [], id: \.id) { info in
                    Toggle(isOn: Binding(
                        get: { model.selectedModelID.map(info.matches(selection:)) ?? false },
                        set: { if $0 { model.selectedModelID = info.qualifiedID } })) {
                        // A probe that reached the model is the only thing that can tell a working name
                        // from one the plan excludes; /v1/models lists both. nil means nobody has
                        // tried yet, which must not read as a verdict either way.
                        if info.availability == .unavailable {
                            Label(info.displayName, systemImage: "exclamationmark.triangle")
                        } else {
                            Text(info.displayName)
                        }
                    }
                    // Offered but not selectable: a plan can change, and hiding the row entirely would
                    // leave no way to re-probe it from here. The reason stays visible in the label.
                    .disabled(info.availability == .unavailable)
                }
            }
        }
    }

    /// Display name, clipped so a long model name never pushes the send button
    /// out of the row.
    private var modelLabel: String {
        if runtime.providerStatus?.configured == false { return "模型未连接" }
        guard let id = model.selectedModelID, !id.isEmpty else { return "选择模型" }
        let name = model.models.first { $0.matches(selection: id) }?.displayName ?? id
        let label = name.isEmpty ? id : name
        return label.count > 20 ? String(label.prefix(19)) + "…" : label
    }

    private var modeSymbol: String {
        switch model.selectedMode {
        case .build: return "hammer"
        case .plan: return "list.bullet.rectangle"
        case .explore: return "binoculars"
        }
    }

    /// One 28pt accent circle. Running swaps the glyph only; position and
    /// colour never change and nothing glows. In 目标模式 it commits the goal instead of
    /// sending, and a run in flight does not turn it into a stop button — anchoring a goal
    /// is exactly the thing you want to be able to do mid-run.
    private var sendButton: some View {
        let stops = !goalMode && isGenerating
        let symbol = goalMode ? "checkmark" : (stops ? "stop.fill" : "arrow.up")
        let inert = goalMode ? model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             : (!isGenerating && isEmpty)
        return Button(action: sendAction) {
            Image(systemName: symbol)
                .font(.system(size: stops ? 11 : 14, weight: .bold))
                .foregroundStyle(LXColor.onAccent)
                .frame(width: LXControl.regular, height: LXControl.regular)
                .background(LXColor.accent, in: Circle())
                .opacity(inert ? 0.4 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(inert)
        .help(sendHelp)
        .accessibilityLabel(goalMode ? "发出目标" : (stops ? "停止生成" : "发送"))
    }

    private func sendAction() {
        if isGenerating && !goalMode { runtime.stopGenerating() }
        else if goalMode { commitGoal() }
        else { submit() }
    }

    private var sendHelp: String {
        if model.automationPending { return "发送 (⏎)，Esc 取消自动发送" }
        if goalMode { return "发出目标并开始 (⏎)" }
        if isGenerating { return "停止生成 (⌘.)" }
        return sendKey == .commandReturn ? "发送 (⌘⏎)" : "发送 (⏎)"
    }

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty
    }

    // MARK: Actions

    private func submit() {
        runtime.submitComposer()
    }

    /// Presenting an optional message as an alert is the same four lines twice; inlined, the
    /// surrounding modifier chain stops type-checking inside the compiler's budget.
    private func errorBinding(_ path: ReferenceWritableKeyPath<RuntimeFrontend, String?>) -> Binding<Bool> {
        Binding(
            get: { runtime[keyPath: path] != nil },
            set: { if !$0 { runtime[keyPath: path] = nil } }
        )
    }

    /// What is already typed stays: it becomes the goal when sent.
    private func enterGoalMode() {
        model.isGoalMode = true
    }

    private func exitGoalMode() {
        model.isGoalMode = false
    }

    /// ⏎ in 目标模式: the text is anchored as the goal and sent as the turn that starts work.
    private func commitGoal() {
        runtime.submitComposer()
    }

    /// Attaches whatever was picked, of any type.
    ///
    /// This used to splice `@/abs/path` into the text field. That looked like an attachment and
    /// was a sentence: nothing parsed it, and the file's contents never reached the model. The
    /// strip below now holds real files, which `RuntimeFrontend` uploads before submitting.
    ///
    /// It also used to consult `AttachmentSupport.textMediaTypes`, a 40-entry extension table, and
    /// refuse anything not on it. That table answered a question the composer cannot answer —
    /// whether a model reads a file is not a fact about file extensions — and it got both sides
    /// wrong: `.conf`, `.eps`, `.excalidraw` and extension-less files decode fine as text yet were
    /// blocked, while the refusal it did raise blamed a type list for what is really a limit of
    /// this product's model request. Refusing nothing here is what makes Core's one honest
    /// failure (「这些字节不是文本，所以送不到模型」) the only gate that exists.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // A directory has no bytes to attach; the agent reads directories through its own tools.
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where url.isFileURL { addAttachment(url: url) }
    }

    private func addAttachment(url: URL) {
        guard !model.attachments.contains(where: { $0.sourceURL == url }) else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let mime = Self.mediaType(for: url)
        let item = AttachmentPresentation(
            filename: url.lastPathComponent, mediaType: mime, byteCount: size,
            thumbnailSymbol: mime.hasPrefix("image/") ? "photo" : "doc.text",
            sourceURL: url)
        model.attachments.append(item)
        // Preparation starts now, not at ⏎ — by the time the question is typed it is done.
        runtime.prepareAttachment(id: item.id, url: url)
    }

    /// What the file says it is — a label that travels with the upload so the runtime can name
    /// the thing in a message. Descriptive only; it is never a reason to refuse.
    static func mediaType(for url: URL) -> String {
        let byName = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
        if let byName, byName != "application/octet-stream" { return byName }
        if let byContent = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType {
            return byContent
        }
        return byName ?? "application/octet-stream"
    }
}

// MARK: - Context strip menus

/// 24pt light menu button: no fill at rest, fill-control on hover, 10pt caret.
private struct StripMenuLabel: View {
    let symbol: String
    let text: String
    let locked: Bool

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Image(systemName: symbol).font(.system(size: LXIcon.strip))
            Text(text).lineLimit(1).truncationMode(.middle)
            if !locked {
                Image(systemName: "chevron.down").font(.system(size: LXIcon.stripCaret))
            }
        }
        .font(LXType.meta)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct StripMenuModifier: ViewModifier {
    let locked: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(isHovered && !locked ? LXColor.fillControl : .clear,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
            .onHover { isHovered = $0 }
            .disabled(locked)
    }
}

private extension View {
    func stripMenu(locked: Bool) -> some View { modifier(StripMenuModifier(locked: locked)) }
}

// MARK: - Goal

/// The goal, above the composer: what it is, how long it has been running, and the only
/// three things that act on it — edit, pause/resume, remove. The composer below never
/// changes the goal; typing there is an ordinary message.
private struct GoalStatusBar: View {
    let goal: GoalRuntimeSnapshot
    @ObservedObject var runtime: RuntimeFrontend
    @State private var isEditing = false
    @State private var draft = ""
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Image(systemName: goal.paused ? "pause.circle" : "target")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(goal.paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(LXColor.accentText))
            Text(goal.text)
                .font(LXType.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(goal.text)
            Spacer(minLength: LingXiMetrics.Space.sm)
            Text(goal.paused ? "已暂停" : "进行中")
                .font(LXType.micro.weight(.medium))
                .foregroundStyle(goal.paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(LXColor.accentText))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(goal.paused ? LXColor.fillControl : LXColor.accentSoft, in: Capsule())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(goal.runningSeconds(at: context.date)))
                    .font(LXType.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("目标运行时间（暂停期间不计）· 已推进 \(goal.steps) 步")
            HStack(spacing: 2) {
                Button {
                    draft = goal.text
                    isEditing = true
                } label: { Image(systemName: "pencil") }
                    .help("编辑目标")
                    .accessibilityLabel("编辑目标")
                    .popover(isPresented: $isEditing, arrowEdge: .top) { editor }
                Button { runtime.setGoalPaused(!goal.paused) } label: {
                    Image(systemName: goal.paused ? "play.fill" : "pause.fill")
                }
                .help(goal.paused ? "恢复目标" : "暂停目标：暂停期间 Agent 不再被目标驱动")
                .accessibilityLabel(goal.paused ? "恢复目标" : "暂停目标")
                Button { confirmRemove = true } label: { Image(systemName: "trash") }
                    .help("删除目标")
                    .accessibilityLabel("删除目标")
            }
            .buttonStyle(LXIconButtonStyle(side: LXControl.small))
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .frame(height: 36)
        .lxFloating(cornerRadius: LingXiMetrics.Radius.control)
        .confirmationDialog("删除目标？", isPresented: $confirmRemove) {
            Button("删除目标", role: .destructive) { runtime.setGoal(nil) }
        } message: {
            Text("Agent 将不再被这个目标驱动。会话记录不受影响。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目标：\(goal.text)，\(goal.paused ? "已暂停" : "进行中")")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("编辑目标").font(LXType.headline)
            TextField("要达成的目标", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("取消") { isEditing = false }
                    .buttonStyle(.lxSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    runtime.setGoal(draft)
                    isEditing = false
                }
                .buttonStyle(.lxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.lg)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Command suggestions

private struct CommandSuggestionList: View {
    let commands: [CommandDescriptor]
    let onPick: (CommandDescriptor) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { command in
                Button { onPick(command) } label: {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text("/\(command.name)").font(LXType.mono).foregroundStyle(.primary)
                        if !command.argument.isEmpty {
                            Text(command.argument).font(LXType.meta).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: LingXiMetrics.Space.md)
                        Text(command.summary).font(LXType.meta).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: LingXiMetrics.Size.menuItem)
                    .background(hovered == command.id ? LXColor.fillControl : .clear,
                                in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? command.id : (hovered == command.id ? nil : hovered) }
            }
        }
        .padding(5)
        .lxFloating()
        .accessibilityLabel("命令建议")
    }
}
#endif
