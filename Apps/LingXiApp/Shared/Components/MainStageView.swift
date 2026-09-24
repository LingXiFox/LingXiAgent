#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

/// macOS 原生主舞台 (Main Stage)
/// 包含顶部 TaskControlBar、三视图分发 (Plan / Action Flow / Final Report) 以及底部 Composer
public struct MainStageView: View {
    @ObservedObject public var conversationModel: ConversationPresentationModel
    @ObservedObject public var composerModel: ComposerModel
    public var onSendMessage: (String, AgentRunMode, [AttachmentPresentation]) -> Void
    public var onStopGenerating: () -> Void
    public var onResolveInteraction: (String, Bool) -> Void
    public var onFinalizeTask: (TaskFinalizeAction) -> Void

    public init(
        conversationModel: ConversationPresentationModel,
        composerModel: ComposerModel,
        onSendMessage: @escaping (String, AgentRunMode, [AttachmentPresentation]) -> Void,
        onStopGenerating: @escaping () -> Void,
        onResolveInteraction: @escaping (String, Bool) -> Void,
        onFinalizeTask: @escaping (TaskFinalizeAction) -> Void
    ) {
        self.conversationModel = conversationModel
        self.composerModel = composerModel
        self.onSendMessage = onSendMessage
        self.onStopGenerating = onStopGenerating
        self.onResolveInteraction = onResolveInteraction
        self.onFinalizeTask = onFinalizeTask
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部任务控制条
            TaskControlBar(
                activeTask: conversationModel.activeTask,
                selectedTab: $conversationModel.stageTab,
                onFinalize: onFinalizeTask
            )

            Divider()

            // 主展示区三视图分发
            Group {
                switch conversationModel.stageTab {
                case .plan:
                    TaskPlanView(task: conversationModel.activeTask)
                case .actionFlow:
                    ActionFlowTimelineView(
                        items: conversationModel.items,
                        isGenerating: conversationModel.isGenerating,
                        onResolveInteraction: onResolveInteraction
                    )
                case .report:
                    TaskFinalReportView(
                        task: conversationModel.activeTask,
                        onFinalize: onFinalizeTask
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 底部原生 Composer
            MainComposerBar(
                model: composerModel,
                isGenerating: conversationModel.isGenerating,
                onSend: { text, mode, atts in
                    onSendMessage(text, mode, atts)
                },
                onStop: onStopGenerating
            )
        }
        .background(LingXiTheme.windowBackground)
    }
}

// MARK: - Task Control Bar

public struct TaskControlBar: View {
    public let activeTask: TaskPresentation?
    @Binding public var selectedTab: TaskStageViewTab
    public var onFinalize: (TaskFinalizeAction) -> Void

    public var body: some View {
        HStack(spacing: 12) {
            if let task = activeTask {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.objective)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        TaskStatusBadge(state: task.state)
                    }

                    if let branch = task.worktreeBranch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                            Text("Worktree: \(branch)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(LingXiTheme.secondaryText)
                    }
                }
            } else {
                Text("无活跃任务")
                    .font(.subheadline)
                    .foregroundColor(LingXiTheme.secondaryText)
            }

            Spacer()

            // Plan / Action Flow / Final Report 三段切换
            Picker("", selection: $selectedTab) {
                ForEach(TaskStageViewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            // 收尾动作菜单
            Menu {
                Button("接受本次变更 (Accept)") {
                    onFinalize(.accept)
                }
                Button("放弃并回滚 (Discard)", role: .destructive) {
                    onFinalize(.discard)
                }
                Button("标记已完成 (Finish)") {
                    onFinalize(.finish)
                }
            } label: {
                Label("任务收尾", systemImage: "flag.checkered")
            }
            .menuStyle(.borderedButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LingXiTheme.surfaceBackground)
    }
}

// MARK: - Action Flow Timeline View

public struct ActionFlowTimelineView: View {
    public let items: [TimelineItemPresentation]
    public let isGenerating: Bool
    public var onResolveInteraction: (String, Bool) -> Void

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        TimelineRow(item: item, onResolveInteraction: onResolveInteraction)
                            .id(item.id)
                    }

                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("思考与执行中…")
                                .font(.caption)
                                .foregroundColor(LingXiTheme.secondaryText)
                        }
                        .padding(.vertical, 8)
                        .id("bottom-anchor")
                    }
                }
                .padding(20)
            }
            .onChange(of: items.count) {
                if let lastID = items.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }

        }
    }
}

private struct TimelineRow: View {
    let item: TimelineItemPresentation
    let onResolveInteraction: (String, Bool) -> Void

    var body: some View {
        switch item.kind {
        case let .user(content, attachments):
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer()
                    Text(content)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(LingXiTheme.surfaceBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        Spacer()
                        ForEach(attachments) { att in
                            Label(att.filename, systemImage: att.thumbnailSymbol)
                                .font(.caption)
                                .padding(4)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }

        case let .thinking(content, isExpanded, duration, tokens):
            DisclosureGroup(
                isExpanded: .constant(isExpanded),
                content: {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(LingXiTheme.secondaryText)
                        .padding(.top, 4)
                },
                label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .font(.system(size: 11))
                            .foregroundColor(LingXiTheme.accentColor)
                        Text(String(format: "思考过程 (%.1fs, %d tokens)", duration, tokens))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(LingXiTheme.secondaryText)
                    }
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LingXiTheme.surfaceBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case let .assistant(content, _):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundColor(LingXiTheme.accentColor)
                    .font(.system(size: 14))
                    .padding(.top, 2)

                Text(content)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }

        case let .interaction(card):
            InlineInteractionCard(card: card, onResolve: onResolveInteraction)

        case let .diff(filePath, diffContent):
            GroupBox(label: Label(filePath, systemImage: "doc.badge.gearshape")) {
                #if os(macOS)
                MacNativeTextView(
                    text: .constant(diffContent),
                    isEditable: false,
                    isMonospace: true
                )
                .frame(minHeight: 120, maxHeight: 300)
                #else
                Text(diffContent)
                    .font(.system(size: 11, design: .monospaced))
                #endif
            }

        case let .tool(_, toolName, summary, status, output):
            DisclosureGroup {
                if let out = output {
                    Text(out)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(Color.black.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                    Text("调用: \(toolName)")
                        .font(.system(size: 12, weight: .medium))
                    Text("— \(summary)")
                        .font(.system(size: 11))
                        .foregroundColor(LingXiTheme.secondaryText)
                    Spacer()
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(LingXiTheme.secondaryText)
                }
            }
            .padding(8)
            .background(LingXiTheme.surfaceBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case let .terminal(title, isSuccess, message):
            HStack(spacing: 8) {
                Image(systemName: isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundColor(isSuccess ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.bold())
                    Text(message).font(.caption2)
                }
            }
            .padding(8)
            .background(isSuccess ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Inline HITL Interaction Card

public struct InlineInteractionCard: View {
    public let card: InteractionCardPresentation
    public var onResolve: (String, Bool) -> Void

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("权限审批请求", systemImage: "shield.lefthalf.filled")
                        .font(.subheadline.bold())
                        .foregroundColor(LingXiTheme.accentColor)

                    Spacer()

                    Text("发起方: \(card.agentRunID)")
                        .font(.caption2)
                        .foregroundColor(LingXiTheme.secondaryText)
                }

                Text("请求执行工具：\(card.toolName)")
                    .font(.body.weight(.medium))

                Text(card.parametersSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    Spacer()
                    if card.status == .pending {
                        Button("拒绝", role: .destructive) {
                            onResolve(card.interactionID, false)
                        }
                        .keyboardShortcut(.escape, modifiers: [])

                        Button("批准执行") {
                            onResolve(card.interactionID, true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LingXiTheme.accentColor)
                    } else {
                        Text(card.status == .approved ? "已批准" : "已拒绝")
                            .font(.caption.bold())
                            .foregroundColor(card.status == .approved ? .green : .red)
                    }
                }
            }
            .padding(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限审批请求: \(card.toolName)")
    }
}

// MARK: - Plan View

public struct TaskPlanView: View {
    public let task: TaskPresentation?

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let task = task {
                    // 目标与条件
                    GroupBox(label: Label("目标与成功准则 (Success Criteria)", systemImage: "target")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.objective)
                                .font(.body.bold())

                            Divider()

                            ForEach(task.criteria, id: \.criterionID) { criterion in
                                HStack(spacing: 8) {
                                    Image(systemName: criterion.isSatisfied ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(criterion.isSatisfied ? .green : .secondary)
                                    Text(criterion.description)
                                        .font(.subheadline)
                                    Spacer()
                                }
                            }

                        }
                        .padding(6)
                    }

                    // 阶段计划
                    GroupBox(label: Label("阶段执行计划 (Task Plan)", systemImage: "list.bullet.indent")) {
                        if let plan = task.plan, !plan.phases.isEmpty {
                            ForEach(plan.phases) { phase in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(phase.name)
                                            .font(.headline)
                                        Spacer()
                                        Text(phase.status)
                                            .font(.caption2)
                                            .foregroundColor(LingXiTheme.secondaryText)
                                    }
                                    ForEach(phase.steps, id: \.self) { step in
                                        HStack(spacing: 6) {
                                            Circle().frame(width: 4, height: 4).foregroundColor(LingXiTheme.secondaryText)
                                            Text(step).font(.caption)
                                        }
                                        .padding(.leading, 8)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } else {
                            Text("正在分析上下文并规划阶段任务…")
                                .font(.subheadline)
                                .foregroundColor(LingXiTheme.secondaryText)
                                .padding(8)
                        }
                    }
                } else {
                    Text("当前没有进行中的任务计划")
                        .foregroundColor(LingXiTheme.secondaryText)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Final Report View

public struct TaskFinalReportView: View {
    public let task: TaskPresentation?
    public var onFinalize: (TaskFinalizeAction) -> Void

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let task = task {
                    GroupBox(label: Label("任务最终报告", systemImage: "doc.plaintext")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("任务目标: \(task.objective)")
                                .font(.headline)

                            if let report = task.report {
                                Text(report.summary)
                                    .font(.body)

                                Divider()

                                Text("变更摘要:")
                                    .font(.subheadline.bold())
                                Text(report.changesSummary.isEmpty ? "已完成代码与文档变更。" : report.changesSummary)
                                    .font(.caption)

                                Text("验证结论:")
                                    .font(.subheadline.bold())
                                Text(report.verificationSummary.isEmpty ? "架构门禁与契约测试已全部通过。" : report.verificationSummary)
                                    .font(.caption)
                            } else {
                                Text("任务执行完成。已成功生成变更产物，等待收尾验收。")
                                    .font(.body)
                            }
                        }
                        .padding(8)
                    }

                    // 收尾操作卡片
                    GroupBox(label: Label("收尾验收决策", systemImage: "checkmark.seal")) {
                        HStack(spacing: 12) {
                            Button(action: { onFinalize(.accept) }) {
                                Label("接受并合并 (Accept)", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LingXiTheme.accentColor)

                            Button(action: { onFinalize(.finish) }) {
                                Label("保留工作区完成 (Finish)", systemImage: "flag")
                            }

                            Spacer()

                            Button(role: .destructive, action: { onFinalize(.discard) }) {
                                Label("放弃并清理 (Discard)", systemImage: "trash")
                            }
                        }
                        .padding(8)
                    }
                } else {
                    Text("暂无报告数据")
                        .foregroundColor(LingXiTheme.secondaryText)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Composer Bar

public struct MainComposerBar: View {
    @ObservedObject public var model: ComposerModel
    public let isGenerating: Bool
    public var onSend: (String, AgentRunMode, [AttachmentPresentation]) -> Void
    public var onStop: () -> Void

    public var body: some View {
        VStack(spacing: 8) {
            TextField("向灵犀 Agent 下达指令或提问… (⌘Enter 发送)", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .disabled(isGenerating)
                .padding(8)
                .background(LingXiTheme.surfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit {
                    if !isGenerating && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSend(model.text, model.selectedMode, model.attachments)
                    }
                }

            // 控制条：模式选择与发送/停止按钮
            HStack {
                Picker("模式", selection: $model.selectedMode) {
                    ForEach(AgentRunMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Spacer()

                if isGenerating {
                    Button(action: onStop) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                            Text("停止 (⌘.)")
                        }
                        .foregroundColor(.red)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: {
                        onSend(model.text, model.selectedMode, model.attachments)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("发送")
                        }
                        .foregroundColor(LingXiTheme.accentColor)
                    }
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LingXiTheme.surfaceBackground)
    }
}
#endif
