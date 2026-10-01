#if canImport(SwiftUI)
import SwiftUI
import AppKit
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

                ComposerSurface(runtime: runtime, model: model, isGenerating: conversation.isGenerating)
            }
        }
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: current?.id)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: suggestions?.count)
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
    @State private var isEditingGoal = false
    @State private var goalDraft = ""
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
            if isDropTargeted {
                RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous)
                    .strokeBorder(LXColor.accentText, lineWidth: 1)
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
            if isGenerating { Text("运行中不可切换") }
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
            if let goal = model.goal {
                GoalChip(goal: goal, onEdit: beginGoalEdit) { runtime.setGoal(nil) }
            }
            if !model.attachments.isEmpty { AttachmentStrip(attachments: model.attachments) }
            MacNativeTextView(text: $model.text,
                              placeholder: "给 Agent 发消息…",
                              submitRequiresCommand: sendKey == .commandReturn,
                              onSubmit: submit,
                              wantsInitialFocus: true)
                .frame(height: editorHeight)
                .accessibilityLabel("消息输入框")
                .help("@ 引用文件，/ 命令与技能，# 引用符号")
        }
        .frame(maxWidth: .infinity, minHeight: LingXiMetrics.composerMinHeight, alignment: .topLeading)
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.md)
        .popover(isPresented: $isEditingGoal, arrowEdge: .top) {
            GoalEditor(draft: $goalDraft) { goal in
                runtime.setGoal(goal)
                isEditingGoal = false
            }
        }
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
                Button(action: beginGoalEdit) {
                    Group {
                        if compact { Image(systemName: "target") }
                        else { Label("目标", systemImage: "target") }
                    }
                        .font(LXType.body.weight(.medium))
                        .padding(.horizontal, compact ? 0 : 10)
                        .frame(width: compact ? LXControl.regular : nil)
                        .frame(height: LXControl.regular)
                        .background(LXColor.fillControl,
                                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control))
                }
                .buttonStyle(.plain)
                .help("设定任务目标")
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
                LXChipMenu(model.reasoningEffort.rawValue, symbol: "sparkle", help: "思考等级") {
                    Picker("思考等级", selection: $model.reasoningEffort) {
                        ForEach(ReasoningEffortLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
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
                    Toggle(info.displayName, isOn: Binding(
                        get: { model.selectedModelID.map(info.matches(selection:)) ?? false },
                        set: { if $0 { model.selectedModelID = info.qualifiedID } }))
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
    /// colour never change and nothing glows.
    private var sendButton: some View {
        Button(action: isGenerating ? runtime.stopGenerating : submit) {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: isGenerating ? 11 : 14, weight: .bold))
                .foregroundStyle(LXColor.onAccent)
                .frame(width: LXControl.regular, height: LXControl.regular)
                .background(LXColor.accent, in: Circle())
                .opacity(!isGenerating && isEmpty ? 0.4 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isGenerating && isEmpty)
        .help(isGenerating ? "停止生成 (⌘.)" : (sendKey == .commandReturn ? "发送 (⌘⏎)" : "发送 (⏎)"))
        .accessibilityLabel(isGenerating ? "停止生成" : "发送")
    }

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty
    }

    // MARK: Actions

    private func submit() {
        guard !isEmpty, !isGenerating || model.text.hasPrefix("/") else { return }
        runtime.sendMessage(text: model.text, mode: model.selectedMode, attachments: model.attachments)
    }

    /// Presenting an optional message as an alert is the same four lines twice; inlined, the
    /// surrounding modifier chain stops type-checking inside the compiler's budget.
    private func errorBinding(_ path: ReferenceWritableKeyPath<RuntimeFrontend, String?>) -> Binding<Bool> {
        Binding(
            get: { runtime[keyPath: path] != nil },
            set: { if !$0 { runtime[keyPath: path] = nil } }
        )
    }

    private func beginGoalEdit() {
        goalDraft = model.goal ?? ""
        isEditingGoal = true
    }

    /// Attaches files the composer can actually hand to Core.
    ///
    /// This used to splice `@/abs/path` into the text field. That looked like an attachment and
    /// was a sentence: nothing parsed it, and the file's contents never reached the model. The
    /// strip below now holds real files, which `RuntimeFrontend` uploads before submitting.
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
        guard let mediaType = AttachmentSupport.mediaType(for: url) else {
            runtime.actionError = AttachmentSupport.unsupportedReason(for: url)
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        model.attachments.append(AttachmentPresentation(
            filename: url.lastPathComponent, mediaType: mediaType, byteCount: size, sourceURL: url))
    }


    private var separator: String {
        model.text.isEmpty || model.text.hasSuffix(" ") || model.text.hasSuffix("\n") ? "" : " "
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

/// 22pt accent-soft chip above the prompt, accent-text copy, clearable.
private struct GoalChip: View {
    let goal: String
    let onEdit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Button(action: onEdit) {
                Label(goal, systemImage: "target").lineLimit(1)
            }
            .buttonStyle(.plain)
            Button(action: onClear) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除目标")
        }
        .font(LXType.meta.weight(.medium))
        .foregroundStyle(LXColor.accentText)
        .padding(.horizontal, LingXiMetrics.Space.sm)
        .frame(height: LXControl.small)
        .background(LXColor.accentSoft, in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务目标：\(goal)")
    }
}

private struct GoalEditor: View {
    @Binding var draft: String
    let onCommit: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("任务目标").font(LXType.headline)
            TextField("交付物与验收标准", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .frame(width: 320)
                .onSubmit { onCommit(draft) }
            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer(minLength: 0)
                Button("清除") { onCommit(nil) }.buttonStyle(.lxSecondary)
                Button { onCommit(draft) } label: { LXKeyHintLabel("设定", hint: "⏎") }
                    .buttonStyle(.lxPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.lg)
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
