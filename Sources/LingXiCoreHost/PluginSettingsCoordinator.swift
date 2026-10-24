import Foundation
import LingXiCredentialStore
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol

/// Owns settings sessions. A session always gets its own Host process: settings never run inside the
/// provider instance, and a disabled plugin can still be configured without gaining routes or hooks.
actor PluginSettingsCoordinator {
    enum SettingsError: Error, CustomStringConvertible, Equatable {
        case notInstalled(String)
        case noSettingsView
        case frameMissing
        case invalidFrame(String)
        case rejected(String)
        case configMissing
        case sessionMissing
        case busy(String)
        case cancelled
        case saveFailed(String)
        case applyFailed(String)
        case commitFailed(String)
        case credentialNotDeclared(String)
        case credentialConfirmationRequired
        case rollbackFailed(String)

        var description: String {
            switch self {
            case .notInstalled(let bundleID): "plugin \(bundleID) is not installed"
            case .noSettingsView: "the plugin did not declare a settings view"
            case .frameMissing: "the plugin returned no frame"
            case .invalidFrame(let reason): "the plugin returned an invalid frame: \(reason)"
            case .rejected(let reason): "the plugin rejected the settings: \(reason)"
            case .configMissing: "the plugin did not return a candidate configuration"
            case .sessionMissing: "the settings session is no longer open"
            case .busy(let bundleID): "another settings operation is in progress for \(bundleID)"
            case .cancelled: "the settings session was cancelled before the save committed"
            case .saveFailed(let reason): "settings could not be saved: \(reason)"
            case .applyFailed(let reason): "settings could not be applied: \(reason)"
            case .commitFailed(let reason): "settings could not be committed: \(reason)"
            case .credentialNotDeclared(let providerID): "the plugin does not declare credential provider \(providerID)"
            case .credentialConfirmationRequired: "credential removal requires explicit host confirmation"
            case .rollbackFailed(let reason): "settings rollback failed: \(reason)"
            }
        }
    }

    private struct Live {
        let id: String
        let bundleID: String
        let title: String
        let version: String
        let capability: String?
        let plugin: PluginSession?
        var viewport: SettingsViewport
        var frame: SettingsFrame
        var command: SettingsCommand?
        /// Plugin-reported draft state. `nil` means the plugin does not track it; the frontend then
        /// treats the window as dirty rather than silently discarding a draft on Escape.
        var dirty: Bool?
        var lastInvoke: Date
    }

    private let registry: PluginRegistry
    private let hostExecutableURL: URL
    private let policy: SignaturePolicy
    private let store: PluginSettingsStore
    private let running: PluginCoordinator
    private let credentials: CredentialAuthority
    private var sessions: [String: Live] = [:]
    private var opening: Set<String> = []
    private var saving: Set<String> = []
    private var cancelled: Set<String> = []
    private var closedSessions: Set<String> = []
    private var shuttingDown = false
    private var preferredModels: [String: String] = [:]

    init(
        registry: PluginRegistry, hostExecutableURL: URL, policy: SignaturePolicy,
        store: PluginSettingsStore, running: PluginCoordinator, credentials: CredentialAuthority
    ) {
        self.registry = registry
        self.hostExecutableURL = hostExecutableURL
        self.policy = policy
        self.store = store
        self.running = running
        self.credentials = credentials
    }

    func open(bundleID: String, viewport: SettingsViewport) async throws -> SettingsSnapshot {
        guard !shuttingDown else { throw SettingsError.sessionMissing }
        guard let entry = await registry.entry(bundleID) else {
            throw SettingsError.notInstalled(bundleID)
        }
        guard !opening.contains(bundleID), !saving.contains(bundleID) else {
            throw SettingsError.busy(bundleID)
        }
        opening.insert(bundleID)
        cancelled.remove(bundleID)
        defer { opening.remove(bundleID) }
        // Closing a previous session removes it from the map first; otherwise a late reply could
        // still find and mutate a session whose host is already gone.
        if let existing = sessions.values.first(where: { $0.bundleID == bundleID }) {
            sessions.removeValue(forKey: existing.id)
            await close(existing, cancel: true)
        }

        let plugin = PluginSession(
            bundlePath: entry.bundlePath, hostExecutableURL: hostExecutableURL,
            timeout: .seconds(5)
        )
        do {
            // Settings are capability-scoped: never hand the settings-only host the registry's
            // provider grants (recording paths, fault hooks) that a normal run would receive.
            try await plugin.enable(policy: policy, grantedPermissions: [])
            guard await plugin.bundleID == bundleID else {
                throw SettingsError.notInstalled(bundleID)
            }
            guard let capability = await plugin.settingsCapability else {
                await plugin.disable()
                return try fallback(entry: entry, viewport: viewport)
            }
            let sessionID = UUID().uuidString
            let stored = try await store.load(bundleID: bundleID)
        if let preferred = stored?.preferredModel { preferredModels[bundleID] = preferred }
        let config = stored?.config ?? .object([:])
            let statuses = credentialStatuses(bundleID: bundleID, providers: await plugin.providers)
            let response = try await invoke(
                plugin: plugin, capability: capability,
                invocation: SettingsInvocation(
                    op: .open, sessionID: sessionID, viewport: viewport.clamped,
                    config: config, credentials: statuses
                )
            )
            let frame = try validated(response.frame, viewport: viewport)
            let live = Live(
                id: sessionID, bundleID: bundleID,
                title: response.title ?? bundleID, version: entry.version,
                capability: capability, plugin: plugin,
                viewport: viewport.clamped, frame: frame, command: response.command,
                dirty: response.dirty, lastInvoke: .distantPast
            )
            sessions[sessionID] = live
            return snapshot(live)
        } catch {
            await plugin.disable()
            throw error
        }
    }

    func input(sessionID: String, input: SettingsInput) async throws -> SettingsSnapshot {
        guard var live = sessions[sessionID] else { throw SettingsError.sessionMissing }
        guard let plugin = live.plugin, let capability = live.capability else {
            return snapshot(live)
        }
        live.lastInvoke = Date()
        do {
            let response = try await invoke(
                plugin: plugin, capability: capability,
                invocation: SettingsInvocation(
                    op: .input, sessionID: sessionID, viewport: live.viewport, input: input
                )
            )
            live.frame = try validated(response.frame ?? SettingsFrame(rows: []), viewport: live.viewport)
            live.command = response.command
            live.dirty = response.dirty
            sessions[sessionID] = live
            return snapshot(live)
        } catch {
            // A dead or timed-out host must not leave an addressable ghost session.
            sessions.removeValue(forKey: sessionID)
            await close(live, cancel: false)
            throw error
        }
    }

    func resize(sessionID: String, viewport: SettingsViewport) async throws -> SettingsSnapshot {
        guard var live = sessions[sessionID] else { throw SettingsError.sessionMissing }
        live.viewport = viewport.clamped
        if let plugin = live.plugin, let capability = live.capability {
            do {
                let response = try await invoke(
                    plugin: plugin, capability: capability,
                    invocation: SettingsInvocation(
                        op: .resize, sessionID: sessionID, viewport: live.viewport
                    )
                )
                if let frame = response.frame {
                    live.frame = try validated(frame, viewport: live.viewport)
                }
                live.command = response.command
                live.dirty = response.dirty
            } catch {
                sessions.removeValue(forKey: sessionID)
                await close(live, cancel: false)
                throw error
            }
        }
        sessions[sessionID] = live
        return snapshot(live)
    }

    func save(sessionID: String) async throws {
        guard !shuttingDown else { throw SettingsError.sessionMissing }
        guard let live = sessions[sessionID] else { throw SettingsError.sessionMissing }
        guard live.plugin != nil, live.capability != nil else {
            sessions[sessionID] = nil
            await close(live, cancel: false)
            return
        }
        guard !saving.contains(live.bundleID) else { throw SettingsError.busy(live.bundleID) }
        saving.insert(live.bundleID)
        cancelled.remove(sessionID)
        defer {
            saving.remove(live.bundleID)
            cancelled.remove(sessionID)
        }

        do {
            try await performSave(sessionID: sessionID, live: live)
        } catch {
            if case SettingsError.cancelled = error {
                sessions.removeValue(forKey: sessionID)
                await close(live, cancel: true)
            } else if await !(live.plugin?.isRunning ?? false) {
                // A dead settings host cannot be retried; remove the window rather than leaving an
                // unusable session around until shutdown.
                sessions.removeValue(forKey: sessionID)
                await close(live, cancel: false)
            }
            throw error
        }

        sessions.removeValue(forKey: sessionID)
        await close(live, cancel: false)
    }

    /// Runs the prepare/write/apply/commit transaction. It never closes the session: the caller
    /// owns the one exit path so every throw (including cancellation) releases the host exactly once.
    private func performSave(sessionID: String, live: Live) async throws {
        guard let plugin = live.plugin, let capability = live.capability else {
            throw SettingsError.sessionMissing
        }
        let old = try await store.load(bundleID: live.bundleID)
        let oldPreferred = preferredModels[live.bundleID]
        let response = try await invoke(
            plugin: plugin, capability: capability,
            invocation: SettingsInvocation(
                op: .prepareSave, sessionID: sessionID, viewport: live.viewport
            )
        )
        guard !cancelled.contains(sessionID) else { throw SettingsError.cancelled }
        guard response.ok == true else {
            throw SettingsError.rejected(response.error ?? "the plugin rejected the configuration")
        }
        guard let config = response.config else { throw SettingsError.configMissing }
        guard config.object != nil else { throw SettingsError.rejected("configuration must be a JSON object") }

        guard !cancelled.contains(sessionID) else { throw SettingsError.cancelled }
        do {
            try await store.save(
                bundleID: live.bundleID, config: config,
                preferredModel: response.preferredModel
            )
        } catch {
            throw SettingsError.saveFailed("\(error)")
        }

        guard !cancelled.contains(sessionID) else {
            let rollback = await restore(old, bundleID: live.bundleID)
            if let rollback { throw SettingsError.rollbackFailed("cancel after write: \(rollback)") }
            throw SettingsError.cancelled
        }
        do {
            _ = try await running.applySettings(bundleID: live.bundleID, config: config)
        } catch {
            let rollback = await restore(old, bundleID: live.bundleID)
            if let rollback {
                throw SettingsError.rollbackFailed("apply failed: \(error); \(rollback)")
            }
            throw SettingsError.applyFailed("\(error)")
        }

        guard !cancelled.contains(sessionID) else {
            let rollback = await restore(old, bundleID: live.bundleID)
            if let rollback { throw SettingsError.rollbackFailed("cancel before commit: \(rollback)") }
            throw SettingsError.cancelled
        }
        do {
            let commit = try await invoke(
                plugin: plugin, capability: capability,
                invocation: SettingsInvocation(op: .commit, sessionID: sessionID, config: config)
            )
            guard commit.ok == true else {
                throw SettingsError.commitFailed(commit.error ?? "plugin returned ok=false")
            }
        } catch {
            restorePreferredModel(oldPreferred, bundleID: live.bundleID)
            let rollback = await restore(old, bundleID: live.bundleID)
            if let rollback {
                throw SettingsError.rollbackFailed("commit failed: \(error); \(rollback)")
            }
            throw SettingsError.commitFailed("\(error)")
        }

        // Commit is the last cancellation window. If the user cancelled while the plugin was
        // committing, restore the file, the running config and the plugin's commit state before
        // reporting cancellation; otherwise a cancel could silently publish a model preference.
        guard !cancelled.contains(sessionID) else {
            restorePreferredModel(oldPreferred, bundleID: live.bundleID)
            var failures: [String] = []
            if let rollback = await restore(old, bundleID: live.bundleID) {
                failures.append(rollback)
            }
            do {
                let oldConfig = old?.config ?? .object([:])
                let commit = try await invoke(
                    plugin: plugin, capability: capability,
                    invocation: SettingsInvocation(op: .commit, sessionID: sessionID, config: oldConfig)
                )
                if commit.ok != true {
                    failures.append("plugin commit rollback: \(commit.error ?? "ok=false")")
                }
            } catch {
                failures.append("plugin commit rollback: \(error)")
            }
            if !failures.isEmpty {
                throw SettingsError.rollbackFailed("cancel after commit: \(failures.joined(separator: "; "))")
            }
            throw SettingsError.cancelled
        }

        // Publish the preference only after every durable and runtime step committed. A failed
        // commit must not leave the TUI pointing at a model the plugin never accepted.
        if let preferred = response.preferredModel {
            preferredModels[live.bundleID] = preferred
        } else {
            preferredModels[live.bundleID] = nil
        }
    }

    private func restorePreferredModel(_ old: String?, bundleID: String) {
        if let old {
            preferredModels[bundleID] = old
        } else {
            preferredModels[bundleID] = nil
        }
    }

    /// Restores the previous durable file and the previous running configuration. Returns a
    /// non-nil description when any part of the rollback failed; callers must surface it rather
    /// than claiming the save was rejected cleanly.
    private func restore(_ old: PluginSettingsSnapshot?, bundleID: String) async -> String? {
        var failures: [String] = []
        do {
            if let old {
                try await store.save(
                    bundleID: bundleID, version: old.version, config: old.config,
                    preferredModel: old.preferredModel
                )
            } else {
                try await store.remove(bundleID: bundleID)
            }
        } catch {
            failures.append("settings file: \(error)")
        }
        do {
            _ = try await running.applySettings(
                bundleID: bundleID, config: old?.config ?? .object([:])
            )
        } catch {
            failures.append("runtime: \(error)")
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    func cancel(sessionID: String) async {
        guard let live = sessions[sessionID] else { return }
        sessions[sessionID] = nil
        cancelled.insert(sessionID)
        // A save already in flight owns teardown; it will observe this flag and roll back. Closing
        // the host underneath it would turn an ordinary cancel into a crash race.
        if saving.contains(live.bundleID) { return }
        cancelled.remove(sessionID)
        await close(live, cancel: true)
    }

    func shutdown() async {
        shuttingDown = true
        let all = Array(sessions.values)
        for live in all {
            // A save may be awaiting an IPC reply. Mark it cancelled so its exit path performs the
            // rollback, and close the host now; close() is idempotent if save reaches it later.
            cancelled.insert(live.id)
        }
        sessions.removeAll()
        for live in all { await close(live, cancel: true) }
    }

    func bundleID(forSessionID sessionID: String) -> String? {
        sessions[sessionID]?.bundleID
    }

    func preferredModel(forBundleID bundleID: String) -> String? {
        preferredModels[bundleID]
    }

    func preferredModelHint(bundleIDs: [String]) async -> String? {
        await store.preferredModelHint(bundleIDs: bundleIDs)
    }

    func preferredModel(forSessionID sessionID: String) -> String? {
        guard let live = sessions[sessionID] else { return nil }
        return preferredModels[live.bundleID]
    }

    // MARK: - credentials

    /// Resolves a credential action against the open settings session. The provider id supplied by
    /// the plugin is only a lookup key: it must match a provider and credential that this bundle
    /// actually declared. A malicious settings page cannot name another plugin's provider.
    func credentialBinding(
        sessionID: String, providerID: String
    ) async throws -> (bundleID: String, requirement: CredentialRequirement) {
        guard let live = sessions[sessionID], let plugin = live.plugin else {
            throw SettingsError.sessionMissing
        }
        guard await plugin.bundleID == live.bundleID else {
            throw SettingsError.credentialNotDeclared(providerID)
        }
        let providers = await plugin.providers
        guard let provider = providers.first(where: { $0.id == providerID }),
              let requirement = provider.credentials?.first else {
            throw SettingsError.credentialNotDeclared(providerID)
        }
        return (live.bundleID, requirement)
    }

    func credentialStatus(sessionID: String, providerID: String) async throws -> CredentialStatus {
        let binding = try await credentialBinding(sessionID: sessionID, providerID: providerID)
        let state = try credentials.availability(
            bundleID: binding.bundleID, providerID: providerID, requirement: binding.requirement
        )
        return CredentialStatus(
            providerID: state.providerID, credentialID: state.credentialID, label: state.label,
            source: state.source.rawValue, configured: state.configured
        )
    }

    func removeCredential(
        sessionID: String, providerID: String, confirmed: Bool
    ) async throws -> CredentialStatus {
        guard confirmed else { throw SettingsError.credentialConfirmationRequired }
        let binding = try await credentialBinding(sessionID: sessionID, providerID: providerID)
        try credentials.remove(
            bundleID: binding.bundleID, providerID: providerID, requirement: binding.requirement
        )
        let state = try credentials.availability(
            bundleID: binding.bundleID, providerID: providerID, requirement: binding.requirement
        )
        return CredentialStatus(
            providerID: state.providerID, credentialID: state.credentialID, label: state.label,
            source: state.source.rawValue, configured: state.configured
        )
    }

    // MARK: - helpers

    private func invoke(
        plugin: PluginSession, capability: String, invocation: SettingsInvocation
    ) async throws -> SettingsResponse {
        let payload = try JSONValue.encode(invocation)
        let raw = try await plugin.invoke(
            capability: capability, payload: payload, requestID: "settings-\(UUID().uuidString)"
        )
        return try raw.decode(SettingsResponse.self)
    }

    private func validated(_ frame: SettingsFrame?, viewport: SettingsViewport) throws -> SettingsFrame {
        guard let frame else { throw SettingsError.frameMissing }
        do {
            return try SettingsFrameValidator.validate(frame, viewport: viewport)
        } catch {
            throw SettingsError.invalidFrame("\(error)")
        }
    }

    private func snapshot(_ live: Live) -> SettingsSnapshot {
        let status: String
        if live.plugin == nil {
            status = "该插件未提供自定义设置页"
        } else if live.dirty == false {
            status = "无未保存修改"
        } else if live.dirty == nil {
            status = "插件未报告修改状态"
        } else {
            status = "设置草稿（未保存）"
        }
        return SettingsSnapshot(
            sessionID: live.id, bundleID: live.bundleID, title: live.title,
            version: live.version, status: status,
            viewport: live.viewport, frame: live.frame, command: live.command, dirty: live.dirty
        )
    }

    private func fallback(entry: PluginRegistry.Entry, viewport: SettingsViewport) throws -> SettingsSnapshot {
        let rows = [
            SettingsRow([SettingsSpan(entry.bundleID, fg: "fox", bold: true)]),
            SettingsRow([]),
            SettingsRow([SettingsSpan("版本  \(entry.version)")]),
            SettingsRow([SettingsSpan("状态  \(entry.enabled ? "已启用" : "已禁用")")]),
            SettingsRow([]),
            SettingsRow([SettingsSpan("该插件没有声明 settings.view.v1，", fg: "dim")]),
            SettingsRow([SettingsSpan("只能查看宿主提供的基础信息。", fg: "dim")]),
        ]
        let frame = try SettingsFrameValidator.validate(SettingsFrame(rows: rows), viewport: viewport)
        let sessionID = UUID().uuidString
        let live = Live(
            id: sessionID, bundleID: entry.bundleID, title: entry.bundleID,
            version: entry.version, capability: nil, plugin: nil,
            viewport: viewport.clamped, frame: frame, command: nil, dirty: false,
            lastInvoke: .distantPast
        )
        sessions[sessionID] = live
        return snapshot(live)
    }

    private func credentialStatuses(
        bundleID: String, providers: [ProviderIdentity]
    ) -> [SettingsCredentialStatus] {
        providers.flatMap { provider in
            (provider.credentials ?? []).compactMap { requirement in
                guard let state = try? credentials.availability(
                    bundleID: bundleID, providerID: provider.id, requirement: requirement
                ) else { return nil }
                return SettingsCredentialStatus(
                    providerID: provider.id, label: requirement.label,
                    configured: state.configured, source: state.source.rawValue
                )
            }
        }
    }

    private func close(_ live: Live, cancel: Bool) async {
        guard closedSessions.insert(live.id).inserted else { return }
        sessions.removeValue(forKey: live.id)
        if let plugin = live.plugin, let capability = live.capability, cancel {
            _ = try? await invoke(
                plugin: plugin, capability: capability,
                invocation: SettingsInvocation(op: .cancel, sessionID: live.id)
            )
        }
        await live.plugin?.disable()
    }
}
