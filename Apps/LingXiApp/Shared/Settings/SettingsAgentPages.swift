#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// MARK: - Providers

struct ProvidersSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var pendingRemoval: ProviderAccountInfo?

    var body: some View {
        if let status = store.providerStatus {
            Section("当前状态") {
                ValueRow(title: "已配置", value: status.configured ? "是" : "否")
                if let model = status.model { ValueRow(title: "当前模型", value: model, monospaced: true) }
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
                PlaceholderLine("Core 未发现 Provider 账户。在 providers.json 中添加后点「重新发现」。")
            }
            ForEach(store.providers, id: \.id) { account in
                ProviderRow(account: account, test: store.providerTests[account.id],
                            onTest: { Task { await store.testProvider(account.id) } },
                            onRemove: { pendingRemoval = account })
                    .settingsAnchor("provider.\(account.id)")
            }
        } header: {
            HStack {
                Text("账户")
                Spacer()
                Button("重新发现") { Task { await store.reloadProviders() } }
                    .disabled(store.client == nil)
                    .settingsAnchor("providers.reload")
            }
        } footer: {
            Text("凭据由 Core 的 CredentialBroker 保存，此处只显示引用，不回显密钥。")
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
}

private struct ProviderRow: View {
    let account: ProviderAccountInfo
    let test: TestProviderResult?
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
            if let test {
                Label(test.reachable ? test.latencyMs.map { String(format: "%.0f ms", $0) } ?? "可达" : (test.message ?? "不可达"),
                      systemImage: test.reachable ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(test.reachable ? Color.secondary : Color.red)
            } else {
                Text(account.availability).font(.caption).foregroundStyle(.secondary)
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
}

// MARK: - Models

struct ModelsSettingsPage: View {
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
        } footer: {
            Text("模型目录由 Core 从各 Provider 动态发现，不在界面里写死。")
        }

        Section("模型目录") {
            if store.client != nil && store.models.isEmpty {
                PlaceholderLine("Core 尚未返回模型目录。")
            }
            ForEach(store.models, id: \.id) { model in
                ModelRow(model: model, isSelected: model.modelID == store.modelSelection?.modelID)
                    .settingsAnchor("model.\(model.id)")
            }
        }
        .settingsAnchor("models.catalog")
    }
}

private struct ModelRow: View {
    let model: ProviderModelInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(model.displayName)
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                            .accessibilityLabel("当前默认")
                    }
                }
                Text("\(model.providerID) · \(model.modelID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Self.tokens(model.contextWindow))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("上下文窗口 / 最大输出 \(Self.tokens(model.maxOutputTokens))")
            if model.reasoning {
                Image(systemName: "brain").foregroundStyle(.secondary).help("支持推理")
            }
            if !model.configured {
                Text("未配置").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : "\(n / 1000)k"
    }
}

// MARK: - Agent defaults

struct AgentDefaultsSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
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
                ValueRow(title: "L1 目标 / 软限 / 硬限",
                         value: "\(tokens(policy.l1Target)) / \(tokens(policy.l1SoftLimit)) / \(tokens(policy.l1HardLimit))")
                ValueRow(title: "L2 上限", value: tokens(policy.l2Max))
                ValueRow(title: "L3 容量", value: tokens(policy.l3Capacity))
                ValueRow(title: "经济阈值", value: policy.economicThreshold.map(tokens) ?? "未启用")
            } header: {
                Text("当前生效策略")
            } footer: {
                Text("由 Core 按当前模型窗口解析后的实际值；下方为全局配置。")
            }
            .settingsAnchor("context.live")
        }

        Section("预算") {
            ConfigNumberField(title: "可寻址预算", unit: "tokens", key: ConfigKeys.addressableBudget, store: store)
            ConfigNumberField(title: "保留余量", info: "为输出与工具结果预留、不参与上下文填充的 token。",
                              unit: "tokens", key: ConfigKeys.reserve, store: store)
            ConfigNumberField(title: "经济阈值", info: "超过此值时优先压缩而非继续扩充上下文，避免跨入更高计费档。",
                              unit: "tokens", key: ConfigKeys.economicThreshold, store: store)
        }
        .settingsAnchor("context.budget")

        Section("分层") {
            ConfigNumberField(title: "L1 目标", unit: "tokens", key: ConfigKeys.l1Target, store: store)
            ConfigNumberField(title: "L1 软限", unit: "tokens", key: ConfigKeys.l1SoftLimit, store: store)
            ConfigNumberField(title: "L1 硬限", unit: "tokens", key: ConfigKeys.l1HardLimit, store: store)
            ConfigNumberField(title: "L2 上限", unit: "tokens", key: ConfigKeys.l2Max, store: store)
            ConfigToggle(title: "L3 使用剩余预算", key: ConfigKeys.l3UseRemaining, store: store)
        }
        .settingsAnchor("context.layers")

        Section("Context Fabric") {
            ConfigToggle(title: "E-Core 对象存储", info: "把大体积工具结果对象化存储，时间线只保留占位。",
                         key: ConfigKeys.ecoreStorage, store: store)
            ConfigToggle(title: "观察投影", key: ConfigKeys.observationProjection, store: store)
            ConfigToggle(title: "热度追踪", info: "按访问热度决定上下文淘汰顺序。", key: ConfigKeys.heatTracking, store: store)
        }
        .settingsAnchor("context.fabric")
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
