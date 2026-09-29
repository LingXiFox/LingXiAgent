#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// Editing forms for one `providers.json` entry: connection, model list, model
// sheet and the add-account sheet. Core validates and writes; the key goes to
// its vault and is never read back.

enum ProviderAdapterOption: String, CaseIterable, Identifiable {
    case openAICompatible = "openai-compatible"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
    static func label(for raw: String) -> String { Self(rawValue: raw)?.label ?? raw }
}

/// Draft of the connection section; saved explicitly so providers.json is not
/// rewritten per keystroke.
struct ProviderConnectionDraft: Equatable {
    var name: String
    var adapter: String
    var baseURL: String
    var apiKeyHeader: String
    var headers: [LXKeyValueEditor.KeyValuePair]
    var apiKey: SecretUpdate = .keep

    init(_ detail: ProviderConfigurationDetail) {
        name = detail.name
        adapter = detail.adapter
        baseURL = detail.baseURL
        apiKeyHeader = detail.apiKeyHeader ?? ""
        headers = LXKeyValueEditor.pairs(from: detail.headers)
    }

    func request(for detail: ProviderConfigurationDetail,
                 models: [ProviderModelConfigurationDetail]? = nil) -> SaveProviderConfigurationRequest {
        SaveProviderConfigurationRequest(
            providerID: detail.providerID, name: name, adapter: adapter,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
            headers: LXKeyValueEditor.dictionary(from: headers),
            apiKey: apiKey, models: models)
    }
}

/// 「连接」 and 「自定义请求头」 sections of a providers.json account.
struct ProviderConnectionEditor: View {
    @ObservedObject var store: SettingsStore
    let detail: ProviderConfigurationDetail
    let onSaved: (ProviderConfigurationDetail) -> Void
    @State private var draft: ProviderConnectionDraft
    @State private var isSaving = false

    init(store: SettingsStore, detail: ProviderConfigurationDetail,
         onSaved: @escaping (ProviderConfigurationDetail) -> Void) {
        self.store = store
        self.detail = detail
        self.onSaved = onSaved
        _draft = State(initialValue: ProviderConnectionDraft(detail))
    }

    private var isDirty: Bool { draft != ProviderConnectionDraft(detail) }

    var body: some View {
        LXSettingsCard(title: LXSettingsSectionHeader("连接"), accessory: {
            HStack(spacing: LingXiMetrics.Space.sm) {
                if isDirty {
                    Button("还原") { draft = ProviderConnectionDraft(detail) }
                }
                Button(isSaving ? "保存中…" : "保存") { save() }
                    .disabled(!isDirty || isSaving)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }) {
            LXTextRow(title: "名称", text: $draft.name)
            LabeledContent {
                Picker("接口类型", selection: $draft.adapter) {
                    ForEach(ProviderAdapterOption.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text("接口类型")
                    InfoHint("OpenAI 兼容：/v1/chat/completions · OpenAI Responses · Anthropic Messages")
                }
            }
            .lxSettingsRow()
            LXTextRow(title: "Base URL", text: $draft.baseURL, prompt: "https://", monospaced: true)
            LXSecretRow(title: "API Key", info: "由 Core 的凭据库保存，不写进 providers.json。",
                        stored: detail.apiKey, pending: $draft.apiKey)
            LXTextRow(title: "API Key 请求头", info: "留空时按接口类型使用默认请求头（Authorization: Bearer）。",
                      text: $draft.apiKeyHeader, prompt: "Authorization", monospaced: true)
        } footer: {
            Text("API Key 由 CredentialBroker 保存，不下发给子 Agent 或 MCP，也不会以明文显示。")
        }

        LXSettingsCard("自定义请求头") {
            LXKeyValueEditor(pairs: $draft.headers, keyPrompt: "请求头", valuePrompt: "值", addTitle: "添加请求头")
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            if let saved = await store.saveProvider(draft.request(for: detail)) {
                draft = ProviderConnectionDraft(saved)
                onSaved(saved)
            }
        }
    }
}

// MARK: - Models

/// 「模型 N」: one row per model, 「编辑…」 opens the model sheet.
struct ProviderModelsEditor: View {
    @ObservedObject var store: SettingsStore
    let detail: ProviderConfigurationDetail
    let onSaved: (ProviderConfigurationDetail) -> Void
    @State private var editing: EditingModel?

    struct EditingModel: Identifiable {
        let id = UUID()
        var model: ProviderModelConfigurationDetail
        let isNew: Bool
    }

    var body: some View {
        LXSettingsCard(title: HStack(spacing: LingXiMetrics.Space.xs) {
            LXSettingsSectionHeader("模型")
            Text("\(detail.models.count)").font(LXType.sectionHead).foregroundStyle(.secondary)
        }, rowSpacing: 0, accessory: {
            Button("添加模型…") {
                editing = EditingModel(model: ProviderModelConfigurationDetail(modelID: "", name: ""), isNew: true)
            }
        }) {
            ForEach(Array(detail.models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { LXSettingsDivider() }
                HStack(spacing: LingXiMetrics.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: LingXiMetrics.Space.xs) {
                            Text(model.name).font(LXType.body.weight(.medium)).lineLimit(1)
                            if isDefault(model) { LXBadge("当前默认", kind: .accent) }
                        }
                        Text(model.modelID).font(LXType.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: LingXiMetrics.Space.md)
                    Text(modelMetadataSummary(model))
                        .font(LXType.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !isDefault(model) {
                        Button("设为默认") {
                            Task { await store.selectDefaultModel("\(detail.providerID)/\(model.modelID)") }
                        }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    }
                    Button("编辑…") { editing = EditingModel(model: model, isNew: false) }
                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                }
                .lxSettingsRow()
            }
        } footer: {
            Text("模型元数据默认来自 models.lingxifox.cn 官方实时索引；「编辑…」里改过的项标为「已自定义」，可逐项恢复。可用性由 Provider Discovery 动态确认。")
        }
        .sheet(item: $editing) { item in
            ProviderModelSheet(model: item.model, isNew: item.isNew, canRemove: detail.models.count > 1,
                               existingIDs: Set(detail.models.map(\.modelID))) { result in
                editing = nil
                guard let result else { return }
                Task { await apply(result, replacing: item.isNew ? nil : item.model.modelID) }
            }
        }
    }

    private func isDefault(_ model: ProviderModelConfigurationDetail) -> Bool {
        let current = store.modelSelection?.qualifiedID ?? store.preferences.lastModelID
        return current == "\(detail.providerID)/\(model.modelID)"
    }

    /// 「上下文 200K · 输出 64K」 from the effective values, with 「已自定义」 once
    /// the user overrides a field, and 「元数据待同步」 when no catalog describes
    /// the model.
    private func modelMetadataSummary(_ model: ProviderModelConfigurationDetail) -> String {
        guard !model.catalogDefaults.isEmpty else { return "元数据待同步" }
        let summary = "上下文 \(ProvidersSettingsPage.formatTokens(model.effective.contextWindow))"
            + " · 输出 \(ProvidersSettingsPage.formatTokens(model.effective.maxOutputTokens))"
        return model.isCustomized ? summary + " · 已自定义" : summary
    }

    /// Saves the whole model list with one entry added, replaced or removed.
    private func apply(_ result: ProviderModelSheet.Result, replacing oldID: String?) async {
        var models = detail.models
        switch result {
        case .save(let model):
            if let oldID, let index = models.firstIndex(where: { $0.modelID == oldID }) {
                models[index] = model
            } else {
                models.append(model)
            }
        case .remove:
            models.removeAll { $0.modelID == oldID }
        }
        var request = SaveProviderConfigurationRequest(
            providerID: detail.providerID, name: detail.name, adapter: detail.adapter, baseURL: detail.baseURL,
            apiKeyHeader: detail.apiKeyHeader, headers: detail.headers, apiKey: .keep)
        request.models = models
        if let saved = await store.saveProvider(request) { onSaved(saved) }
    }
}

/// 编辑模型: 限制 · 能力 · 速率限制 · 重试策略.
struct ProviderModelSheet: View {
    enum Result { case save(ProviderModelConfigurationDetail), remove }

    @State var model: ProviderModelConfigurationDetail
    let isNew: Bool
    let canRemove: Bool
    let existingIDs: Set<String>
    let onFinish: (Result?) -> Void
    @State private var confirmRemove = false

    private var idConflict: Bool {
        isNew && existingIDs.contains(model.modelID.trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        !model.modelID.trimmingCharacters(in: .whitespaces).isEmpty && !idConflict
            && (model.contextWindow.map { $0 > 0 } ?? true)
            && (model.maxOutputTokens.map { $0 > 0 } ?? true)
    }

    /// Fields the user has not overridden show Core's effective value, which
    /// already resolved override → catalog default → last-resort default.
    private var defaults: ProviderModelEffectiveValues { model.effective }

    private func resetAll() {
        model.contextWindow = nil
        model.maxOutputTokens = nil
        model.reasoning = nil
        model.toolCalling = nil
        model.parallelToolCalling = nil
        model.vision = nil
        model.structuredOutput = nil
        model.tokensPerMinute = nil
        model.requestsPerMinute = nil
        model.maxConcurrentRequests = nil
        model.maxRetries = nil
        model.initialRetryDelayMilliseconds = nil
        model.maxRetryDelayMilliseconds = nil
        model.retryJitterRatio = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "添加模型" : model.name).font(LXType.title)
                    if !isNew {
                        Text(model.modelID).font(LXType.monoSmall).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .frame(height: LingXiMetrics.Size.toolbar + LingXiMetrics.Space.md)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                    LXSettingsCard("模型") {
                        if isNew {
                            LXTextRow(title: "模型 ID", info: "Provider 接口里使用的模型名。", text: $model.modelID,
                                      prompt: "例如 deepseek-v4-flash", monospaced: true)
                        }
                        LXTextRow(title: "显示名称", text: $model.name, prompt: model.modelID)
                    }
                    LXSettingsCard("限制") {
                        LXNumberRow(title: "上下文窗口", value: $model.contextWindow, unit: "tokens",
                                    defaultValue: defaults.contextWindow,
                                    reset: model.contextWindow == nil ? nil : { model.contextWindow = nil })
                        LXNumberRow(title: "输出上限", value: $model.maxOutputTokens, unit: "tokens",
                                    defaultValue: defaults.maxOutputTokens,
                                    reset: model.maxOutputTokens == nil ? nil : { model.maxOutputTokens = nil })
                    }
                    LXSettingsCard("能力") {
                        LXOverrideToggle(title: "推理（思考）", override: $model.reasoning,
                                         defaultValue: defaults.reasoning)
                        LXOverrideToggle(title: "工具调用", override: $model.toolCalling,
                                         defaultValue: defaults.toolCalling)
                        LXOverrideToggle(title: "并行工具调用", override: $model.parallelToolCalling,
                                         defaultValue: defaults.parallelToolCalling)
                        LXOverrideToggle(title: "视觉输入", override: $model.vision,
                                         defaultValue: defaults.vision)
                        LXOverrideToggle(title: "结构化输出", override: $model.structuredOutput,
                                         defaultValue: defaults.structuredOutput)
                    }
                    LXSettingsCard("速率限制") {
                        LXNumberRow(title: "每分钟 token (TPM)", value: $model.tokensPerMinute,
                                    defaultValue: defaults.tokensPerMinute,
                                    reset: model.tokensPerMinute == nil ? nil : { model.tokensPerMinute = nil })
                        LXNumberRow(title: "每分钟请求 (RPM)", value: $model.requestsPerMinute,
                                    defaultValue: defaults.requestsPerMinute,
                                    reset: model.requestsPerMinute == nil ? nil : { model.requestsPerMinute = nil })
                        LXNumberRow(title: "最大并发请求", value: $model.maxConcurrentRequests,
                                    defaultValue: defaults.maxConcurrentRequests,
                                    reset: model.maxConcurrentRequests == nil ? nil : { model.maxConcurrentRequests = nil })
                    }
                    LXSettingsCard("重试策略", subtitle: "遇到 429 或可重试错误时按指数退避重试。") {
                        LXNumberRow(title: "最大重试次数", value: $model.maxRetries, unit: "次",
                                    defaultValue: defaults.maxRetries,
                                    reset: model.maxRetries == nil ? nil : { model.maxRetries = nil })
                        LXNumberRow(title: "初始延迟", value: $model.initialRetryDelayMilliseconds, unit: "毫秒",
                                    defaultValue: defaults.initialRetryDelayMilliseconds,
                                    reset: model.initialRetryDelayMilliseconds == nil ? nil : { model.initialRetryDelayMilliseconds = nil })
                        LXNumberRow(title: "最大延迟", value: $model.maxRetryDelayMilliseconds, unit: "毫秒",
                                    defaultValue: defaults.maxRetryDelayMilliseconds,
                                    reset: model.maxRetryDelayMilliseconds == nil ? nil : { model.maxRetryDelayMilliseconds = nil })
                        LabeledContent("抖动比例") {
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                if model.retryJitterRatio != nil {
                                    Button("恢复默认") { model.retryJitterRatio = nil }
                                        .buttonStyle(LXButtonStyle(.secondary, size: .small))
                                }
                                TextField("抖动比例", value: $model.retryJitterRatio,
                                          format: .number.precision(.fractionLength(0...2)))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundStyle(model.retryJitterRatio == nil ? Color.secondary : Color.primary)
                                    .frame(width: 96)
                            }
                        }
                        .lxSettingsRow()
                    }
                    Text("未改动的项跟随 models.lingxifox.cn 的元数据；改过的项在左侧出现「恢复默认」。")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                    if idConflict {
                        LXStatusText("这个 Provider 已有同名模型。", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.xxl)
                .padding(.bottom, LingXiMetrics.Space.xl)
            }

            LXHairline()
            HStack(spacing: LingXiMetrics.Space.sm) {
                if !isNew {
                    Button("移除模型…") { confirmRemove = true }
                        .buttonStyle(LXButtonStyle(.destructive, size: .regular))
                        .disabled(!canRemove)
                        .help(canRemove ? "从 providers.json 中移除" : "Provider 至少需要一个模型")
                    if model.isCustomized {
                        Button("恢复全部默认", action: resetAll)
                            .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                    }
                }
                Spacer()
                Button("取消") { onFinish(nil) }
                    .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") {
                    model.modelID = model.modelID.trimmingCharacters(in: .whitespaces)
                    onFinish(.save(model))
                }
                .buttonStyle(LXButtonStyle(.primary, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(LingXiMetrics.Space.lg)
        }
        .frame(width: 620, height: 640)
        .background(LXColor.window)
        .lxSettingsControlStyles()
        .confirmationDialog("移除模型 \(model.modelID)？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { onFinish(.remove) }
        }
    }
}

// MARK: - Add account

/// 添加 Provider 账户: an API Key account becomes a providers.json entry, and
/// 「登录账户」 runs the OAuth flow Core owns — this sheet only opens the
/// authorize URL and reads the phase back.
struct AddProviderSheet: View {
    private enum Access: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case account = "登录账户"
        var id: String { rawValue }
    }

    @ObservedObject var store: SettingsStore
    let onFinish: (ProviderConfigurationDetail?) -> Void
    @Environment(\.openURL) private var openURL

    @State private var access: Access = .apiKey
    @State private var providerID = ""
    @State private var name = ""
    @State private var adapter = ProviderAdapterOption.openAICompatible.rawValue
    @State private var baseURL = "https://"
    @State private var apiKey = ""
    @State private var apiKeyHeader = ""
    @State private var modelID = ""
    @State private var contextWindow = 128_000
    @State private var maxOutput = 8_192
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: TestProviderResult?
    /// Key already written to Core's vault, referenced instead of resent.
    @State private var stagedRef: CredentialRef?
    @State private var authProducts: [ProviderAuthProduct] = []
    @State private var authProductID = ""
    @State private var authFlow: ProviderAuthFlow?
    @State private var pollTask: Task<Void, Never>?

    private var existingIDs: Set<String> { Set(store.providers.map(\.id)) }

    private var trimmedID: String { providerID.trimmingCharacters(in: .whitespaces) }

    private var isValid: Bool {
        switch access {
        case .account:
            return !authProductID.isEmpty
        case .apiKey:
            return trimmedID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
                && !existingIDs.contains(trimmedID)
                && !name.trimmingCharacters(in: .whitespaces).isEmpty
                && baseURL.count > "https://".count
                && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
                && contextWindow > 0 && maxOutput > 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("添加 Provider 账户").font(LXType.title)
                Text("选择接入方式，填入连接信息。保存前会先测试连接。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.vertical, LingXiMetrics.Space.lg)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                    LXSettingsCard(title: LXSettingsSectionHeader("接入方式")) {
                        LabeledContent("方式") {
                            Picker("方式", selection: $access) {
                                ForEach(Access.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .lxSettingsRow()
                    } footer: {
                        Text("接口类型：OpenAI 兼容（/v1/chat/completions）· OpenAI Responses · Anthropic Messages。「登录账户」用浏览器完成 OAuth，不需要填 Key。")
                    }

                    if access == .apiKey {
                        LXSettingsCard(title: LXSettingsSectionHeader("连接")) {
                            LXTextRow(title: "名称", text: $name, prompt: "例如：公司中转")
                            LXTextRow(title: "ID", info: "providers.json 中的键，也是模型名前缀，如 relay/model。",
                                      text: $providerID, prompt: "relay", monospaced: true)
                            LabeledContent("接口类型") {
                                Picker("接口类型", selection: $adapter) {
                                    ForEach(ProviderAdapterOption.allCases) { Text($0.label).tag($0.rawValue) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            .lxSettingsRow()
                            LXTextRow(title: "Base URL", text: $baseURL, prompt: "https://", monospaced: true)
                            LabeledContent("API Key") {
                                SecureField("粘贴 API Key", text: $apiKey)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(LXType.mono)
                                    .frame(width: 280)
                            }
                            .lxSettingsRow()
                            LXTextRow(title: "API Key 请求头", text: $apiKeyHeader, prompt: "Authorization", monospaced: true)
                        } footer: {
                            Text("API Key 由 CredentialBroker 保存，不下发给子 Agent 或 MCP，也不会以明文显示。")
                        }
                        LXSettingsCard("首个模型") {
                            LXTextRow(title: "模型 ID", text: $modelID, prompt: "例如 deepseek-v4-flash", monospaced: true)
                            LXNumberRow(title: "上下文窗口", value: $contextWindow.optional, unit: "tokens")
                            LXNumberRow(title: "输出上限", value: $maxOutput.optional, unit: "tokens")
                        }
                        if existingIDs.contains(trimmedID) {
                            LXStatusText("已存在 ID 为 \(trimmedID) 的账户。", systemImage: "exclamationmark.triangle", tone: .warning)
                        }
                        if let testResult {
                            LXStatusText(
                                testResult.reachable
                                    ? "连接可达" + (testResult.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? "")
                                    : "连接失败：\(testResult.message ?? "未知错误")",
                                systemImage: testResult.reachable ? "checkmark.circle" : "xmark.circle",
                                tone: testResult.reachable ? .success : .danger)
                        }
                    } else {
                        LXSettingsCard(title: LXSettingsSectionHeader("账户")) {
                            LabeledContent("产品") {
                                Picker("产品", selection: $authProductID) {
                                    Text("请选择").tag("")
                                    ForEach(authProducts) { product in
                                        Text(product.displayName).tag(product.productID)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            .lxSettingsRow()
                            if let authFlow {
                                LabeledContent("状态") {
                                    LXStatusText(Self.authText(authFlow.phase),
                                                 systemImage: Self.authImage(authFlow.phase),
                                                 tone: Self.authTone(authFlow.phase))
                                }
                                .lxSettingsRow()
                                if let message = authFlow.message {
                                    LXStatusText(message, systemImage: "exclamationmark.triangle", tone: .warning)
                                }
                            }
                        } footer: {
                            Text("登录由 Core 完成：浏览器授权后由 Core 接收回调并保存凭据，本窗口不会看到令牌。")
                        }
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.xxl)
                .padding(.bottom, LingXiMetrics.Space.xl)
            }

            LXHairline()
            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                if access == .apiKey {
                    Button(isTesting ? "测试中…" : "测试连接") { testConnection() }
                        .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                        .disabled(isTesting || baseURL.count <= "https://".count)
                    Button(isSaving ? "添加中…" : "添加") { save() }
                        .buttonStyle(LXButtonStyle(.primary, size: .regular))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid || isSaving)
                } else {
                    Button(authFlow?.phase == .awaitingCallback ? "重新登录" : "登录") { startSignIn() }
                        .buttonStyle(LXButtonStyle(.primary, size: .regular))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
            .padding(LingXiMetrics.Space.lg)
        }
        .frame(width: 620, height: 600)
        .background(LXColor.window)
        .lxSettingsControlStyles()
        .task {
            if authProducts.isEmpty {
                authProducts = await store.providerAuthProducts()
                authProductID = authProducts.first?.productID ?? ""
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private static func authText(_ phase: ProviderAuthPhase) -> String {
        switch phase {
        case .awaitingCallback, .exchanging: "登录中"
        case .connected: "已连接"
        case .needsReauthentication: "需要重新登录"
        case .failed: "登录失败"
        case .cancelled: "已取消"
        }
    }

    private static func authImage(_ phase: ProviderAuthPhase) -> String {
        switch phase {
        case .awaitingCallback, .exchanging: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle"
        case .needsReauthentication: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        case .cancelled: "circle.dashed"
        }
    }

    private static func authTone(_ phase: ProviderAuthPhase) -> LXStatusText.Tone {
        switch phase {
        case .connected: .success
        case .failed: .danger
        case .needsReauthentication: .warning
        case .awaitingCallback, .exchanging, .cancelled: .neutral
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            defer { isTesting = false }
            if stagedRef == nil {
                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { stagedRef = await store.stageSecret(key) }
            }
            testResult = await store.testProviderDraft(TestProviderDraftRequest(
                adapter: adapter,
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
                credentialRef: stagedRef))
        }
    }

    private func startSignIn() {
        pollTask?.cancel()
        Task {
            guard let flow = await store.beginProviderAuth(productID: authProductID) else { return }
            authFlow = flow
            if let string = flow.authorizeURL, let url = URL(string: string) { openURL(url) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let status = await store.providerAuthStatus(flowID: flow.flowID) else { break }
                authFlow = status
                if status.phase == .connected || status.phase == .failed || status.phase == .cancelled { break }
            }
        }
    }

    /// Drops the staged key when the form is abandoned; an adopted one is
    /// already the account's own credential.
    private func dismiss() {
        pollTask?.cancel()
        if let stagedRef {
            Task { await store.discardStagedSecret(stagedRef) }
        }
        onFinish(nil)
    }

    private func save() {
        isSaving = true
        let staged = stagedRef
        let request = SaveProviderConfigurationRequest(
            providerID: trimmedID,
            name: name.trimmingCharacters(in: .whitespaces),
            adapter: adapter,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
            apiKey: staged.map { .staged(reference: $0) } ?? .keep,
            models: [ProviderModelConfigurationDetail(
                modelID: modelID.trimmingCharacters(in: .whitespaces),
                name: modelID.trimmingCharacters(in: .whitespaces),
                contextWindow: contextWindow, maxOutputTokens: maxOutput)])
        Task {
            let saved = await store.saveProvider(request)
            isSaving = false
            if saved != nil {
                stagedRef = nil
                onFinish(saved)
            } else if let staged {
                await store.discardStagedSecret(staged)
                stagedRef = nil
            }
        }
    }
}
#endif
