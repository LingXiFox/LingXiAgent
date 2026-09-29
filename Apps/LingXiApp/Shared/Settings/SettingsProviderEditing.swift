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
                editing = EditingModel(model: ProviderModelConfigurationDetail(
                    modelID: "", name: "", contextWindow: 128_000, maxOutputTokens: 8_192), isNew: true)
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
                    Text("上下文 \(ProvidersSettingsPage.formatTokens(model.contextWindow)) · 输出 \(ProvidersSettingsPage.formatTokens(model.maxOutputTokens))")
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
            Text("模型元数据默认来自 models.lingxifox.cn 官方实时索引；这里的限制、能力与速率由你覆盖。可用性由 Provider Discovery 动态确认。")
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
            && model.contextWindow > 0 && model.maxOutputTokens > 0
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

            ScrollView {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                    LXSettingsCard("模型") {
                        if isNew {
                            LXTextRow(title: "模型 ID", info: "Provider 接口里使用的模型名。", text: $model.modelID,
                                      prompt: "例如 deepseek-v4-flash", monospaced: true)
                        }
                        LXTextRow(title: "显示名称", text: $model.name, prompt: model.modelID)
                    }
                    LXSettingsCard("限制") {
                        LXNumberRow(title: "上下文窗口", value: $model.contextWindow.optional, unit: "tokens")
                        LXNumberRow(title: "输出上限", value: $model.maxOutputTokens.optional, unit: "tokens")
                    }
                    LXSettingsCard("能力") {
                        Toggle("推理（思考）", isOn: $model.reasoning)
                        Toggle("工具调用", isOn: $model.toolCalling)
                        Toggle("并行工具调用", isOn: $model.parallelToolCalling)
                        Toggle("视觉输入", isOn: $model.vision)
                        Toggle("结构化输出", isOn: $model.structuredOutput)
                    }
                    LXSettingsCard("速率限制") {
                        LXNumberRow(title: "每分钟 token (TPM)", value: $model.tokensPerMinute)
                        LXNumberRow(title: "每分钟请求 (RPM)", value: $model.requestsPerMinute)
                        LXNumberRow(title: "最大并发请求", value: $model.maxConcurrentRequests)
                    }
                    LXSettingsCard("重试策略", subtitle: "遇到 429 或可重试错误时按指数退避重试。") {
                        LXNumberRow(title: "最大重试次数", value: $model.maxRetries.optional, unit: "次")
                        LXNumberRow(title: "初始延迟", value: $model.initialRetryDelayMilliseconds.optional, unit: "毫秒")
                        LXNumberRow(title: "最大延迟", value: $model.maxRetryDelayMilliseconds.optional, unit: "毫秒")
                        LabeledContent("抖动比例") {
                            TextField("抖动比例", value: $model.retryJitterRatio, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                        }
                        .lxSettingsRow()
                    }
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

/// 添加 Provider 账户: API Key accounts become a providers.json entry. OAuth
/// accounts sign in with `lingxiagent auth login`, which Settings points to.
struct AddProviderSheet: View {
    @ObservedObject var store: SettingsStore
    let onFinish: (ProviderConfigurationDetail?) -> Void

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

    private var existingIDs: Set<String> { Set(store.providers.map(\.id)) }

    private var trimmedID: String { providerID.trimmingCharacters(in: .whitespaces) }

    private var isValid: Bool {
        trimmedID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
            && !existingIDs.contains(trimmedID)
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && baseURL.count > "https://".count
            && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
            && contextWindow > 0 && maxOutput > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("添加 Provider 账户").font(LXType.title)
                Text("填入连接信息与一个可用模型。保存后可在 Provider 页继续补充模型与请求头。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.vertical, LingXiMetrics.Space.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
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
                        Text("OAuth 登录的账户请在终端运行 lingxiagent auth login <产品 ID>，完成后会出现在列表里。")
                    }
                    LXSettingsCard("首个模型") {
                        LXTextRow(title: "模型 ID", text: $modelID, prompt: "例如 deepseek-v4-flash", monospaced: true)
                        LXNumberRow(title: "上下文窗口", value: $contextWindow.optional, unit: "tokens")
                        LXNumberRow(title: "输出上限", value: $maxOutput.optional, unit: "tokens")
                    }
                    if existingIDs.contains(trimmedID) {
                        LXStatusText("已存在 ID 为 \(trimmedID) 的账户。", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.xxl)
                .padding(.bottom, LingXiMetrics.Space.xl)
            }

            LXHairline()
            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer()
                Button("取消") { onFinish(nil) }
                    .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "添加中…" : "添加") { save() }
                    .buttonStyle(LXButtonStyle(.primary, size: .regular))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
            .padding(LingXiMetrics.Space.lg)
        }
        .frame(width: 620, height: 600)
        .background(LXColor.window)
        .lxSettingsControlStyles()
    }

    private func save() {
        isSaving = true
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SaveProviderConfigurationRequest(
            providerID: trimmedID,
            name: name.trimmingCharacters(in: .whitespaces),
            adapter: adapter,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
            apiKey: key.isEmpty ? .keep : .replace(key),
            models: [ProviderModelConfigurationDetail(
                modelID: modelID.trimmingCharacters(in: .whitespaces),
                name: modelID.trimmingCharacters(in: .whitespaces),
                contextWindow: contextWindow, maxOutputTokens: maxOutput)])
        Task {
            let saved = await store.saveProvider(request)
            isSaving = false
            if saved != nil { onFinish(saved) }
        }
    }
}
#endif
