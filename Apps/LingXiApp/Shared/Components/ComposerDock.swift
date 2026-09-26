#if canImport(SwiftUI)
import SwiftUI
import AppKit
import LingXiProtocol

// MARK: - Dock

/// The floating execution layer at the foot of the stage: pending human
/// requests, `/` command suggestions and the composer, all in ONE glass group
/// on the reading column so they sample one backdrop and morph together.
struct ComposerDock: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject private var model: ComposerModel
    @ObservedObject private var conversation: ConversationPresentationModel
    @State private var activeIndex = 0
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.composerModel
        self.conversation = runtime.conversationModel
    }

    var body: some View {
        LXGlassGroup(spacing: LingXiMetrics.Space.md) {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                if let card = current {
                    Group {
                        if card.kind == .permission {
                            PermissionSurface(card: card, position: position,
                                              policy: model.permissionPreset.label) { approved in
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
                    .lxGlassID("interaction", in: glass)
                    .transition(.opacity.combined(with: .offset(y: LingXiMetrics.Space.sm)))
                }

                if let suggestions, !suggestions.isEmpty {
                    CommandSuggestionList(commands: suggestions) { model.text = "/\($0.name) " }
                        .lxGlassID("commands", in: glass)
                        .transition(.opacity)
                }

                ComposerSurface(runtime: runtime, model: model, isGenerating: conversation.isGenerating)
                    .lxGlassID("composer", in: glass)
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
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isGenerating { contextStrip }
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
            insertFileReferences(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Layer 1 — where

    private var contextStrip: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            stripItem(workspace.isRemote ? "network" : "desktopcomputer", workspace.isRemote ? "Remote" : "Local")
            stripItem("folder", runtime.workspaceURL?.lastPathComponent ?? workspace.name)
            if let branch = workspace.gitBranch ?? runtime.inspectorModel.live?.branch, !branch.isEmpty {
                stripItem("arrow.triangle.branch", branch)
            }
            if let worktree = workspace.worktreeBranch, !worktree.isEmpty {
                stripItem("square.stack.3d.up", worktree)
            }
            Spacer(minLength: 0)
        }
        .font(LXType.meta)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .overlay(alignment: .bottom) { LXHairline() }
        .help(runtime.workspaceURL?.path ?? workspace.name)
    }

    private var workspace: WorkspaceSummaryPresentation { runtime.sidebarModel.workspace }

    private func stripItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Image(systemName: symbol).font(.system(size: LXIcon.strip))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
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
                              onSubmit: submit)
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

    private var actionBar: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                LXChipMenu("添加", symbol: "plus.circle", help: "添加文件、引用或设定任务目标") {
                    Button("文件或图片…", systemImage: "paperclip", action: pickFiles)
                    Button("引用文件 @", systemImage: "at") { insertReference("@") }
                    Button("引用符号 #", systemImage: "number") { insertReference("#") }
                    Divider()
                    Button("设定任务目标…", systemImage: "target", action: beginGoalEdit)
                }
                LXChipMenu(model.permissionPreset.shortLabel,
                           symbol: model.permissionPreset.isElevated ? "exclamationmark.shield" : "checkmark.shield",
                           help: "权限策略：\(model.permissionPreset.label)") {
                    Picker("权限策略", selection: $model.permissionPreset) {
                        ForEach(PermissionPreset.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
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
                LXChipMenu("\(modelLabel) · \(model.reasoningEffort.rawValue)", symbol: "cpu",
                           help: "模型与思考等级") {
                    modelMenu
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
        let groups = Dictionary(grouping: model.models.filter(\.configured), by: \.providerID)
        if groups.isEmpty {
            Text("Core 还没有返回可用模型")
        }
        ForEach(groups.keys.sorted(), id: \.self) { provider in
            Section(provider) {
                ForEach(groups[provider] ?? [], id: \.id) { info in
                    Toggle(info.displayName, isOn: Binding(
                        get: { model.selectedModelID == info.id || model.selectedModelID == info.modelID },
                        set: { if $0 { model.selectedModelID = info.id } }))
                }
            }
        }
        Section("思考等级") {
            Picker("思考等级", selection: $model.reasoningEffort) {
                ForEach(ReasoningEffortLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                        .disabled(!model.availableReasoningLevels.contains(level))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var modelLabel: String {
        guard let id = model.selectedModelID else { return "选择模型" }
        return model.models.first { $0.id == id || $0.modelID == id }?.displayName ?? id
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

    private func beginGoalEdit() {
        goalDraft = model.goal ?? ""
        isEditingGoal = true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "引用"
        if panel.runModal() == .OK { insertFileReferences(panel.urls) }
    }

    private func insertFileReferences(_ urls: [URL]) {
        let refs = urls.filter(\.isFileURL).map { "@" + $0.path }
        guard !refs.isEmpty else { return }
        model.text += separator + refs.joined(separator: " ") + " "
    }

    private func insertReference(_ marker: String) {
        model.text += separator + marker
    }

    private var separator: String {
        model.text.isEmpty || model.text.hasSuffix(" ") || model.text.hasSuffix("\n") ? "" : " "
    }
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
