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
    @State private var isAdding = false
    @State private var availability: [String: ModelAvailability] = [:]
    @State private var isProbing = false

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
            Button(isProbing ? "探测中…" : "探测可用性") {
                isProbing = true
                Task {
                    availability = await store.probeProviderModels(providerID: detail.providerID)
                    isProbing = false
                }
            }
            .disabled(isProbing)
            Button("添加模型…") { isAdding = true }
        }) {
            ForEach(Array(detail.models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { LXSettingsDivider() }
                HStack(spacing: LingXiMetrics.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: LingXiMetrics.Space.xs) {
                            Text(model.name).font(LXType.body.weight(.medium)).lineLimit(1)
                            if isDefault(model) { LXBadge("当前默认", kind: .accent) }
                            // Only a real turn tells a working model from one the plan excludes.
                            if availability[model.modelID] == .unavailable { LXBadge("套餐不含", kind: .neutral) }
                            if isProbing && availability[model.modelID] == nil { Text("…").font(LXType.meta).foregroundStyle(.secondary) }
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
            Text("模型元数据默认来自 models.lingxifox.cn 官方实时索引；「编辑…」里改过的项标为「已自定义」，可逐项恢复。端点列出的模型不等于这个账号能用——「探测可用性」对每个模型发一次最小请求，只有套餐不含或模型不存在才标「套餐不含」，限流与网关故障不算失败。")
        }
        // Read back what an earlier probe already settled, so leaving the page and coming back does
        // not lose an answer the account already paid for.
        .task(id: detail.providerID) {
            availability = await store.modelAvailability(providerID: detail.providerID)
        }
        .sheet(item: $editing) { item in
            ProviderModelSheet(model: item.model, isNew: item.isNew, canRemove: detail.models.count > 1,
                               existingIDs: Set(detail.models.map(\.modelID))) { result in
                editing = nil
                guard let result else { return }
                Task { await apply(result, replacing: item.isNew ? nil : item.model.modelID) }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddProviderModelsSheet(store: store, detail: detail) { saved in
                onSaved(saved)
                isAdding = false
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

struct AddProviderModelsSheet: View {
    @ObservedObject var store: SettingsStore
    let detail: ProviderConfigurationDetail
    let onSaved: (ProviderConfigurationDetail) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var emptyNote: String?
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var manualID = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var existingIDs: Set<String> { Set(detail.models.map(\.modelID)) }
    private var additions: [String] {
        var ids = selected
        let manual = manualID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { ids.insert(manual) }
        return ids.subtracting(existingIDs).sorted()
    }
    private var visibleModels: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { needle.isEmpty || $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("添加模型 · \(detail.name)").font(LXType.title)
            NativeSearchField(text: $query, prompt: "搜索模型").navigatorChrome()
            HStack {
                Text(isLoading ? "正在获取模型列表…" : "已选 \(additions.count) 个模型")
                    .font(LXType.meta).foregroundStyle(.secondary)
                Spacer()
                Button("全选") { selected = Set(models) }
                Button("清空") { selected = [] }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    if !isLoading && models.isEmpty {
                        Text((emptyNote.map { $0 + " " } ?? "") + "可在下方手动输入模型 ID。")
                            .foregroundStyle(.secondary)
                    } else if !isLoading && visibleModels.isEmpty {
                        Text("没有匹配的模型。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleModels, id: \.self) { id in
                        Toggle(id, isOn: Binding(
                            get: { selected.contains(id) },
                            set: { if $0 { selected.insert(id) } else { selected.remove(id) } }))
                            .toggleStyle(.checkbox)
                            .font(LXType.monoSmall)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("手动输入模型 ID（可选）", text: $manualID)
                .textFieldStyle(.roundedBorder).font(LXType.mono)
            if let error { Text(error).foregroundStyle(LXColor.danger).font(LXType.meta) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "保存中…" : "添加 \(additions.count) 个模型") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving || additions.isEmpty)
            }
        }
        .padding(LingXiMetrics.Space.xl)
        .frame(width: 620, height: 520)
        .modifier(WallpaperWindow())
        .lxNoInitialFocus()
        .lxSettingsControlStyles()
        .task {
            let roster = await store.providerCatalogModels(entryID: detail.providerID)
            models = Array(Set(roster.models).subtracting(existingIDs)).sorted()
            selected = Set(models)
            emptyNote = roster.models.isEmpty ? roster.note
                : (models.isEmpty ? "端点列出的模型已全部在配置中。" : nil)
            isLoading = false
        }
    }

    private func save() {
        let added = additions.map { ProviderModelConfigurationDetail(modelID: $0, name: $0) }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            let request = ProviderConnectionDraft(detail).request(for: detail, models: detail.models + added)
            if let saved = await store.saveProvider(request) { onSaved(saved) }
            else { error = store.notice ?? "保存模型失败。" }
        }
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
        .modifier(WallpaperWindow())
        .lxNoInitialFocus()
        .lxSettingsControlStyles()
        .confirmationDialog("移除模型 \(model.modelID)？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { onFinish(.remove) }
        }
    }
}

// MARK: - Add account

/// 添加 Provider 账户.
///
/// The list comes from Core's provider catalog — the curated registry plus the
/// published models.lingxifox.cn index — and the form is then driven by what the
/// chosen entry says it needs: a key, a browser sign-in, a local endpoint, or
/// nothing. Endpoints, wire protocols and model lists stay in Core. A relay the
/// user runs themselves is still written into `providers.json` by hand.
struct AddProviderSheet: View {
    private enum Choice: Hashable {
        case custom
        case entry(String)
    }

    @ObservedObject var store: SettingsStore
    let onFinish: (String?) -> Void
    @Environment(\.openURL) private var openURL

    @State private var query = ""
    @State private var choice: Choice = .custom

    // 自定义中转
    @State private var providerID = ""
    @State private var name = ""
    @State private var adapter = ProviderAdapterOption.openAICompatible.rawValue
    @State private var baseURL = "https://"
    @State private var apiKeyHeader = ""
    @State private var modelID = ""
    @State private var contextWindow = 128_000
    @State private var maxOutput = 8_192

    // shared
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var fieldValues: [String: String] = [:]
    @State private var stagedRef: CredentialRef?
    @State private var testResult: TestProviderResult?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isRefreshingCatalog = false

    // models of the selected catalog entry
    @State private var catalogModels: [String] = []
    @State private var catalogNote: String?
    @State private var chosenModels: Set<String> = []
    @State private var modelQuery = ""

    // 登录账户
    @State private var authFlow: ProviderAuthFlow?
    @State private var pollTask: Task<Void, Never>?

    private var entries: [ProviderCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.providerCatalog }
        return store.providerCatalog.filter {
            $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
    }

    private var selectedEntry: ProviderCatalogEntry? {
        guard case .entry(let id) = choice else { return nil }
        return store.providerCatalog.first { $0.id == id }
    }

    private var connectedIDs: Set<String> { Set(store.providers.map(\.productID)) }
    private var trimmedID: String { providerID.trimmingCharacters(in: .whitespaces) }

    private var visibleModels: [String] {
        let needle = modelQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return catalogModels }
        return catalogModels.filter { $0.lowercased().contains(needle) }
    }

    private var needsModelChoice: Bool {
        guard let entry = selectedEntry else { return false }
        // A curated product discovers its own models once connected; only an
        // index entry needs the choice written into providers.json.
        return entry.source == .modelsIndex && entry.signInMode != .browser && entry.connectable
    }

    private var isValid: Bool {
        switch choice {
        case .entry(let id):
            guard let entry = store.providerCatalog.first(where: { $0.id == id }), entry.connectable else { return false }
            // Only an index entry needs a model written into providers.json.
            let needsModel = entry.source == .modelsIndex && chosenModels.isEmpty
            switch entry.signInMode {
            case .browser:
                return authFlow?.phase != .connected
            case .localEndpoint:
                return !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !needsModel
            case .apiKey:
                if needsKey(entry), stagedRef == nil,
                   apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                let missingFields = entry.requiredAccountFields.filter { (fieldValues[$0] ?? "").isEmpty }
                return missingFields.isEmpty && !needsModel
            case .none:
                return !needsModel
            }
        case .custom:
            return trimmedID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
                && !Set(store.providers.map(\.id)).contains(trimmedID)
                && !name.trimmingCharacters(in: .whitespaces).isEmpty
                && baseURL.count > "https://".count
                && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
                && contextWindow > 0 && maxOutput > 0
        }
    }

    private func needsKey(_ entry: ProviderCatalogEntry) -> Bool {
        entry.signInMode == .apiKey
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("添加 Provider 账户").font(LXType.title)
                Text("选择提供商，按其契约完成连接。保存前会先测试连接。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.vertical, LingXiMetrics.Space.lg)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.lg) {
                    pickerCard
                    if let entry = selectedEntry {
                        entryForm(entry)
                    } else {
                        customForm
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
                if selectedEntry?.signInMode == .browser {
                    Button(authFlow?.phase == .awaitingCallback ? "重新登录" : "登录") { startSignIn() }
                        .buttonStyle(LXButtonStyle(.primary, size: .regular))
                        .disabled(!isValid)
                } else {
                    Button(isTesting ? "测试中…" : "测试连接") { testConnection() }
                        .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                        .disabled(isTesting || !canTest)
                    Button(isSaving ? "连接中…" : (choice == .custom ? "添加" : "连接")) { save() }
                        .buttonStyle(LXButtonStyle(.primary, size: .regular))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid || isSaving)
                }
            }
            .padding(LingXiMetrics.Space.lg)
        }
        .frame(width: 640, height: 680)
        .modifier(WallpaperWindow())
        .lxNoInitialFocus()
        .lxSettingsControlStyles()
        .task {
            if store.providerCatalog.isEmpty { await store.loadProviderCatalog(refresh: false) }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: 提供商

    private var pickerCard: some View {
        LXSettingsCard(title: LXSettingsSectionHeader("提供商"), rowSpacing: LingXiMetrics.Space.xs, accessory: {
            Button(isRefreshingCatalog ? "刷新中…" : "刷新列表") {
                isRefreshingCatalog = true
                Task {
                    await store.loadProviderCatalog(refresh: true)
                    isRefreshingCatalog = false
                }
            }
            .disabled(isRefreshingCatalog)
        }) {
            NativeSearchField(text: $query, prompt: "搜索提供商")
                .navigatorChrome()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    choiceRow(id: "custom", name: "自定义中转 / 自建端点",
                              mode: "API Key", models: nil, connected: false)
                    ForEach(entries) { entry in
                        choiceRow(id: entry.id, name: entry.name, mode: Self.modeLabel(entry),
                                  models: entry.modelCount, connected: connectedIDs.contains(entry.id),
                                  connectable: entry.connectable)
                    }
                }
            }
            .frame(maxHeight: 200)
        } footer: {
            Text("共 \(store.providerCatalog.count) 个提供商，来自 Core 的注册表与 models.lingxifox.cn 索引；端点、协议与模型清单由目录提供。")
        }
    }

    private func choiceRow(id: String, name: String, mode: String, models: Int?,
                           connected: Bool, connectable: Bool = true) -> some View {
        let selected: Choice = id == "custom" ? .custom : .entry(id)
        return Button { select(id) } label: {
            HStack(spacing: LingXiMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(LXType.body).lineLimit(1)
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text(mode).font(LXType.meta).foregroundStyle(.secondary)
                        if let models {
                            Text("· \(models) 个模型").font(LXType.meta).foregroundStyle(.secondary)
                        }
                        if !connectable {
                            Text("· 驱动未支持").font(LXType.meta).foregroundStyle(LXColor.warning)
                        }
                    }
                }
                Spacer(minLength: LingXiMetrics.Space.sm)
                if connected { LXBadge("已连接") }
                if choice == selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(LXColor.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(minHeight: LingXiMetrics.Size.rowList)
        }
        .buttonStyle(.plain)
    }

    private func select(_ id: String) {
        choice = id == "custom" ? .custom : .entry(id)
        testResult = nil
        authFlow = nil
        catalogModels = []
        catalogNote = nil
        chosenModels = []
        modelQuery = ""
        guard let entry = store.providerCatalog.first(where: { $0.id == id }) else { return }
        Task {
            let roster = await store.providerCatalogModels(entryID: entry.id)
            guard choice == .entry(entry.id) else { return }
            catalogModels = roster.models
            catalogNote = roster.note
            chosenModels = Set(roster.models)
        }
    }

    static func modeLabel(_ entry: ProviderCatalogEntry) -> String {
        switch entry.signInMode {
        case .apiKey: return "API Key"
        case .browser: return "登录账户"
        case .localEndpoint: return "本地端点"
        case .none: return "无需凭据"
        }
    }

    // MARK: 所选提供商的表单

    @ViewBuilder private func entryForm(_ entry: ProviderCatalogEntry) -> some View {
        LXSettingsCard(title: LXSettingsSectionHeader("连接")) {
            ValueRow(title: "接入方式", value: Self.modeLabel(entry))
            switch entry.signInMode {
            case .browser:
                if let authFlow {
                    LabeledContent("状态") {
                        LXStatusText(Self.authText(authFlow.phase), systemImage: Self.authImage(authFlow.phase),
                                     tone: Self.authTone(authFlow.phase))
                    }
                    .lxSettingsRow()
                    if let message = authFlow.message {
                        LXStatusText(message, systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                }
            case .apiKey, .localEndpoint, .none:
                if needsKey(entry) {
                    LabeledContent("API Key") {
                        SecureField("粘贴 API Key", text: $apiKey)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .font(LXType.mono).frame(width: 280)
                    }
                    .lxSettingsRow()
                }
                if entry.signInMode == .localEndpoint {
                    LXTextRow(title: "本地端点", info: "目录给出的地址留空时沿用目录值。",
                              text: $endpoint, prompt: "http://127.0.0.1:11434/v1", monospaced: true)
                }
                ForEach(entry.requiredAccountFields, id: \.self) { field in
                    LXTextRow(title: field, text: binding(for: field))
                }
            }
            if let testResult {
                LXStatusText(testResult.reachable
                    ? "连接可达" + (testResult.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? "")
                        + (testResult.message.map { " · \($0)" } ?? "")
                    : "连接失败：\(testResult.message ?? "未知错误")",
                    systemImage: testResult.reachable ? "checkmark.circle" : "xmark.circle",
                    tone: testResult.reachable ? .success : .danger)
            }
            if !entry.connectable {
                LXStatusText("该提供商的接口驱动本机运行时还不支持，无法从这里连接。",
                             systemImage: "exclamationmark.triangle", tone: .warning)
            }
        } footer: {
            Text("端点、协议与模型清单来自目录。"
                 + (entry.signInMode == .browser
                    ? "登录由 Core 完成：浏览器授权后由 Core 接收回调并保存凭据，本窗口不会看到令牌。"
                    : "API Key 由 CredentialBroker 保存，不下发给子 Agent 或 MCP，也不会以明文显示。"))
        }

        if needsModelChoice {
            LXSettingsCard(title: LXSettingsSectionHeader("模型"), rowSpacing: LingXiMetrics.Space.xs, accessory: {
                Button("全选") { chosenModels = Set(catalogModels) }
                Button("清空") { chosenModels = [] }
            }) {
                NativeSearchField(text: $modelQuery, prompt: "搜索模型")
                    .navigatorChrome()
                if catalogModels.isEmpty {
                    PlaceholderLine(modelQuery.isEmpty
                        ? (catalogNote ?? "目录未列出该提供商的模型。")
                        : "没有匹配的模型。")
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            ForEach(visibleModels, id: \.self) { model in
                                modelRow(model)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            } footer: {
                Text("已选 \(chosenModels.count) 个。未填的字段跟随 models.lingxifox.cn 的元数据。")
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        Button {
            if chosenModels.contains(model) { chosenModels.remove(model) } else { chosenModels.insert(model) }
        } label: {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: chosenModels.contains(model) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosenModels.contains(model) ? LXColor.accent : Color.secondary)
                Text(model).font(LXType.monoSmall).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(minHeight: LingXiMetrics.Size.rowList)
        }
        .buttonStyle(.plain)
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(get: { fieldValues[field] ?? "" }, set: { fieldValues[field] = $0 })
    }

    // MARK: 自定义中转

    private var customForm: some View {
        Group {
            LXSettingsCard(title: LXSettingsSectionHeader("连接")) {
                LXTextRow(title: "名称", text: $name, prompt: "例如：公司中转")
                LXTextRow(title: "ID", info: "providers.json 中的键，也是模型名前缀，如 relay/model。",
                          text: $providerID, prompt: "relay", monospaced: true)
                LabeledContent("接口类型") {
                    Picker("接口类型", selection: $adapter) {
                        ForEach(ProviderAdapterOption.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                .lxSettingsRow()
                LXTextRow(title: "Base URL", text: $baseURL, prompt: "https://", monospaced: true)
                LabeledContent("API Key") {
                    SecureField("粘贴 API Key", text: $apiKey)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .font(LXType.mono).frame(width: 280)
                }
                .lxSettingsRow()
                LXTextRow(title: "API Key 请求头", text: $apiKeyHeader, prompt: "Authorization", monospaced: true)
            } footer: {
                Text("自己搭的中转或内网端点，写入 providers.json。API Key 由 CredentialBroker 保存，"
                     + "不下发给子 Agent 或 MCP，也不会以明文显示。")
            }
            LXSettingsCard("首个模型") {
                LXTextRow(title: "模型 ID", text: $modelID, prompt: "例如 deepseek-v4-flash", monospaced: true)
                LXNumberRow(title: "上下文窗口", value: $contextWindow.optional, unit: "tokens")
                LXNumberRow(title: "输出上限", value: $maxOutput.optional, unit: "tokens")
            }
            if let testResult {
                LXStatusText(testResult.reachable
                    ? "连接可达" + (testResult.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? "")
                    : "连接失败：\(testResult.message ?? "未知错误")",
                    systemImage: testResult.reachable ? "checkmark.circle" : "xmark.circle",
                    tone: testResult.reachable ? .success : .danger)
            }
        }
    }

    private var canTest: Bool {
        switch choice {
        case .custom: return baseURL.count > "https://".count
        case .entry(let id):
            guard let entry = store.providerCatalog.first(where: { $0.id == id }) else { return false }
            if !entry.connectable { return false }
            if entry.signInMode == .localEndpoint { return true }
            return true
        }
    }

    // MARK: 动作

    private func testConnection() {
        isTesting = true
        Task {
            defer { isTesting = false }
            await stageKeyIfNeeded()
            switch choice {
            case .custom:
                testResult = await store.testProviderDraft(TestProviderDraftRequest(
                    adapter: adapter, baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                    apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
                    credentialRef: stagedRef))
            case .entry(let id):
                testResult = await store.testProviderDraft(TestProviderDraftRequest(
                    credentialRef: stagedRef, productID: id))
            }
        }
    }

    /// Writes a typed key into Core's vault once and keeps only its reference.
    private func stageKeyIfNeeded() async {
        guard stagedRef == nil else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        stagedRef = await store.stageSecret(key)
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            await stageKeyIfNeeded()
            switch choice {
            case .custom:
                let request = SaveProviderConfigurationRequest(
                    providerID: trimmedID,
                    name: name.trimmingCharacters(in: .whitespaces),
                    adapter: adapter,
                    baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                    apiKeyHeader: apiKeyHeader.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKeyHeader,
                    apiKey: stagedRef.map { SecretUpdate.staged(reference: $0) } ?? .keep,
                    models: [ProviderModelConfigurationDetail(
                        modelID: modelID.trimmingCharacters(in: .whitespaces),
                        name: modelID.trimmingCharacters(in: .whitespaces),
                        contextWindow: contextWindow, maxOutputTokens: maxOutput)])
                if let saved = await store.saveProvider(request) {
                    stagedRef = nil
                    onFinish(saved.providerID)
                } else if let staged = stagedRef {
                    await store.discardStagedSecret(staged)
                    stagedRef = nil
                }
            case .entry(let id):
                let fields = fieldValues.filter { !$0.value.isEmpty }
                let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
                if let account = await store.connectProvider(ConnectProviderRequest(
                    productID: id, credentialRef: stagedRef,
                    endpoint: trimmedEndpoint.isEmpty ? nil : trimmedEndpoint,
                    fields: fields, modelIDs: Array(chosenModels).sorted())) {
                    stagedRef = nil
                    onFinish(account.id)
                } else if let staged = stagedRef {
                    await store.discardStagedSecret(staged)
                    stagedRef = nil
                }
            }
        }
    }

    private func startSignIn() {
        guard case .entry(let id) = choice else { return }
        pollTask?.cancel()
        Task {
            guard let flow = await store.beginProviderAuth(productID: id) else { return }
            authFlow = flow
            if let string = flow.authorizeURL, let url = URL(string: string) { openURL(url) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let status = await store.providerAuthStatus(flowID: flow.flowID) else { break }
                authFlow = status
                if status.phase == .connected { onFinish(nil); break }
                if status.phase == .failed || status.phase == .cancelled { break }
            }
        }
    }

    private func dismiss() {
        pollTask?.cancel()
        if let stagedRef {
            Task { await store.discardStagedSecret(stagedRef) }
        }
        onFinish(nil)
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
}

#endif
