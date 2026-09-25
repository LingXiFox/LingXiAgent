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
    @Published private(set) var providerStatus: ProviderStatus?
    @Published private(set) var providerTests: [String: TestProviderResult] = [:]
    @Published private(set) var models: [ProviderModelInfo] = []
    @Published private(set) var modelSelection: ModelSelectionInfo?
    @Published private(set) var extensions: [ExtensionInfo] = []
    @Published private(set) var contextPolicy: ContextCachePolicySnapshot?
    @Published private(set) var workspace: WorkspaceSummary?
    @Published private(set) var worktrees: [WorkspaceWorktreeInfo] = []
    @Published private(set) var backgroundTasks: [BackgroundTaskSnapshot] = []
    @Published private(set) var providerMetrics: ProviderMetricsInfo?
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
        return (configFile.value(at: key.path) as? Value) ?? key.fallback
    }

    func isOverridden<Value>(_ key: ConfigKey<Value>) -> Bool {
        configFile.value(at: key.path) != nil
    }

    func binding<Value>(_ key: ConfigKey<Value>) -> Binding<Value> {
        Binding(
            get: { self.config(key) },
            set: { self.writeConfig($0, at: key.path) }
        )
    }

    func resetConfig<Value>(_ key: ConfigKey<Value>) {
        writeConfig(nil, at: key.path)
    }

    private func writeConfig(_ value: Any?, at path: [String]) {
        do {
            try configFile.set(value, at: path)
            configRevision += 1
            notice = client == nil ? nil : "已写入 config.json，Core 重新加载配置后生效。"
        } catch {
            notice = error.localizedDescription
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

    /// Re-reads every live section. Endpoints are independent: one failing
    /// (e.g. an unimplemented domain) leaves that section empty, not the page.
    func refresh() async {
        configFile.reload()
        configRevision += 1
        preferences = preferencesStore.load()
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let info = try? client.runtime.getInfo()
        async let health = try? client.runtime.getHealth()
        async let caps = try? client.runtime.getCapabilities()
        async let providers = try? client.provider.list()
        async let status = try? client.provider.status()
        async let models = try? client.model.list()
        async let selection = try? client.model.getSelection()
        async let extensions = try? client.extensionDomain.list()
        async let policy = try? client.context.getPolicy()
        async let workspace = try? client.workspace.summary()
        async let worktrees = try? client.workspace.listWorktrees()
        async let tasks = try? client.diagnostics.getBackgroundTasks()
        async let metrics = try? client.diagnostics.getProviderMetrics()

        self.runtimeInfo = await info
        self.health = await health
        self.capabilities = await caps
        self.providers = await providers ?? []
        self.providerStatus = await status
        self.models = await models ?? []
        self.modelSelection = await selection
        self.extensions = await extensions ?? []
        self.contextPolicy = await policy
        self.workspace = await workspace
        self.worktrees = await worktrees ?? []
        self.backgroundTasks = await tasks ?? []
        self.providerMetrics = await metrics
    }

    private func clearLiveState() {
        runtimeInfo = nil; health = nil; capabilities = nil
        providers = []; providerStatus = nil; providerTests = [:]
        models = []; modelSelection = nil; extensions = []
        contextPolicy = nil; workspace = nil; worktrees = []
        backgroundTasks = []; providerMetrics = nil
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
