#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// MARK: - Modality Badges

private struct ModalityBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
            .foregroundStyle(color)
    }
}

private func modalityColor(for mod: String) -> Color {
    switch mod {
    case "Vision": return LingXiTheme.electricPurple
    case "Reasoning": return LingXiTheme.foxfireAmber
    case "Tools": return LingXiTheme.auroraMint
    default: return LingXiTheme.electricCyan
    }
}

// MARK: - Providers

struct ProvidersSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var pendingRemoval: ProviderAccountInfo?
    @State private var expandedProviders: Set<String> = []

    var body: some View {
        if let status = store.providerStatus {
            Section("当前状态") {
                ValueRow(title: "已配置", value: status.configured ? "是" : "否")
                if let model = status.model { ValueRow(title: "当前活跃模型", value: model, monospaced: true) }
                if let base = status.baseURL { ValueRow(title: "Endpoint", value: base, monospaced: true) }
                if !status.missingRequirements.isEmpty {
                    Label("缺少：\(status.missingRequirements.joined(separator: "、"))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }

                Section {
                    if store.client != nil && store.providers.isEmpty {
                        PlaceholderLine("Core 尚未配置 Provider 账户。可在 providers.json 中配置或通过登录关联。")
                    }
                    ForEach(store.providers, id: \.id) { account in
                        VStack(spacing: 0) {
                            ProviderRow(
                                account: account,
                                test: store.providerTests[account.id],
                                isExpanded: expandedProviders.contains(account.id),
                                onToggleExpand: {
                                    if expandedProviders.contains(account.id) {
                                        expandedProviders.remove(account.id)
                                    } else {
                                        expandedProviders.insert(account.id)
                                    }
                                },
                                onTest: { Task { await store.testProvider(account.id) } },
                                onRemove: { pendingRemoval = account }
                            )

                            // 展开的真实 Core 模型列表 (Provider Account Discovery ∩ models.json metadata)
                            if expandedProviders.contains(account.id) {
                                let providerModels = store.models.filter { $0.providerID == account.id || $0.providerID == account.productID }
                                VStack(spacing: 6) {
                                    Divider().padding(.vertical, 4)
                                    if providerModels.isEmpty {
                                        HStack {
                                            Text("该提供商已连接，可通过 /v1/models 或模型目录发现模型。")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                            Spacer()
                                        }
                                        .padding(.leading, 24)
                                    } else {
                                        ForEach(providerModels, id: \.id) { model in
                                            ExpandableModelSubRow(
                                                model: model,
                                                isSelected: model.modelID == (store.modelSelection?.modelID ?? store.preferences.lastModelID),
                                                onSelect: {
                                                    Task { await store.selectDefaultModel(model.modelID) }
                                                }
                                            )
                                            .padding(.leading, 20)
                                        }
                                    }
                                }
                                .padding(.bottom, 6)
                            }
                        }
                        .settingsAnchor("provider.\(account.id)")
                    }
                } header: {
                    HStack {
                        Text("已连接提供商账户 (Connected Providers)")
                        Spacer()
                        Button("重新发现") { Task { await store.reloadProviders() } }
                            .disabled(store.client == nil)
                            .settingsAnchor("providers.reload")
                    }
                } footer: {
                    Text("模型元数据权威来自 models.lingxifox.cn 官方实时索引，账户可访问性由 Provider Discovery 动态确认。")
                }
                .settingsAnchor("providers.list")
        .confirmationDialog("移除 Provider 账户？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { account in
            Button("移除 \(account.displayName)", role: .destructive) {
                Task { await store.removeProvider(account.id) }
            }
        } message: { account in
            Text("\(account.displayName) 将从 Core 的账户列表中移除，依赖它的模型将不可用。")
        }
    }

    static func formatTokens(_ n: Int) -> String {
        guard n > 0 else { return "待同步" }
        return n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : "\(n / 1000)k"
    }
}

private struct ExpandableModelSubRow: View {
    let model: ProviderModelInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.caption.weight(.semibold))
                    if isSelected {
                        Label("当前默认", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LingXiTheme.auroraMint)
                    }
                }
                HStack(spacing: 4) {
                    Text(model.modelID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    ModalityBadge(title: "Text", color: LingXiTheme.neonCyan)
                    if model.reasoning {
                        ModalityBadge(title: "Reasoning", color: LingXiTheme.foxfireAmber)
                    }
                    if model.vision {
                        ModalityBadge(title: "Vision", color: LingXiTheme.astralViolet)
                    }
                    if model.toolCalling {
                        ModalityBadge(title: "Tools", color: LingXiTheme.auroraMint)
                    }
                }
            }

            Spacer(minLength: 0)

            if model.metadataIncomplete || model.contextWindow == 0 {
                Text("元数据待同步")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ProvidersSettingsPage.formatTokens(model.contextWindow))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.primary)
                    if model.maxOutputTokens > 0 {
                        Text("Max \(ProvidersSettingsPage.formatTokens(model.maxOutputTokens))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !isSelected {
                Button("设为默认", action: onSelect)
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ProviderRow: View {
    let account: ProviderAccountInfo
    let test: TestProviderResult?
    let isExpanded: Bool
    var onToggleExpand: () -> Void
    var onTest: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(account.displayName).font(.body.weight(.medium))
                    Text(account.accountType.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(account.endpoint ?? account.productID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)

            Button(action: onToggleExpand) {
                HStack(spacing: 4) {
                    Text("模型列表")
                        .font(.caption2.weight(.medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(LingXiTheme.electricCyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)

            if let test {
                Label(test.reachable ? test.latencyMs.map { String(format: "%.0f ms", $0) } ?? "可达" : (test.message ?? "不可达"),
                      systemImage: test.reachable ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(test.reachable ? Color.secondary : Color.red)
            } else {
                providerStatusBadge(account: account)
            }

            Menu {
                Button("测试连接", action: onTest)
                Divider()
                Button("移除…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(account.displayName) 操作")
        }
    }

    @ViewBuilder
    private func providerStatusBadge(account: ProviderAccountInfo) -> some View {
        let isOAuth = account.accountType == .oauthUser || account.availability == "reauthenticationRequired" || account.availability == "refresh_failed" || account.availability == "refreshing" || account.availability == "active"
        if isOAuth {
            if account.availability == "reauthenticationRequired" || account.availability.contains("撤销") || account.availability.contains("失效") {
                Label("凭据已失效 (需重新登录)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            } else if account.availability == "refresh_failed" || account.availability.contains("刷新失败") {
                Label("RT 刷新失败 (可重试)", systemImage: "arrow.clockwise.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else if account.availability == "refreshing" || account.availability.contains("刷新中") {
                Label("AT 自动刷新中…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LingXiTheme.electricCyan)
            } else {
                Label("OAuth 活跃 (自动刷新)", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LingXiTheme.auroraMint)
            }
        } else {
            Text(account.availability)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Agent defaults

struct AgentDefaultsSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            Picker("默认模型", selection: Binding(
                get: { store.modelSelection?.modelID ?? store.preferences.lastModelID ?? "" },
                set: { id in Task { await store.selectDefaultModel(id) } }
            )) {
                if store.models.isEmpty { Text("—").tag("") }
                ForEach(store.models.filter(\.configured), id: \.modelID) { model in
                    Text(model.displayName).tag(model.modelID)
                }
            }
            .disabled(store.models.isEmpty)
            .settingsAnchor("models.default")
        } header: {
            Text("新会话默认模型")
        } footer: {
            Text("新会话启动时默认启用的模型。元数据来自 models.lingxifox.cn 官方实时索引，可用性由 Provider 发现决定。")
        }

        Section("新任务默认") {
            ConfigPicker(title: "行为模式", info: "新会话 Composer 的初始模式。Plan 只规划不改动，Explore 只读探索。",
                         key: ConfigKeys.behaviorProfile, options: [
                ("build", "Build"), ("plan", "Plan"), ("explore", "Explore"),
            ], store: store)

            Picker(selection: Binding(get: { store.defaultReasoning },
                                      set: { store.setDefaultReasoning($0) })) {
                ForEach(ReasoningEffortLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("思考强度")
                    InfoHint("模型不支持的档位由 Core 映射到最近的可用档位。")
                }
            }
            .settingsAnchor("agent.reasoning")

            ConfigNumberField(title: "单轮最大步数", info: "一次回合内 Agent 循环的步数上限。",
                              key: ConfigKeys.maxAgentLoopSteps, store: store)
        }

        Section("子 Agent") {
            ConfigNumberField(title: "最大并发", key: ConfigKeys.maxConcurrentSubagents, store: store)
            ConfigNumberField(title: "最大嵌套深度", key: ConfigKeys.maxSubagentDepth, store: store)
            ConfigNumberField(title: "单个根任务总运行数", key: ConfigKeys.maxTotalRuns, store: store)
        }
        .settingsAnchor("agent.subagents")

        Section("项目指令") {
            ConfigNumberField(title: "L1 项目指令上限", info: "AGENTS.md 等项目级指令进入常驻上下文的字符上限。",
                              unit: "字符", key: ConfigKeys.l1ProjectMaxCharacters, store: store)
            ConfigNumberField(title: "L2 文档上限", unit: "字符", key: ConfigKeys.l2MaxCharacters, store: store)
        }

        SystemContextEditor(store: store)
    }
}

/// Edited as a draft and saved explicitly, so config.json is not rewritten per keystroke.
private struct SystemContextEditor: View {
    @ObservedObject var store: SettingsStore
    @State private var draft = ""

    var body: some View {
        Section {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("系统上下文")
            HStack {
                Spacer()
                Button("保存") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        store.resetConfig(ConfigKeys.systemContext)
                    } else {
                        store.binding(ConfigKeys.systemContext).wrappedValue = draft
                    }
                }
                .disabled(draft == store.config(ConfigKeys.systemContext))
            }
        } header: {
            ConfigLabel(title: "系统上下文", info: "追加到每个会话系统提示之后的全局说明。留空即不追加。",
                        key: ConfigKeys.systemContext, store: store)
        }
        .settingsAnchor(ConfigKeys.systemContext.id)
        .onAppear { draft = store.config(ConfigKeys.systemContext) }
    }
}

// MARK: - Permissions

struct PermissionsSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            ConfigPicker(title: "审批策略", key: ConfigKeys.permissionPolicy, options: [
                ("ask", "每次询问"), ("auto", "自动批准"),
            ], store: store)
            ConfigPicker(title: "访问范围", key: ConfigKeys.executionProfile, options: [
                ("readOnly", "只读"), ("workspace", "工作区"), ("fullAccess", "完全访问"),
            ], store: store)
            .pickerStyle(.segmented)
        } header: {
            Text("默认权限")
        } footer: {
            if store.config(ConfigKeys.executionProfile) == "fullAccess" {
                Label(store.config(ConfigKeys.permissionPolicy) == "auto"
                      ? "自动批准 + 完全访问即 YOLO：Agent 可不经确认修改工作区外的任何文件并执行任意命令。"
                      : "完全访问允许 Agent 读写工作区以外的路径，每次仍会请求你确认。",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("启动时从 config.json 读取。命令行 -y / --yolo 优先于此设置。")
            }
        }

        Section {
            LabeledContent {
                Button("应用") { Task { await store.applyPermissionToCore() } }
                    .disabled(store.client == nil)
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("应用到当前 Core")
                    InfoHint("不等重启，立即把上面的组合推送给正在运行的 Core。")
                }
            }
            .settingsAnchor("permissions.apply")
        }

        Section {
            let policy = store.composerDefaults.permission.configuration.approvalPolicy
            ApprovalRow(title: "安全读取", decision: policy.safeRead)
            ApprovalRow(title: "工作区写入", decision: policy.workspaceMutation)
            ApprovalRow(title: "进程执行", decision: policy.processExecution)
            ApprovalRow(title: "外部读取", decision: policy.externalRead)
            ApprovalRow(title: "外部写入", decision: policy.externalMutation)
            ApprovalRow(title: "敏感访问", decision: policy.sensitiveAccess)
        } header: {
            Text("审批矩阵")
        } footer: {
            Text("上面组合对应 Core 的冻结权限预设，逐类决定允许、询问或拒绝。自定义规则需要 Core 提供规则契约后开放。")
        }
        .settingsAnchor("permissions.matrix")

        Section {
            ValueRow(title: "凭据", value: "由 CredentialBroker 持有，不下发给子 Agent 或 MCP")
            ValueRow(title: "子 Agent 授权", value: "只能单调收窄于父集（child ⊆ parent）")
        } header: {
            Text("固定边界")
        } footer: {
            Text("以上由 Core 强制执行，不提供开关。")
        }
    }
}

private struct ApprovalRow: View {
    let title: String
    let decision: ApprovalDecision

    var body: some View {
        LabeledContent(title) {
            Label(label, systemImage: symbol)
                .foregroundStyle(tint)
        }
    }

    private var label: String {
        switch decision {
        case .allow: return "允许"
        case .ask: return "询问"
        case .deny: return "拒绝"
        default: return "\(decision)"
        }
    }

    private var symbol: String {
        switch decision {
        case .allow: return "checkmark.circle"
        case .ask: return "questionmark.circle"
        default: return "xmark.circle"
        }
    }

    private var tint: AnyShapeStyle {
        switch decision {
        case .allow: return AnyShapeStyle(.secondary)
        case .ask: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.tertiary)
        }
    }
}

// MARK: - Code intelligence

struct CodeIntelligenceSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            ConfigToggle(title: "代码智能工具", info: "启用符号查找、定义、引用与依赖查询等代码图谱工具。",
                         key: ConfigKeys.codeIntelligence, store: store)
        } footer: {
            Text("关闭后 Agent 只用 grep / glob 等文本检索。")
        }

        Section("项目索引") {
            if let workspace = store.workspace {
                ValueRow(title: "索引状态", value: workspace.indexingState ?? "—")
                ValueRow(title: "图谱节点", value: workspace.codebaseNodes.map { "\($0)" } ?? "—")
                ValueRow(title: "图谱关系", value: workspace.codebaseEdges.map { "\($0)" } ?? "—")
            } else {
                PlaceholderLine(store.client == nil ? "连接 Core 后显示当前工作区的索引状态。" : "Core 未返回工作区索引信息。")
            }
        }
        .settingsAnchor("code.index")

        Section {
            PlaceholderLine("各语言 LSP、Formatter 与诊断的运行状态需要 Core 提供前端数据契约，暂不展示。")
        } header: {
            Text("语言服务")
        }
    }
}

// MARK: - Context

struct ContextSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        if let policy = store.contextPolicy {
            Section {
                ValueRow(title: "模型窗口", value: tokens(policy.modelWindow))
                ValueRow(title: "可寻址预算", value: tokens(policy.addressableBudget))
                ValueRow(title: "P-Core 目标 / 软限 / 硬限",
                         value: "\(tokens(policy.pCoreTarget)) / \(tokens(policy.pCoreSoftLimit)) / \(tokens(policy.pCoreHardLimit))")
                ValueRow(title: "E-Core 存储预算", value: tokens(policy.eCoreStorageBudget))
                ValueRow(title: "E-Core 召回预算", value: tokens(policy.eCoreRecallBudget))
                ValueRow(title: "E-Core 压力保护阈值", value: String(format: "%.0f%%", policy.eCorePressureThreshold * 100))
                ValueRow(title: "经济阈值", value: policy.economicThreshold.map(tokens) ?? "未启用")
            } header: {
                Text("当前生效策略 (Dual-Core Snapshot)")
            } footer: {
                Text("由 Core 按当前模型窗口与双核策略计算后的实际工作值；下方为全局双核配置。")
            }
            .settingsAnchor("context.live")
        }

        Section("预算基线") {
            ConfigNumberField(title: "可寻址预算", unit: "tokens", key: ConfigKeys.addressableBudget, store: store)
            ConfigNumberField(title: "保留余量", info: "为输出与工具结果预留、不参与上下文填充的 token。",
                              unit: "tokens", key: ConfigKeys.reserve, store: store)
            ConfigNumberField(title: "经济阈值", info: "超过此值时优先压缩而非继续扩充上下文，避免跨入更高计费档。",
                              unit: "tokens", key: ConfigKeys.economicThreshold, store: store)
        }
        .settingsAnchor("context.budget")

        Section("P-Core 实时工作集 (Primary Working Set)") {
            ConfigNumberField(title: "P-Core 目标工作集", unit: "tokens", key: ConfigKeys.pCoreTarget, store: store)
            ConfigNumberField(title: "P-Core 软限制 (Soft Limit)", info: "超过软限时触发非关键上下文降权淘汰与对象化流出。",
                              unit: "tokens", key: ConfigKeys.pCoreSoftLimit, store: store)
            ConfigNumberField(title: "P-Core 硬限制 (Hard Limit)", info: "绝对硬上限，超过时强制阻断或深度截断以保护 Prefix Cache。",
                              unit: "tokens", key: ConfigKeys.pCoreHardLimit, store: store)
        }
        .settingsAnchor("context.pcore")

        Section("E-Core 对象与召回织网 (Context Fabric)") {
            ConfigNumberField(title: "E-Core 存储预算", info: "外延对象存储的容量上限，超限时触发冷热分级淘汰。",
                              unit: "tokens", key: ConfigKeys.eCoreStorageBudget, store: store)
            ConfigNumberField(title: "E-Core 召回预算", info: "单次回合中自外延存储召回注入的最大 token 数。",
                              unit: "tokens", key: ConfigKeys.eCoreRecallBudget, store: store)
            ConfigToggle(title: "E-Core 对象存储", info: "把大体积工具结果对象化存储，时间线只保留占位并按需召回。",
                         key: ConfigKeys.ecoreStorage, store: store)
            ConfigToggle(title: "观察投影 (Observation Projection)", info: "将大体积多模态或命令输出结构化为紧凑观察摘要。",
                         key: ConfigKeys.observationProjection, store: store)
            ConfigToggle(title: "访问热度追踪", info: "按访问热度决定上下文淘汰与召回优先顺序。",
                         key: ConfigKeys.heatTracking, store: store)
        }
        .settingsAnchor("context.ecore")
    }

    private func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

// MARK: - Execution

struct ExecutionSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section {
            ConfigSecondsField(title: "前台命令", key: ConfigKeys.foregroundShellSeconds, store: store)
            ConfigSecondsField(title: "快速文件操作", key: ConfigKeys.quickFilesystemSeconds, store: store)
            ConfigSecondsField(title: "搜索", key: ConfigKeys.searchSeconds, store: store)
            ConfigSecondsField(title: "构建与测试", key: ConfigKeys.buildTestSeconds, store: store)
            ConfigSecondsField(title: "MCP 调用", key: ConfigKeys.mcpSeconds, store: store)
        } header: {
            Text("工具时限")
        } footer: {
            Text("超时后 Core 终止对应进程并把超时作为工具结果返回给 Agent。")
        }
        .settingsAnchor("execution.budgets")

        Section("模型与运行") {
            ConfigSecondsField(title: "Provider 请求", key: ConfigKeys.providerSeconds, store: store)
            ConfigSecondsField(title: "Provider 流空闲", info: "流式响应无新数据超过此时长即视为中断。",
                               key: ConfigKeys.providerIdleSeconds, store: store)
            ConfigSecondsField(title: "子 Agent", key: ConfigKeys.subagentSeconds, store: store)
            ConfigSecondsField(title: "单次 Agent 运行", key: ConfigKeys.agentRunSeconds, store: store)
            ConfigSecondsField(title: "绝对上限", info: "任何单项时限都不会超过此值。", key: ConfigKeys.maximumSeconds, store: store)
        }
    }
}

#endif
