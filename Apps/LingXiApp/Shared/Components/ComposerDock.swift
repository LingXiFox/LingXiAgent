#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
#if os(macOS)
import AppKit
#endif

// MARK: - Dock

/// Floating execution layer at the foot of the timeline — "how the current task
/// proceeds": pending HITL requests, command suggestions and the composer, all
/// glass shapes in one container so they grow out of and melt back into it.
struct ComposerDock: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject var model: ComposerModel
    @ObservedObject var conversation: ConversationPresentationModel

    @State private var activeIndex = 0
    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(runtime: RuntimeFrontend) {
        self.runtime = runtime
        self.model = runtime.composerModel
        self.conversation = runtime.conversationModel
    }

    private var pending: [InteractionCardPresentation] {
        conversation.items.compactMap { item in
            if case .interaction(let card) = item.kind, card.status == .pending { return card }
            return nil
        }
    }

    var body: some View {
        ReadingColumn {
            LXGlassGroup(spacing: LingXiMetrics.Space.md) {
                VStack(spacing: LingXiMetrics.Space.sm) {
                    if let card = current {
                        Group {
                            if card.kind == .permission {
                                PermissionSurface(card: card, position: position,
                                                  policy: model.permissionPreset.label) { approved in
                                    runtime.resolveInteraction(interactionID: card.interactionID, approved: approved)
                                    advance()
                                }
                            } else {
                                QuestionSurface(card: card, position: position,
                                                onSubmit: { selected, text in
                                                    runtime.answerQuestion(card, selected: selected, text: text)
                                                    advance()
                                                },
                                                onCancel: {
                                                    runtime.cancelQuestion(card)
                                                    advance()
                                                })
                            }
                        }
                        .lxGlassID("interaction", in: glassSpace)
                        .transition(.opacity.combined(with: .offset(y: LingXiMetrics.Space.sm)))
                    }

                    if let suggestions = commandSuggestions, !suggestions.isEmpty {
                        CommandSuggestionList(commands: suggestions) { command in
                            model.text = "/\(command.name) "
                        }
                        .lxGlassID("commands", in: glassSpace)
                        .transition(.opacity)
                    }

                    ComposerSurface(runtime: runtime, model: model,
                                    isGenerating: conversation.isGenerating)
                        .lxGlassID("composer", in: glassSpace)
                }
            }
        }
        .padding(.top, LingXiMetrics.Space.sm)
        .padding(.bottom, LingXiMetrics.Space.lg)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: current?.id)
        .animation(LXMotion.animation(reduceMotion: reduceMotion), value: commandSuggestions?.count)
        .onChange(of: pending.count) { _, newCount in
            if activeIndex >= max(newCount, 1) { activeIndex = 0 }
        }
    }

    private var current: InteractionCardPresentation? {
        guard !pending.isEmpty else { return nil }
        return activeIndex < pending.count ? pending[activeIndex] : pending[0]
    }

    private var position: String? {
        pending.count > 1 ? "\(activeIndex + 1)/\(pending.count)" : nil
    }

    private func advance() {
        activeIndex = min(activeIndex + 1, max(pending.count - 1, 0))
    }

    /// `/` at the start of an otherwise single-word draft lists matching commands.
    private var commandSuggestions: [CommandDescriptor]? {
        let text = model.text
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        let query = text.dropFirst().lowercased()
        return Array(runtime.availableCommands
            .filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
            .prefix(8))
    }
}

// MARK: - Permission surface

/// Temporary approval layer. Operation, target resource and the verbatim
/// command are listed; risk shows as the shield glyph; only the primary
/// action takes the brand tint.
struct PermissionSurface: View {
    let card: InteractionCardPresentation
    let position: String?
    let policy: String
    var onResolve: (Bool) -> Void

    private var isElevated: Bool {
        ToolGlyph.isElevated(card.toolName)
            || card.capabilities.contains { $0.localizedCaseInsensitiveContains("external") || $0.localizedCaseInsensitiveContains("sensitive") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: isElevated ? "exclamationmark.shield.fill" : "checkmark.shield")
                    .foregroundStyle(isElevated ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text("请求授权")
                    .font(.lxCallout.weight(.semibold))
                Label(card.toolName, systemImage: ToolGlyph.symbol(for: card.toolName))
                    .font(.lxCallout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text([position, "发起方 \(card.agentRunID)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.lxMeta)
                    .foregroundStyle(.tertiary)
            }

            if !card.resource.isEmpty {
                Label(card.resource, systemImage: "scope")
                    .font(.lxMeta.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // Actual command / arguments verbatim, never summarised.
            Text(card.parametersSummary.isEmpty ? card.toolName : card.parametersSummary)
                .font(.lxMono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LingXiMetrics.Space.sm)
                .lxInsetBlock()

            HStack(spacing: LingXiMetrics.Space.sm) {
                if !card.capabilities.isEmpty {
                    Text(card.capabilities.joined(separator: " · "))
                        .font(.lxMeta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("当前策略 \(policy)")
                    .font(.lxMeta)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                // "Always allow" needs a scoped PermissionDecision; Core only has
                // allow / ask / deny, so no button that would behave like "allow once".
                Button("拒绝") { onResolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button("允许一次") { onResolve(true) }
                    .lxPrimaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LingXiMetrics.Space.lg)
        .lxGlass(in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous),
                 tint: LingXiTheme.obsidianSurface)
        .lxCrystalBorder(cornerRadius: LingXiMetrics.Radius.surface,
                         glowColor: isElevated ? LingXiTheme.neonCoral : LingXiTheme.solarGold)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("权限审批请求：\(card.toolName)")
    }
}

// MARK: - Question surface

/// Structured question or decision from the agent: options, optional free text,
/// submit or cancel.
struct QuestionSurface: View {
    let card: InteractionCardPresentation
    let position: String?
    var onSubmit: ([Int], String?) -> Void
    var onCancel: () -> Void

    @State private var selected: Set<Int> = []
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: card.kind == .decision ? "arrow.triangle.branch" : "questionmark.bubble.fill")
                    .foregroundStyle(card.kind == .decision ? LingXiTheme.electricCyan : LingXiTheme.astralViolet)
                    .accessibilityHidden(true)
                Text(card.kind == .decision ? "需要你决定" : "Agent 提问")
                    .font(.lxCallout.weight(.semibold))
                Spacer(minLength: 0)
                if let position {
                    Text(position).font(.lxMeta).foregroundStyle(.tertiary)
                }
            }

            Text(card.parametersSummary)
                .font(.lxBody)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !card.options.isEmpty {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(index) },
                            set: { on in
                                if card.allowsMultiple {
                                    if on { selected.insert(index) } else { selected.remove(index) }
                                } else {
                                    selected = on ? [index] : []
                                }
                            })) {
                            Text(option).font(.lxCallout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            if card.allowsFreeText && card.kind == .question {
                TextField("补充说明（可选）", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }

            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("提交") {
                    onSubmit(selected.sorted(), text.isEmpty ? nil : text)
                }
                .lxPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.lg)
        .lxGlass(in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous),
                 tint: LingXiTheme.obsidianSurface)
        .lxCrystalBorder(cornerRadius: LingXiMetrics.Radius.surface,
                         glowColor: card.kind == .decision ? LingXiTheme.electricCyan : LingXiTheme.astralViolet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent 提问：\(card.parametersSummary)")
    }
}

// MARK: - Command suggestions

private struct CommandSuggestionList: View {
    let commands: [CommandDescriptor]
    var onPick: (CommandDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { command in
                Button {
                    onPick(command)
                } label: {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text("/\(command.name)").font(.lxMono)
                            .foregroundStyle(LingXiTheme.electricCyan)
                        if !command.argument.isEmpty {
                            Text(command.argument).font(.lxMeta).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: LingXiMetrics.Space.sm)
                        Text(command.summary)
                            .font(.lxMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: LingXiMetrics.Row.list)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LingXiMetrics.Space.lg)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .lxGlass(in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous),
                 tint: LingXiTheme.obsidianSurface)
        .lxCrystalBorder(cornerRadius: LingXiMetrics.Radius.surface)
        .accessibilityLabel("命令建议")
    }
}

// MARK: - Composer surface

/// One glass container: goal, input, and a single control row
/// (attach · mode · model · reasoning · permission · goal · send).
struct ComposerSurface: View {
    @ObservedObject var runtime: RuntimeFrontend
    @ObservedObject var model: ComposerModel
    let isGenerating: Bool

    @State private var isDropTargeted = false
    @State private var isEditingGoal = false
    @State private var goalDraft = ""
    @AppStorage(LXPreferenceKey.sendKey) private var sendKey = SendKeyPreference.returnKey

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LingXiMetrics.Radius.surface, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            if let goal = model.goal {
                GoalChip(goal: goal, onEdit: beginGoalEdit, onClear: { runtime.setGoal(nil) })
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(attachments: model.attachments)
            }
            input
            controlRow
        }
        .padding(LingXiMetrics.Space.md)
        .lxGlass(in: surfaceShape, tint: LingXiTheme.obsidianSurface)
        .lxCrystalBorder(cornerRadius: LingXiMetrics.Radius.surface,
                         glowColor: isGenerating ? LingXiTheme.foxfireAmber : nil,
                         glowRadius: 10)
        .overlay {
            if isDropTargeted {
                surfaceShape.strokeBorder(LingXiTheme.foxfireAmber, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            insertFileReferences(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private var input: some View {
        #if os(macOS)
        MacNativeTextView(
            text: $model.text,
            isEditable: true,
            placeholder: placeholder,
            submitRequiresCommand: sendKey == .commandReturn,
            onSubmit: submit
        )
        .frame(height: inputHeight)
        .accessibilityLabel("消息输入框")
        #else
        TextField("给 Agent 发消息…", text: $model.text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...LingXiMetrics.composerMaxLines)
        #endif
    }

    private var placeholder: String {
        "@ 引用文件/Agent; / 命令与技能; ! 终端命令; # 代码片段"
    }

    #if os(macOS)
    /// Grows one line per explicit line break up to the cap, then scrolls internally.
    private var inputHeight: CGFloat {
        let lines = model.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let used = max(2, min(lines, LingXiMetrics.composerMaxLines))
        return CGFloat(used) * MacNativeTextView.bodyLineHeight + LingXiMetrics.Space.xs
    }
    #endif

    private var controlRow: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            // MARK: - Left utility buttons
            #if os(macOS)
            Button(action: pickFiles) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
            }
            .help("添加上下文、文件或目录 (@)")
            #endif

            Button(action: beginGoalEdit) {
                Image(systemName: model.goal == nil ? "target" : "target.fill")
                    .font(.system(size: 14))
            }
            .help(model.goal == nil ? "设定执行目标 (/goal)" : "已设定目标: \(model.goal ?? "")")
            .popover(isPresented: $isEditingGoal, arrowEdge: .top) {
                GoalEditor(draft: $goalDraft) { value in
                    runtime.setGoal(value)
                    isEditingGoal = false
                }
            }

            Menu {
                Picker("权限", selection: $model.permissionPreset) {
                    ForEach(PermissionPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.permissionPreset.shortLabel,
                      systemImage: model.permissionPreset.isElevated ? "exclamationmark.shield" : "lock.shield")
                    .font(.lxMeta)
                    .foregroundStyle(model.permissionPreset.isElevated ? Color.orange : Color.secondary)
            }
            .composerMenu(help: "权限模式：\(model.permissionPreset.label)")

            Spacer(minLength: LingXiMetrics.Space.sm)

            // MARK: - Right status and execution settings
            Menu {
                Picker("思考等级", selection: $model.reasoningEffort) {
                    ForEach(model.availableReasoningLevels, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.reasoningEffort.rawValue, systemImage: "sparkles").font(.lxMeta)
            }
            .composerMenu(help: "思考等级（按当前模型支持能力）")

            Menu {
                Picker("模型", selection: Binding(get: { model.selectedModelID ?? "" },
                                                 set: { model.selectedModelID = $0.isEmpty ? nil : $0 })) {
                    ForEach(configuredModels, id: \.id) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .pickerStyle(.inline)
                if configuredModels.isEmpty {
                    Text("Core 未返回可用模型")
                }
            } label: {
                Label(modelLabel, systemImage: "cpu").font(.lxMeta)
            }
            .composerMenu(help: "选择模型（更多 Provider 请前往设置）")

            Menu {
                Picker("模式", selection: $model.selectedMode) {
                    ForEach(AgentRunMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.selectedMode.rawValue, systemImage: modeSymbol).font(.lxMeta)
            }
            .composerMenu(help: "模式：Build 执行改动，Plan 只规划，Explore 只读探索")

            sendOrStop
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }

    private var configuredModels: [ProviderModelInfo] {
        model.models.filter(\.configured)
    }

    private var modelLabel: String {
        guard let id = model.selectedModelID else { return "模型" }
        return model.models.first { $0.id == id || $0.modelID == id }?.displayName ?? id
    }

    private var modeSymbol: String {
        switch model.selectedMode {
        case .build: return "hammer"
        case .plan: return "list.bullet.rectangle"
        case .explore: return "binoculars"
        }
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if isGenerating {
            Button(action: runtime.stopGenerating) {
                Label("停止", systemImage: "stop.fill").labelStyle(.iconOnly)
            }
            .lxGlassButtonStyle()
            .buttonBorderShape(.circle)
            .lxNeonGlow(color: LingXiTheme.foxfireAmber, radius: 8, opacity: 0.65)
            .keyboardShortcut(".", modifiers: .command)
            .help("停止 (⌘.)")
        } else {
            Button(action: submit) {
                Label("发送", systemImage: "paperplane.fill").labelStyle(.iconOnly).fontWeight(.semibold)
            }
            .lxPrimaryButtonStyle()
            .buttonBorderShape(.circle)
            .lxNeonGlow(color: isEmpty ? .clear : LingXiTheme.foxfireAmber, radius: 6, opacity: 0.45)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEmpty)
            .help(sendKey == .returnKey ? "发送 (⏎)" : "发送 (⌘⏎)")
        }
    }

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !isEmpty, !isGenerating || model.text.hasPrefix("/") else { return }
        runtime.sendMessage(text: model.text, mode: model.selectedMode, attachments: model.attachments)
    }

    private func beginGoalEdit() {
        goalDraft = model.goal ?? ""
        isEditingGoal = true
    }

    /// Files are referenced as `@path`: the turn protocol's attachment slot needs
    /// uploaded ContentRefs, which the frontend does not own yet.
    private func insertFileReferences(_ urls: [URL]) {
        let refs = urls.filter(\.isFileURL).map { "@" + $0.path }
        guard !refs.isEmpty else { return }
        let separator = model.text.isEmpty || model.text.hasSuffix(" ") || model.text.hasSuffix("\n") ? "" : " "
        model.text += separator + refs.joined(separator: " ") + " "
    }

    #if os(macOS)
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "引用"
        if panel.runModal() == .OK {
            insertFileReferences(panel.urls)
        }
    }
    #endif
}

private extension View {
    func composerMenu(help: String) -> some View {
        self.menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, LingXiMetrics.Space.xs + 2)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .help(help)
    }
}

private struct GoalChip: View {
    let goal: String
    var onEdit: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Image(systemName: "target").foregroundStyle(.tint)
            Button(action: onEdit) {
                Text(goal).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.plain)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除目标")
        }
        .font(.lxMeta)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前目标：\(goal)")
    }
}

private struct GoalEditor: View {
    @Binding var draft: String
    var onCommit: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            Text("任务目标").font(.lxCallout.weight(.semibold))
            TextField("交付物与验收标准", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .frame(width: 320)
                .onSubmit { onCommit(draft) }
            HStack {
                Button("清除") { onCommit(nil) }
                Spacer()
                Button("设定") { onCommit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.lg)
    }
}

#endif
