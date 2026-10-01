#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine
import LingXiApplication
import LingXiClient
import LingXiProtocol

/// Backing model for the Settings window. Three sources, each the real owner
/// of its data — nothing here is a UI-only stand-in:
/// - `config.json`: global Core defaults (read by Core at start / reload)
/// - `preferences.json`: client preferences shared with the TUI
/// - Core RPC domains: providers, models, extensions, workspace, diagnostics
@MainActor
public final class SettingsStore: ObservableObject {

    public enum CoreLink: Equatable {
        case offline, connecting, connected
        case failed(String)
    }
    // MARK: Connection

    /// The main window's runtime owns the one Core connection; Settings reuses it.
    public weak var runtime: RuntimeFrontend? {
        didSet {
            runtimeObservation = runtime?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    private var runtimeObservation: AnyCancellable?
    var client: LingXiClientVNext? { runtime?.client }

    var link: CoreLink {
        switch runtime?.link ?? .disconnected {
        case .disconnected: return .offline
        case .connecting: return .connecting
        case .connected: return client == nil ? .offline : .connected
        case .failed(let message): return .failed(message)
        }
    }

    /// Workspace Settings would start a Core in; defaults to the open one.
    @AppStorage("lx.settings.workspaceRoot") public var workspaceRoot: String = ""

    // MARK: Live Core state

    @Published private(set) var runtimeInfo: RuntimeInfo?
    @Published private(set) var health: RuntimeHealth?
    @Published private(set) var capabilities: RuntimeCapabilities?
    @Published private(set) var providers: [ProviderAccountInfo] = []
    /// Every provider Core knows: curated registry plus the published models index.
    @Published private(set) var providerCatalog: [ProviderCatalogEntry] = []
    @Published private(set) var providerStatus: ProviderStatus?
    @Published private(set) var providerTests: [String: TestProviderResult] = [:]
    @Published private(set) var models: [ProviderModelInfo] = []
    @Published private(set) var modelSelection: ModelSelectionInfo?
    @Published private(set) var extensions: [ExtensionInfo] = []
    @Published private(set) var contextPolicy: ContextCachePolicySnapshot?
    @Published private(set) var workspace: WorkspaceSummary?
    /// Language servers Core reports as running; nil until the first refresh.
    @Published private(set) var languageServices: [LanguageServiceStatus]?
    /// Core's own answer about the tools the Computer Use page displays.
    static let reportedToolIDs = ["browser_navigate", "browser_act", "computer_batch"]
    @Published private(set) var toolStatus: [String: ToolStatusEntry]?
    @Published private(set) var worktrees: [WorkspaceWorktreeInfo] = []
    /// `mcp.json` servers as stored (the form's source of truth).
    @Published private(set) var mcpServers: [MCPServerConfigurationDetail] = []
    /// Set after an MCP write: connections change only when Core restarts.
    @Published var mcpNeedsRestart = false
    @Published private(set) var backgroundTasks: [BackgroundTaskSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published var notice: String?

    // MARK: Local documents

    private let configFile: CoreConfigFile
    private let preferencesStore: UserPreferencesStore
    /// Bumped on every config write so bindings re-read the document.
    @Published private(set) var configRevision = 0
    @Published private(set) var preferences: UserPreferences

    public init(configURL: URL? = nil, preferencesStore: UserPreferencesStore = .shared) {
        self.configFile = configURL.map(CoreConfigFile.init(url:)) ?? CoreConfigFile()
        self.preferencesStore = preferencesStore
        self.preferences = preferencesStore.load()
    }

    var configURL: URL { configFile.url }
    var isConfigReadable: Bool { configFile.isReadable }

    // MARK: - Config bindings

    func config<Value>(_ key: ConfigKey<Value>) -> Value {
        _ = configRevision
        return key.resolve(in: configFile)
    }

    func isOverridden<Value>(_ key: ConfigKey<Value>) -> Bool {
        key.isOverridden(in: configFile)
    }

    func binding<Value>(_ key: ConfigKey<Value>) -> Binding<Value> {
        Binding(
            get: { self.config(key) },
            set: { self.writeConfig($0, at: key.path) }
        )
    }

    func resetConfig<Value>(_ key: ConfigKey<Value>) {
        for path in key.clearPaths {
            writeConfig(nil, at: path)
        }
    }

    /// Writes or removes an override for a whole key, legacy spellings included.
    /// `nil` removes it, which is how "Core decides" is expressed in config.json.
    func writeOverride<Value>(_ key: ConfigKey<Value>, _ value: Value?) {
        for path in key.clearPaths { writeConfig(value, at: path) }
    }

    /// How a written setting becomes effective. §16 requires every control to declare one of
    /// these, because a banner that only says "reload required" and offers no way to do it —
    /// while the real reload button sits buried on the Diagnostics page — is a half-truth.
    public enum ConfigApply: Sendable {
        case instant, reloadConfiguration, restartCore, nextSession, nextTurn
    }

    /// The action the notice bar should offer for the last write. `.instant` means nothing to do.
    @Published public var pendingApply: ConfigApply = .instant

    private func writeConfig(_ value: Any?, at path: [String]) {
        do {
            try configFile.set(value, at: path)
            configRevision += 1
            guard client != nil else {
                pendingApply = .instant
                notice = nil
                return
            }
            pendingApply = Self.applySemantics(for: path.joined(separator: "."))
            notice = switch pendingApply {
            case .instant: nil
            case .reloadConfiguration: "已写入 config.json，点击「重新加载 Core」生效。"
            case .restartCore: "已写入 config.json，需要重启 Core 才能生效。"
            case .nextSession: "已写入 config.json，下一个会话生效。"
            case .nextTurn: "已写入 config.json，下一轮对话生效。"
            }
        } catch {
            pendingApply = .instant
            notice = error.localizedDescription
        }
    }

    /// Almost everything in config.json is read when Core builds a runtime, so the honest default
    /// is "reload". The exceptions are listed rather than inferred from a prefix, because a
    /// wrong claim here is worse than a conservative one: telling a user a change is instant when
    /// it needs a reload is how settings appear to be ignored.
    static func applySemantics(for key: String) -> ConfigApply {
        switch key {
        case _ where key.hasPrefix("appearance.") || key.hasPrefix("conversation."):
            return .instant            // app-side preferences, no Core round trip
        case ConfigKeys.eCorePersistence.id:
            return .restartCore        // the store's own lifetime, not a per-turn parameter
        default:
            return .reloadConfiguration
        }
    }

    // MARK: - Preferences (shared with the TUI)

    func setExpandThinking(_ on: Bool) {
        preferencesStore.update(expandThinking: on)
        preferences = preferencesStore.load()
    }

    func setExpandTools(_ on: Bool) {
        preferencesStore.update(expandTools: on)
        preferences = preferencesStore.load()
    }

    func setDefaultReasoning(_ level: ReasoningEffortLevel) {
        preferencesStore.update(reasoningEffort: level.protocolEffort.rawValue)
        preferences = preferencesStore.load()
    }

    var defaultReasoning: ReasoningEffortLevel {
        preferences.lastReasoningEffort
            .flatMap(ReasoningEffort.init(rawValue:))
            .map(ReasoningEffortLevel.init(protocolEffort:)) ?? .auto
    }

    public var timelineDisclosureDefaults: TimelineDisclosureDefaults {
        TimelineDisclosureDefaults(expandThinking: preferences.expandThinking ?? false,
                                   expandTools: preferences.expandTools ?? false)
    }

    /// Composer defaults derived from the global settings, applied to each new window.
    public var composerDefaults: (mode: AgentRunMode, reasoning: ReasoningEffortLevel, permission: PermissionPreset) {
        let mode: AgentRunMode
        switch config(ConfigKeys.behaviorProfile) {
        case "plan": mode = .plan
        case "explore": mode = .explore
        default: mode = .build
        }
        let permission: PermissionPreset
        switch (config(ConfigKeys.permissionPolicy), config(ConfigKeys.executionProfile)) {
        case ("auto", "fullAccess"): permission = .yoloFullAccess
        case ("auto", _): permission = .autoWorkspace
        case (_, "fullAccess"): permission = .askFullAccess
        default: permission = .askWorkspace
        }
        return (mode, defaultReasoning, permission)
    }

    // MARK: - Core link

    /// Opens the chosen workspace in the main runtime (never a second Core).
    func connectCore() async {
        if client != nil {
            await refresh()
            return
        }
        var isDirectory: ObjCBool = false
        let root = workspaceRoot.isEmpty ? (RecentWorkspaces.all.first?.path ?? "") : workspaceRoot
        guard !root.isEmpty, FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue, let runtime else {
            notice = "请先选择工作区目录。"
            return
        }
        await runtime.openWorkspace(URL(fileURLWithPath: root))
        await refresh()
    }

    func disconnectCore() async {
        await runtime?.closeWorkspace()
        clearLiveState()
    }

    /// Which live sections a page actually reads.
    ///
    /// `refresh()` used to be all-or-nothing and `needsCore` used to say which pages wanted it at
    /// all — six pages that render provider lists, effective policy, workspace indexes, tool
    /// status, health and background tasks answered `false`, so opening them showed whatever the
    /// last unrelated page had left behind and printed no "not connected" banner. §15 asks each
    /// page to declare what it needs; this is the vocabulary it declares in.
    enum LiveDomain: Hashable {
        case runtime, providers, models, context, workspace, diagnostics, extensions
    }

    /// Re-reads every live section. Endpoints are independent: one failing
    /// (e.g. an unimplemented domain) leaves that section empty, not the page.
    func refresh() async {
        await refresh(domains: [.runtime, .providers, .models, .context, .workspace,
                                .diagnostics, .extensions])
    }

    func refresh(domains: Set<LiveDomain>) async {
        configFile.reload()
        configRevision += 1
        preferences = preferencesStore.load()
        guard let client, !domains.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Each group is awaited as a unit so a page that wants one domain does not pay for
        // fifteen round trips.
        if domains.contains(.runtime) {
            async let info = try? client.runtime.getInfo()
            async let health = try? client.runtime.getHealth()
            async let caps = try? client.runtime.getCapabilities()
            self.runtimeInfo = await info
            self.health = await health
            self.capabilities = await caps
        }
        if domains.contains(.providers) {
            async let providers = try? client.provider.list()
            async let catalog = try? client.provider.catalog()
            async let status = try? client.provider.status()
            self.providers = await providers ?? []
            self.providerCatalog = await catalog ?? []
            self.providerStatus = await status
        }
        if domains.contains(.models) {
            async let models = try? client.model.list()
            async let selection = try? client.model.getSelection()
            self.models = await models ?? []
            self.modelSelection = await selection
        }
        if domains.contains(.extensions) {
            async let extensions = try? client.extensionDomain.list()
            async let mcpServers = try? client.extensionDomain.mcpServers()
            self.extensions = await extensions ?? []
            self.mcpServers = await mcpServers ?? []
        }
        if domains.contains(.context) {
            self.contextPolicy = try? await client.context.getPolicy()
        }
        if domains.contains(.workspace) {
            async let workspace = try? client.workspace.get()
            async let languageServices = try? client.workspace.languageServices()
            async let toolStatus = try? client.workspace.toolStatus(Self.reportedToolIDs)
            async let worktrees = try? client.workspace.listWorktrees()
            self.workspace = await workspace
            self.languageServices = await languageServices
            self.toolStatus = (await toolStatus).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.toolID, $0) }) }
            self.worktrees = await worktrees ?? []
        }
        if domains.contains(.diagnostics) {
            self.backgroundTasks = (try? await client.diagnostics.getBackgroundTasks()) ?? []
        }
    }

    private func clearLiveState() {
        runtimeInfo = nil; health = nil; capabilities = nil
        providers = []; providerStatus = nil; providerTests = [:]
        providerCatalog = []
        models = []; modelSelection = nil; extensions = []
        contextPolicy = nil; workspace = nil; worktrees = []
        languageServices = nil
        toolStatus = nil
        backgroundTasks = []; mcpServers = []
    }

    // MARK: - Core commands

    private func perform(_ label: String, _ body: (LingXiClientVNext) async throws -> Void) async {
        guard let client else { notice = "未连接 Core。"; return }
        do {
            try await body(client)
            await refresh()
        } catch {
            notice = "\(label)失败：\(error.localizedDescription)"
        }
    }

    func testProvider(_ id: String) async {
        await perform("测试 Provider") { client in
            let receipt = try await client.provider.test(providerID: id)
            providerTests[id] = receipt.result
        }
    }

    func removeProvider(_ accountID: String) async {
        await perform("移除 Provider") { _ = try await $0.provider.remove(accountID: accountID) }
    }

    func reloadProviders() async {
        await perform("重新发现 Provider") { _ = try await $0.provider.reload() }
    }

    func selectDefaultModel(_ modelID: String) async {
        preferencesStore.update(modelID: modelID)
        preferences = preferencesStore.load()
        await perform("切换模型") { _ = try await $0.model.select(model: modelID) }
    }

    func setExtension(_ id: String, enabled: Bool) async {
        await perform(enabled ? "启用扩展" : "停用扩展") { client in
            _ = enabled ? try await client.extensionDomain.enable(id: id)
                        : try await client.extensionDomain.disable(id: id)
        }
    }

    func reloadExtensions() async {
        await perform("重新加载扩展") { _ = try await $0.extensionDomain.reload() }
    }

    func reloadConfiguration() async {
        await perform("重新加载配置") { _ = try await $0.runtime.reloadConfiguration() }
    }

    /// Pushes the configured approval policy and access scope to the running Core
    /// through the typed-setting channel Core already honours.
    func applyPermissionToCore() async {
        let configuration = composerDefaults.permission.configuration
        await perform("应用权限策略") {
            _ = try await $0.runtime.updateTypedSetting(key: "permissionConfiguration",
                                                        value: configuration.displayName)
        }
    }

    func terminateBackgroundTask(_ id: String) async {
        await perform("终止后台任务") { _ = try await $0.runtime.terminateBackgroundTask(id: id) }
    }

    func pruneWorktrees() async {
        await perform("清理 Worktree") { _ = try await $0.workspace.pruneWorktrees(force: false) }
    }

    func applyWorktree(_ id: String, message: String? = nil) async -> Bool {
        await performReporting("应用 Worktree") { _ = try await $0.workspace.applyWorktree(worktreeID: id, commitMessage: message) }
    }

    func discardWorktree(_ id: String) async -> Bool {
        await performReporting("丢弃 Worktree") { _ = try await $0.workspace.discardWorktree(worktreeID: id, force: true) }
    }

    // MARK: - providers.json

    /// Reloads the provider catalog, optionally forcing Core to refetch the
    /// published index first.
    func loadProviderCatalog(refresh: Bool) async {
        guard let client else { return }
        if let entries = try? await client.provider.catalog(refresh: refresh) {
            providerCatalog = entries
        }
    }

    func providerCatalogModels(entryID: String) async -> [String] {
        guard let client else { return [] }
        return (try? await client.provider.catalogModels(entryID: entryID)) ?? []
    }

    /// Products Core can actually sign a user in to; empty when the runtime
    /// offers no OAuth login.
    func providerAuthProducts() async -> [ProviderAuthProduct] {
        guard let client else { return [] }
        return (try? await client.provider.authProducts()) ?? []
    }

    /// Starts a sign-in in Core. The caller opens the returned URL in the system
    /// browser; tokens and the callback stay inside Core.
    func beginProviderAuth(productID: String) async -> ProviderAuthFlow? {
        guard let client else { notice = "未连接 Core。"; return nil }
        do {
            return try await client.provider.beginAuth(productID: productID)
        } catch {
            notice = "发起登录失败：\(error.localizedDescription)"
            return nil
        }
    }

    func providerAuthStatus(flowID: String) async -> ProviderAuthFlow? {
        guard let client else { return nil }
        let flow = try? await client.provider.authStatus(flowID: flowID)
        // Once the account exists, the provider list has to show it.
        if flow?.phase == .connected { await refresh() }
        return flow
    }

    func cancelProviderAuth(flowID: String) async {
        await perform("取消登录") { try await $0.provider.cancelAuth(flowID: flowID) }
    }

    /// Writes an unsaved key into Core's vault once and returns its reference, so
    /// the plaintext never travels inside a provider test or save request.
    /// Stores a secret and returns its reference. A nil always means "it did not save", and the
    /// user is told why: this used to swallow the error, so a failed write left the form showing
    /// nothing more than an unsaved field.
    func stageSecret(_ secret: String) async -> CredentialRef? {
        guard let client else {
            notice = "未连接 Core，凭据无法保存。"
            return nil
        }
        do {
            let receipt = try await client.credential.store(secret: secret)
            guard let reference = receipt.result?.reference else {
                notice = "Core 接受了写入但没有返回凭据引用，不能当作已保存。"
                return nil
            }
            return reference
        } catch {
            notice = "保存凭据失败：\(error.localizedDescription)"
            return nil
        }
    }

    func discardStagedSecret(_ reference: CredentialRef) async {
        await perform("清除暂存凭据") { _ = try await $0.credential.delete(reference: reference) }
    }

    /// Connects a registry product through its own contract.
    func connectProvider(_ request: ConnectProviderRequest) async -> ProviderAccountInfo? {
        guard let client else { notice = "未连接 Core。"; return nil }
        do {
            let account = try await client.provider.connect(request)
            notice = "已连接 \(account.displayName)。"
            return account
        } catch {
            notice = "连接失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// A real connection test of a provider that is not saved yet.
    func testProviderDraft(_ draft: TestProviderDraftRequest) async -> TestProviderResult? {
        guard let client else { notice = "未连接 Core。"; return nil }
        do {
            return try await client.provider.testDraft(draft)
        } catch {
            notice = "测试连接失败：\(error.localizedDescription)"
            return nil
        }
    }


    /// nil when the account is not a providers.json entry (OAuth / built-in).
    func providerConfiguration(_ providerID: String) async -> ProviderConfigurationDetail? {
        try? await client?.provider.configuration(providerID: providerID)
    }

    /// Validated and written by Core; the key goes to its vault.
    func saveProvider(_ request: SaveProviderConfigurationRequest) async -> ProviderConfigurationDetail? {
        guard let client else { notice = "未连接 Core。"; return nil }
        do {
            let detail = try await client.provider.saveConfiguration(request)
            notice = "已保存 \(detail.name)。"
            await refresh()
            return detail
        } catch {
            notice = "保存 Provider 失败：\(error.localizedDescription)"
            return nil
        }
    }

    func deleteProvider(_ providerID: String) async -> Bool {
        await performReporting("移除 Provider") { try await $0.provider.deleteConfiguration(providerID: providerID) }
    }

    // MARK: - mcp.json

    func saveMCPServer(_ request: SaveMCPServerRequest) async -> MCPServerConfigurationDetail? {
        guard let client else { notice = "未连接 Core。"; return nil }
        do {
            let detail = try await client.extensionDomain.saveMCPServer(request)
            mcpNeedsRestart = true
            notice = nil
            await refresh()
            return detail
        } catch {
            notice = "保存 MCP 服务器失败：\(error.localizedDescription)"
            return nil
        }
    }

    func deleteMCPServer(_ id: String) async -> Bool {
        let ok = await performReporting("移除 MCP 服务器") { try await $0.extensionDomain.deleteMCPServer(id: id) }
        if ok { mcpNeedsRestart = true }
        return ok
    }

    /// Restarts Core in the same workspace so new MCP connections take effect.
    func restartCore() async {
        guard let runtime, let workspace = runtime.workspaceURL else { return }
        await runtime.openWorkspace(workspace)
        mcpNeedsRestart = false
        await refresh()
    }

    /// Like `perform`, and tells the caller whether it worked.
    private func performReporting(_ label: String, _ body: (LingXiClientVNext) async throws -> Void) async -> Bool {
        guard let client else { notice = "未连接 Core。"; return false }
        do {
            try await body(client)
            await refresh()
            return true
        } catch {
            notice = "\(label)失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Diagnostics bundle as pretty JSON, for pasting into an issue.
    func diagnosticsBundleJSON() async -> String? {
        guard let client else { return nil }
        do {
            let bundle = try await client.diagnostics.getBundle()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return String(data: try encoder.encode(bundle), encoding: .utf8)
        } catch {
            notice = "导出诊断包失败：\(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - Reasoning level mapping

extension ReasoningEffortLevel {
    var protocolEffort: ReasoningEffort {
        switch self {
        case .auto: return .auto
        case .off: return .off
        case .low: return .low
        case .med: return .medium
        case .high: return .high
        case .max: return .max
        }
    }

    init(protocolEffort: ReasoningEffort) {
        switch protocolEffort {
        case .off: self = .off
        case .minimal, .low: self = .low
        case .medium: self = .med
        case .high, .xhigh: self = .high
        case .max, .ultra: self = .max
        case .auto: self = .auto
        }
    }
}

#endif
