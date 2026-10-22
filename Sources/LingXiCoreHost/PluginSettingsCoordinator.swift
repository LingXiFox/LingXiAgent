import Foundation
import LingXiCredentialStore
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
        case applyFailed(String)

        var description: String {
            switch self {
            case .notInstalled(let bundleID): "plugin \(bundleID) is not installed"
            case .noSettingsView: "the plugin did not declare a settings view"
            case .frameMissing: "the plugin returned no frame"
            case .invalidFrame(let reason): "the plugin returned an invalid frame: \(reason)"
            case .rejected(let reason): "the plugin rejected the settings: \(reason)"
            case .configMissing: "the plugin did not return a candidate configuration"
            case .sessionMissing: "the settings session is no longer open"
            case .applyFailed(let reason): "settings could not be applied: \(reason)"
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
        var lastInvoke: Date
    }

    private let registry: PluginRegistry
    private let hostExecutableURL: URL
    private let policy: SignaturePolicy
    private let store: PluginSettingsStore
    private let running: PluginCoordinator
    private let credentials: CredentialAuthority
    private var sessions: [String: Live] = [:]

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
        guard let entry = await registry.entry(bundleID) else {
            throw SettingsError.notInstalled(bundleID)
        }
        if let existing = sessions.values.first(where: { $0.bundleID == bundleID }) {
            await close(existing, cancel: true)
        }

        let plugin = PluginSession(bundlePath: entry.bundlePath, hostExecutableURL: hostExecutableURL)
        do {
            try await plugin.enable(policy: policy, grantedPermissions: entry.grants ?? [])
            guard let capability = await plugin.settingsCapability else {
                await plugin.disable()
                return try fallback(entry: entry, viewport: viewport)
            }
            let sessionID = UUID().uuidString
            let config = try await store.load(bundleID: bundleID)?.config ?? .object([:])
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
                lastInvoke: .distantPast
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
        let response = try await invoke(
            plugin: plugin, capability: capability,
            invocation: SettingsInvocation(
                op: .input, sessionID: sessionID, viewport: live.viewport, input: input
            )
        )
        live.frame = try validated(response.frame ?? SettingsFrame(rows: []), viewport: live.viewport)
        live.command = response.command
        sessions[sessionID] = live
        return snapshot(live)
    }

    func resize(sessionID: String, viewport: SettingsViewport) async throws -> SettingsSnapshot {
        guard var live = sessions[sessionID] else { throw SettingsError.sessionMissing }
        live.viewport = viewport.clamped
        if let plugin = live.plugin, let capability = live.capability {
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
        }
        sessions[sessionID] = live
        return snapshot(live)
    }

    func save(sessionID: String) async throws {
        guard let live = sessions[sessionID] else { throw SettingsError.sessionMissing }
        guard let plugin = live.plugin, let capability = live.capability else {
            sessions[sessionID] = nil
            return
        }
        let old = try await store.load(bundleID: live.bundleID)
        let response = try await invoke(
            plugin: plugin, capability: capability,
            invocation: SettingsInvocation(
                op: .prepareSave, sessionID: sessionID, viewport: live.viewport
            )
        )
        if response.ok == false {
            throw SettingsError.rejected(response.error ?? "the plugin rejected the configuration")
        }
        guard let config = response.config else { throw SettingsError.configMissing }
        guard config.object != nil else { throw SettingsError.rejected("configuration must be a JSON object") }
        try await store.save(bundleID: live.bundleID, config: config)
        do {
            try await running.applySettings(bundleID: live.bundleID, config: config)
        } catch {
            // Restore the previous durable configuration; the plugin's own side effects are out of
            // scope for this rollback (documented in ADR-0006).
            if let old {
                try? await store.save(bundleID: live.bundleID, version: old.version, config: old.config)
            } else {
                try? await store.remove(bundleID: live.bundleID)
            }
            throw SettingsError.applyFailed("\(error)")
        }
        _ = try? await invoke(
            plugin: plugin, capability: capability,
            invocation: SettingsInvocation(op: .commit, sessionID: sessionID, config: config)
        )
        sessions[sessionID] = nil
        await plugin.disable()
    }

    func cancel(sessionID: String) async {
        guard let live = sessions[sessionID] else { return }
        sessions[sessionID] = nil
        await close(live, cancel: true)
    }

    func shutdown() async {
        let all = Array(sessions.values)
        sessions.removeAll()
        for live in all { await close(live, cancel: true) }
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
        SettingsSnapshot(
            sessionID: live.id, bundleID: live.bundleID, title: live.title,
            version: live.version,
            status: live.plugin == nil ? "该插件未提供自定义设置页" : "设置草稿（未保存）",
            viewport: live.viewport, frame: live.frame, command: live.command
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
            viewport: viewport.clamped, frame: frame, command: nil, lastInvoke: .distantPast
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
        if let plugin = live.plugin, let capability = live.capability, cancel {
            _ = try? await invoke(
                plugin: plugin, capability: capability,
                invocation: SettingsInvocation(op: .cancel, sessionID: live.id)
            )
        }
        await live.plugin?.disable()
    }
}
