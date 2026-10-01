#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol
import LingXiApplication

// MARK: - Providers

/// §8.6 reference layout for a management page: page head 「已连接提供商账户」 with
/// a `.small` 「重新发现」 on the right, one hairline row per account, expandable
/// model sub-rows, and a footnote naming the metadata authority. Every value on
/// the rows comes from the live store (`providers` / `models` / `modelSelection`
/// / `providerTests`); there is no built-in provider or model list here.
struct ProvidersSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @State private var pendingRemoval: ProviderAccountInfo?
    @State private var detail: ProviderConfigurationDetail?
    @State private var isAdding = false
    @Environment(\.settingsSelection) private var selection
    @Environment(\.settingsAddTrigger) private var addTrigger
    @Environment(\.settingsSelect) private var select

    private var account: ProviderAccountInfo? {
        store.providers.first { $0.id == selection } ?? store.providers.first
    }

    var body: some View {
        LXSettingsScrollPage(title: "Provider",
                             subtitle: "管理 LingXiAgent 使用的模型服务、账户与连接状态。") {
            if let account {
                LXSettingsCard(title: EmptyView()) {
                    ProviderRow(account: account,
                                test: store.providerTests[account.id],
                                onTest: { Task { await store.testProvider(account.id) } },
                                onRemove: { pendingRemoval = account })
                }
                .settingsAnchor("provider.\(account.id)")

                if let detail, detail.providerID == account.id {
                    // providers.json entry: every field is editable.
                    ProviderConnectionEditor(store: store, detail: detail) { self.detail = $0 }
                        .id(detail.providerID)
                    ProviderModelsEditor(store: store, detail: detail) { self.detail = $0 }
                        .settingsAnchor("providers.list")
                } else {
                    // OAuth / built-in account: Core manages it, shown read-only.
                    LXSettingsCard("连接", subtitle: "此账户由登录或内置目录管理，不在 providers.json 中，因此不能在这里编辑连接。") {
                        ValueRow(title: "名称", value: account.displayName)
                        ValueRow(title: "接入方式", value: ProviderRow.accountTypeLabel(account.accountType))
                        ValueRow(title: "Base URL", value: account.endpoint ?? "Provider 默认", monospaced: account.endpoint != nil)
                    }
                    let models = store.models.filter { $0.providerID == account.id || $0.providerID == account.productID }
                    LXSettingsCard(title: HStack(spacing: LingXiMetrics.Space.xs) {
                        LXSettingsSectionHeader("模型")
                        Text("\(models.count)").font(LXType.sectionHead).foregroundStyle(.secondary)
                    }, rowSpacing: 0) {
                        ProviderModelList(store: store, models: models)
                    } footer: {
                        Text("模型元数据默认来自 models.lingxifox.cn 官方实时索引；可用性由 Provider Discovery 动态确认。")
                    }
                    .settingsAnchor("providers.list")
                }
            } else if store.client != nil {
                PlaceholderLine("Core 尚未配置 Provider 账户。用中间列的「＋」添加一个。")
            }

            if let status = store.providerStatus, !status.missingRequirements.isEmpty {
                LXStatusText("当前连接缺少：\(status.missingRequirements.joined(separator: "、"))",
                             systemImage: "exclamationmark.triangle",
                             tone: .warning)
            }
        }
        .task(id: account?.id) { await loadDetail() }
        .onChange(of: addTrigger) { _, _ in isAdding = true }
        .sheet(isPresented: $isAdding) {
            AddProviderSheet(store: store) { added in
                isAdding = false
                if let added { select(added.providerID) }
            }
        }
        .confirmationDialog("移除 Provider 账户？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { account in
            Button("移除 \(account.displayName)", role: .destructive) {
                Task {
                    if detail?.providerID == account.id {
                        if await store.deleteProvider(account.id) { select(nil) }
                    } else {
                        await store.removeProvider(account.id)
                    }
                }
            }
        } message: { account in
            Text(detail?.providerID == account.id
                 ? "\(account.displayName) 会从 providers.json 中移除，保存的 API Key 一并删除，依赖它的模型将不可用。"
                 : "\(account.displayName) 将从 Core 的账户列表中移除，依赖它的模型将不可用。")
        }
    }

    private func loadDetail() async {
        guard let id = account?.id else { detail = nil; return }
        detail = await store.providerConfiguration(id)
    }

    static func formatTokens(_ n: Int) -> String {
        guard n > 0 else { return "待同步" }
        return n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : "\(n / 1000)k"
    }
}

/// Expanded model list of one account. Models come from Core discovery only;
/// when the index has not filled the metadata yet the row shows the real
/// "metadata incomplete" state instead of a guessed window or capability.
private struct ProviderModelList: View {
    @ObservedObject var store: SettingsStore
    let models: [ProviderModelInfo]

    var body: some View {
        if models.isEmpty {
            PlaceholderLine("该账户已连接，还没有发现可用模型。")
                .lxSettingsRow()
        }
        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
            if index > 0 { LXSettingsDivider() }
            ExpandableModelSubRow(
                model: model,
                isSelected: (store.modelSelection?.qualifiedID ?? store.preferences.lastModelID)
                    .map(model.matches(selection:)) ?? false,
                onSelect: { Task { await store.selectDefaultModel(model.qualifiedID) } }
            )
        }
    }
}


private struct ExpandableModelSubRow: View {
    let model: ProviderModelInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(model.displayName)
                        .font(LXType.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isSelected {
                        LXBadge("当前默认", kind: .accent)
                    }
                }
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text(model.modelID)
                        .font(LXType.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if let capability = Self.capabilitySummary(model) {
                        Text(capability)
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: LingXiMetrics.Space.md)

            if model.metadataIncomplete || model.contextWindow == 0 {
                LXStatusText("元数据待同步", systemImage: "circle.dotted", tone: .muted)
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ProvidersSettingsPage.formatTokens(model.contextWindow))
                        .font(LXType.meta.monospacedDigit())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("上下文窗口 \(ProvidersSettingsPage.formatTokens(model.contextWindow))")
                    if model.maxOutputTokens > 0 {
                        Text("上限 \(ProvidersSettingsPage.formatTokens(model.maxOutputTokens))")
                            .font(LXType.meta.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("输出上限 \(ProvidersSettingsPage.formatTokens(model.maxOutputTokens))")
                    }
                }
            }

            if !isSelected {
                Button("设为默认", action: onSelect)
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
            }
        }
        .lxSettingsRow()
    }

    /// Only flags Core actually reports; nothing is guessed when the index has
    /// not filled the model's capabilities yet.
    private static func capabilitySummary(_ model: ProviderModelInfo) -> String? {
        var parts: [String] = []
        if model.reasoning { parts.append("推理") }
        if model.vision { parts.append("视觉") }
        if model.toolCalling { parts.append("工具调用") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ProviderRow: View {
    let account: ProviderAccountInfo
    let test: TestProviderResult?
    var onTest: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            Image(systemName: Self.glyph(for: account.accountType))
                .font(.system(size: LXIcon.surfaceHead))
                .foregroundStyle(.secondary)
                .frame(width: LXControl.large, height: LXControl.large)
                .background(LXColor.fillControl,
                            in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.control, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                Text(account.displayName)
                    .font(LXType.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([Self.accountTypeLabel(account.accountType), account.endpoint ?? account.productID]
                    .joined(separator: " · "))
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: LingXiMetrics.Space.md)

            connectivity

            Button("测试连接", action: onTest)
                .buttonStyle(LXButtonStyle(.secondary, size: .small))
            Button("移除…", action: onRemove)
                .buttonStyle(LXButtonStyle(.destructive, size: .small))
        }
        .padding(.vertical, LingXiMetrics.Space.sm)
        .lxSettingsRow()
    }

    /// Connectivity only ever shows a real measurement: the last Core test
    /// receipt, otherwise the availability Core reports for the account.
    @ViewBuilder
    private var connectivity: some View {
        if let test {
            if test.reachable {
                LXStatusText(test.latencyMs.map { String(format: "%.0f ms", $0) } ?? "可达",
                             systemImage: "checkmark.circle",
                             tone: .success)
            } else {
                LXStatusText(test.message ?? "不可达",
                             systemImage: "xmark.circle",
                             tone: .danger)
            }
        } else {
            availability
        }
    }

    /// Availability states Core actually reports, read through the contract's
    /// enum rather than by matching strings. The wording for the four credential
    /// states is already the shipped one; anything the design system does not
    /// name falls through to Core's own value instead of a guess.
    @ViewBuilder
    private var availability: some View {
        switch account.availability {
        case .reauthenticationRequired:
            LXStatusText("凭据已失效（需重新登录）", systemImage: "exclamationmark.triangle", tone: .danger)
        case .refreshFailedTransient:
            LXStatusText("刷新失败（可重试）", systemImage: "arrow.clockwise.circle", tone: .warning)
        case .refreshing:
            LXStatusText("令牌刷新中…", systemImage: "arrow.triangle.2.circlepath", tone: .neutral)
        case .active:
            if account.accountType == .oauthUser {
                LXStatusText("会话有效（自动刷新）", systemImage: "checkmark.shield", tone: .success)
            } else {
                LXStatusText("凭据有效", systemImage: "checkmark.circle", tone: .success)
            }
        case .configured, .unavailable, .unknown:
            LXStatusText(account.availability.rawValue, systemImage: "circle.dotted", tone: .muted)
        }
    }

    /// Protocol account type → short badge label. Maps a real Core value; it is
    /// not a provider list.
    static func accountTypeLabel(_ type: ProviderAccountType) -> String {
        switch type {
        case .apiKey: return "API"
        case .oauthUser: return "OAuth"
        case .localInstance, .anonymousLocal: return "Local"
        case .subscription: return "订阅"
        case .gateway: return "Gateway"
        case .workloadIdentity: return "Identity"
        }
    }

    /// Icon well glyph, derived from the account's real type. No brand logos are
    /// invented: the well only ever reflects what Core reports about the account.
    private static func glyph(for type: ProviderAccountType) -> String {
        switch type {
        case .apiKey: return "key"
        case .oauthUser: return "person.badge.key"
        case .localInstance, .anonymousLocal: return "pc"
        case .subscription: return "envelope"
        case .gateway: return "network"
        case .workloadIdentity: return "person.crop.circle.badge.checkmark"
        }
    }
}

// MARK: - Agent defaults

struct AgentDefaultsSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "Agent 默认",
                             subtitle: "新会话的默认模型、行为模式、思考强度与子 Agent 限额。") {
            LXSettingsCard("新会话默认模型",
                           subtitle: "新会话启动时默认启用的模型。元数据来自 models.lingxifox.cn 官方实时索引，可用性由 Provider 发现决定。") {
                LabeledContent {
                    Picker(selection: Binding(
                        get: {
                            let current = store.modelSelection?.qualifiedID
                                ?? store.preferences.lastModelID ?? ""
                            return store.models.first { $0.matches(selection: current) }?.qualifiedID ?? current
                        },
                        set: { id in Task { await store.selectDefaultModel(id) } }
                    )) {
                        if store.models.isEmpty { Text("—").tag("") }
                        ForEach(store.models.filter(\.configured), id: \.qualifiedID) { model in
                            Text(model.displayName).tag(model.qualifiedID)
                        }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                } label: {
                    Text("默认模型")
                }
                .disabled(store.models.isEmpty)
                .lxSettingsRow()
                .settingsAnchor("models.default")
            }

            LXSettingsCard("新任务默认") {
                LabeledContent {
                    Picker(selection: store.binding(ConfigKeys.behaviorProfile)) {
                        ForEach([(value: "build", label: "Build"),
                                 (value: "plan", label: "Plan"),
                                 (value: "explore", label: "Explore")], id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                } label: {
                    ConfigLabel(title: "行为模式", info: "新会话 Composer 的初始模式。Plan 只规划不改动，Explore 只读探索。",
                                key: ConfigKeys.behaviorProfile, store: store)
                }
                .lxSettingsRow()
                .settingsAnchor(ConfigKeys.behaviorProfile.id)

                LabeledContent {
                    Picker(selection: Binding(get: { store.defaultReasoning },
                                              set: { store.setDefaultReasoning($0) })) {
                        ForEach(ReasoningEffortLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                } label: {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("思考强度")
                        InfoHint("模型不支持的档位由 Core 映射到最近的可用档位。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("agent.reasoning")

                ConfigNumberField(title: "单轮最大步数", info: "一次回合内 Agent 循环的步数上限。",
                                  key: ConfigKeys.maxAgentLoopSteps, store: store)
            }

            LXSettingsCard("子 Agent") {
                ConfigNumberField(title: "最大并发", key: ConfigKeys.maxConcurrentSubagents, store: store)
                ConfigNumberField(title: "最大嵌套深度", key: ConfigKeys.maxSubagentDepth, store: store)
                ConfigNumberField(title: "单个根任务总运行数", key: ConfigKeys.maxTotalRuns, store: store)
            }
            .settingsAnchor("agent.subagents")

            LXSettingsCard("项目指令") {
                ConfigNumberField(title: "P-Core 项目指令上限", info: "AGENTS.md 等项目级指令进入常驻核心上下文的字符上限。",
                                  unit: "字符", key: ConfigKeys.pCoreProjectMaxCharacters, store: store)
                ConfigNumberField(title: "E-Core 召回上限", info: "从外延存储召回注入的字符上限。",
                                  unit: "字符", key: ConfigKeys.eCoreRecallMaxCharacters, store: store)
            }

            SystemContextEditor(store: store)
        }
    }
}

/// Edited as a draft and saved explicitly, so config.json is not rewritten per keystroke.
private struct SystemContextEditor: View {
    @ObservedObject var store: SettingsStore
    @State private var draft = ""

    var body: some View {
        LXSettingsCard(title: ConfigLabel(title: "系统上下文", info: "追加到每个会话系统提示之后的全局说明。留空即不追加。",
                                          key: ConfigKeys.systemContext, store: store)) {
            TextEditor(text: $draft)
                .font(LXType.mono)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .lxInsetBlock()
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
        }
        .settingsAnchor(ConfigKeys.systemContext.id)
        .onAppear { draft = store.config(ConfigKeys.systemContext) }
    }
}

// MARK: - Permissions

struct PermissionsSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "权限与沙箱", subtitle: "默认审批策略、访问范围与 Core 的审批矩阵。") {
            LXSettingsCard(title: LXSettingsSectionHeader("默认权限")) {
                ConfigPicker(title: "审批策略", key: ConfigKeys.permissionPolicy, options: [
                    ("ask", "每次询问"), ("auto", "自动批准"),
                ], store: store)
                ConfigPicker(title: "访问范围", key: ConfigKeys.executionProfile, options: [
                    ("readOnly", "只读"), ("workspace", "工作区"), ("fullAccess", "完全访问"),
                ], store: store)
                LabeledContent {
                    Button("应用") { Task { await store.applyPermissionToCore() } }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                        .disabled(store.client == nil)
                } label: {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text("应用到当前 Core")
                        InfoHint("不等重启，立即把上面的组合推送给正在运行的 Core。")
                    }
                }
                .lxSettingsRow()
                .settingsAnchor("permissions.apply")
            } footer: {
                if store.config(ConfigKeys.executionProfile) == "fullAccess" {
                    LXStatusText(store.config(ConfigKeys.permissionPolicy) == "auto"
                                 ? "自动批准 + 完全访问即 YOLO：Agent 可不经确认修改工作区外的任何文件并执行任意命令。"
                                 : "完全访问允许 Agent 读写工作区以外的路径，每次仍会请求你确认。",
                                 systemImage: "exclamationmark.triangle",
                                 tone: .warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("启动时读取。命令行 -y / --yolo 优先于此设置。Composer 里的 YOLO 开关只作用于当前会话，不修改这里的默认值。")
                }
            }

            LXSettingsCard(title: LXSettingsSectionHeader("审批矩阵")) {
                let policy = store.composerDefaults.permission.configuration.approvalPolicy
                ApprovalRow(title: "安全读取", decision: policy.safeRead)
                ApprovalRow(title: "工作区写入", decision: policy.workspaceMutation)
                ApprovalRow(title: "进程执行", decision: policy.processExecution)
                ApprovalRow(title: "外部读取", decision: policy.externalRead)
                ApprovalRow(title: "外部写入", decision: policy.externalMutation)
                ApprovalRow(title: "敏感访问", decision: policy.sensitiveAccess)
            } footer: {
                Text("上面组合对应 Core 的冻结权限预设，逐类决定允许、询问或拒绝。自定义规则需要 Core 提供规则契约后开放。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("permissions.matrix")

            LXSettingsCard(title: LXSettingsSectionHeader("固定边界")) {
                ValueRow(title: "凭据", value: "由 CredentialBroker 持有，不下发给子 Agent 或 MCP")
                ValueRow(title: "子 Agent 授权", value: "只能单调收窄于父集（child ⊆ parent）")
            } footer: {
                Text("以上由 Core 强制执行，不提供开关。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ApprovalRow: View {
    let title: String
    let decision: ApprovalDecision

    var body: some View {
        LabeledContent(title) {
            // A frozen policy value is static metadata, not an outcome: the row
            // carries no status colour, only the glyph and the label.
            LXStatusText(label, systemImage: symbol, tone: .neutral)
        }
        .lxSettingsRow()
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
}

// MARK: - Code intelligence

struct CodeIntelligenceSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "代码智能", subtitle: "代码图谱工具的启用状态与当前工作区索引。") {
            LXSettingsCard(title: LXSettingsSectionHeader("代码智能")) {
                ConfigToggle(title: "代码智能工具", info: "启用符号查找、定义、引用与依赖查询等代码图谱工具。",
                             key: ConfigKeys.codeIntelligence, store: store)
            } footer: {
                Text("关闭后 Agent 只用 grep / glob 等文本检索。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }

            LXSettingsCard(title: LXSettingsSectionHeader("项目索引")) {
                if let workspace = store.workspace {
                    ValueRow(title: "索引状态", value: workspace.indexingState ?? "—")
                    ValueRow(title: "图谱节点", value: workspace.codebaseNodes.map { "\($0)" } ?? "—")
                    ValueRow(title: "图谱关系", value: workspace.codebaseEdges.map { "\($0)" } ?? "—")
                } else {
                    PlaceholderLine(store.client == nil ? "连接 Core 后显示当前工作区的索引状态。" : "Core 未返回工作区索引信息。")
                }
            }
            .settingsAnchor("code.index")

            LXSettingsCard(title: LXSettingsSectionHeader("语言服务"), rowSpacing: 0) {
                if store.client == nil {
                    PlaceholderLine("连接 Core 后显示各语言 LSP 的运行状态。")
                        .lxSettingsRow()
                } else if let services = store.languageServices, !services.isEmpty {
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        if index > 0 { LXSettingsDivider() }
                        HStack(spacing: LingXiMetrics.Space.md) {
                            Text(service.language).font(LXType.body)
                            Spacer(minLength: LingXiMetrics.Space.md)
                            LXStatusText(LanguageServicePresentation.text(service.state),
                                         systemImage: LanguageServicePresentation.image(service.state),
                                         tone: LanguageServicePresentation.tone(service.state))
                        }
                        .lxSettingsRow()
                    }
                } else {
                    PlaceholderLine("当前工作区没有正在运行的语言服务。")
                        .lxSettingsRow()
                }
            }
        }
    }
}

/// 状态 = 图标 + 文字，不只靠颜色（设计系统「状态」规则）。
private enum LanguageServicePresentation {
    static func text(_ state: LanguageServiceState) -> String {
        switch state {
        case .idle: "空闲"
        case .starting: "启动中"
        case .ready: "就绪"
        case .degraded: "已降级"
        case .stopped: "已停止"
        }
    }

    static func image(_ state: LanguageServiceState) -> String {
        switch state {
        case .idle: "circle.dashed"
        case .starting: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        }
    }

    static func tone(_ state: LanguageServiceState) -> LXStatusText.Tone {
        switch state {
        case .idle, .stopped: .muted
        case .starting: .neutral
        case .ready: .success
        case .degraded: .warning
        }
    }
}

// MARK: - Context

struct ContextSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "上下文", subtitle: "当前生效的双核上下文策略与全局预算配置。") {
            if let policy = store.contextPolicy {
                LXSettingsCard(title: LXSettingsSectionHeader("当前生效策略 (Dual-Core Snapshot)")) {
                    ValueRow(title: "模型窗口", value: tokens(policy.modelWindow))
                    ValueRow(title: "可寻址预算", value: tokens(policy.addressableBudget))
                    ValueRow(title: "P-Core 目标 / 软限 / 硬限",
                             value: "\(tokens(policy.pCoreTarget)) / \(tokens(policy.pCoreSoftLimit)) / \(tokens(policy.pCoreHardLimit))")
                    ValueRow(title: "E-Core 存储预算", value: tokens(policy.eCoreStorageBudget))
                    ValueRow(title: "E-Core 召回预算", value: tokens(policy.eCoreRecallBudget))
                    ValueRow(title: "E-Core 压力保护阈值", value: String(format: "%.0f%%", policy.eCorePressureThreshold * 100))
                    ValueRow(title: "经济阈值", value: policy.economicThreshold.map(tokens) ?? "未启用")
                } footer: {
                    Text("由 Core 按当前模型窗口与双核策略计算后的实际工作值；下方为全局双核配置。")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor("context.live")
            }

            LXSettingsCard(title: LXSettingsSectionHeader("预算基线")) {
                ConfigNumberField(title: "可寻址预算", unit: "tokens", key: ConfigKeys.addressableBudget, store: store)
                ConfigNumberField(title: "保留余量", info: "为输出与工具结果预留、不参与上下文填充的 token。",
                                  unit: "tokens", key: ConfigKeys.reserve, store: store)
                ConfigNumberField(title: "经济阈值", info: "超过此值时优先压缩而非继续扩充上下文，避免跨入更高计费档。",
                                  unit: "tokens", key: ConfigKeys.economicThreshold, store: store)
            }
            .settingsAnchor("context.budget")

            LXSettingsCard(title: LXSettingsSectionHeader("P-Core 实时工作集 (Primary Working Set)")) {
                ConfigNumberField(title: "P-Core 目标工作集", unit: "tokens", key: ConfigKeys.pCoreTarget, store: store)
                ConfigNumberField(title: "P-Core 软限制 (Soft Limit)", info: "超过软限时触发非关键上下文降权淘汰与对象化流出。",
                                  unit: "tokens", key: ConfigKeys.pCoreSoftLimit, store: store)
                ConfigNumberField(title: "P-Core 硬限制 (Hard Limit)", info: "绝对硬上限，超过时强制阻断或深度截断以保护 Prefix Cache。",
                                  unit: "tokens", key: ConfigKeys.pCoreHardLimit, store: store)
            }
            .settingsAnchor("context.pcore")

            LXSettingsCard(title: LXSettingsSectionHeader("E-Core 对象与召回织网 (Context Fabric)")) {
                ConfigNumberField(title: "E-Core 存储预算", info: "外延对象存储的容量上限，超限时触发冷热分级淘汰。",
                                  unit: "tokens", key: ConfigKeys.eCoreStorageBudget, store: store)
                ConfigNumberField(title: "E-Core 召回预算", info: "单次回合中自外延存储召回注入的最大 token 数。",
                                  unit: "tokens", key: ConfigKeys.eCoreRecallBudget, store: store)
                ConfigToggle(title: "E-Core 载荷持久化", info: "把大体积工具结果与移出核心上下文的内容对象化落盘；关闭后仍保存在内存，只失去跨进程存活。",
                             key: ConfigKeys.eCorePersistence, store: store)
                ConfigToggle(title: "观察投影 (Observation Projection)", info: "将大体积多模态或命令输出结构化为紧凑观察摘要。",
                             key: ConfigKeys.observationProjection, store: store)
                ConfigToggle(title: "访问热度追踪", info: "按访问热度决定上下文淘汰与召回优先顺序。",
                             key: ConfigKeys.heatTracking, store: store)
            }
            .settingsAnchor("context.ecore")
        }
    }

    private func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

// MARK: - Execution

struct ExecutionSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        LXSettingsScrollPage(title: "执行与超时", subtitle: "各工具环节与运行阶段的超时上限。") {
            LXSettingsCard(title: LXSettingsSectionHeader("工具时限")) {
                ConfigSecondsField(title: "前台命令", key: ConfigKeys.foregroundShellSeconds, store: store)
                ConfigSecondsField(title: "快速文件操作", key: ConfigKeys.quickFilesystemSeconds, store: store)
                ConfigSecondsField(title: "搜索", key: ConfigKeys.searchSeconds, store: store)
                ConfigSecondsField(title: "构建与测试", key: ConfigKeys.buildTestSeconds, store: store)
                ConfigSecondsField(title: "MCP 调用", key: ConfigKeys.mcpSeconds, store: store)
            } footer: {
                Text("超时后 Core 终止对应进程并把超时作为工具结果返回给 Agent。")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("execution.budgets")

            LXSettingsCard(title: LXSettingsSectionHeader("模型与运行")) {
                ConfigSecondsField(title: "Provider 请求", key: ConfigKeys.providerSeconds, store: store)
                ConfigSecondsField(title: "Provider 流空闲", info: "流式响应无新数据超过此时长即视为中断。",
                                   key: ConfigKeys.providerIdleSeconds, store: store)
                ConfigSecondsField(title: "子 Agent", key: ConfigKeys.subagentSeconds, store: store)
                ConfigSecondsField(title: "单次 Agent 运行", key: ConfigKeys.agentRunSeconds, store: store)
                ConfigSecondsField(title: "绝对上限", info: "任何单项时限都不会超过此值。", key: ConfigKeys.maximumSeconds, store: store)
            }
        }
    }
}

#endif
