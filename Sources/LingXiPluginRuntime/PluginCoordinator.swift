import Foundation
import LingXiKernel
import LingXiPluginABI

/// Ties the registry, the per-plugin host sessions, the kernel hook pipeline and - when a router is
/// supplied - the model routes together. This is the only object that knows both a plugin and the
/// kernel, and it lives outside both.
public actor PluginCoordinator {
    public struct Loaded: Sendable {
        public let bundleID: String
        public let capabilities: [DeclaredCapability]
    }

    public struct ProviderBinding: Sendable {
        public let declaration: ProviderIdentity
        public let adapter: PluginProviderAdapter
    }

    private let hostExecutableURL: URL
    private let registry: PluginRegistry
    private let pipeline: HookPipeline
    private let router: ModelRouter?
    private let credential: @Sendable (String, ProviderIdentity) throws -> String?
    private let settingsProvider: (any PluginSettingsProviding)?
    private var sessions: [String: PluginSession] = [:]
    private var handlerIDs: [String: [String]] = [:]
    private var adapters: [String: [PluginProviderAdapter]] = [:]
    private var disabling: Set<String> = []
    private var stateChangeHandler: (@Sendable () -> Void)?

    /// `credential` resolves a capability id to a secret the Core owns. It never comes from the host
    /// environment and is never written to a log; only the provider adapter puts it on the wire.
    public init(
        hostExecutableURL: URL,
        registry: PluginRegistry,
        pipeline: HookPipeline,
        router: ModelRouter? = nil,
        credential: @escaping @Sendable (String, ProviderIdentity) throws -> String? = { _, _ in nil },
        settingsProvider: (any PluginSettingsProviding)? = nil
    ) {
        self.hostExecutableURL = hostExecutableURL
        self.registry = registry
        self.pipeline = pipeline
        self.router = router
        self.credential = credential
        self.settingsProvider = settingsProvider
    }

    /// Installs a bundle in the registry without starting it. Enabling is a separate, explicit act.
    public func install(bundleID: String, version: String, bundlePath: String) async throws {
        try await registry.upsert(.init(bundleID: bundleID, version: version, bundlePath: bundlePath, enabled: false))
    }

    /// Called after any change to running/enabled state, including unexpected exits. The Core uses
    /// it to refresh the frontend without polling.
    public func setStateChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        stateChangeHandler = handler
    }

    /// Starts a plugin, mounts its hooks and registers its model routes. Registration is atomic per
    /// provider; any failure rolls back everything this call installed, including the host process.
    @discardableResult
    public func enable(
        bundleID: String,
        policy: SignaturePolicy = .restricted,
        grantedPermissions: [String] = []
    ) async throws -> Loaded {
        guard let entry = await registry.entry(bundleID) else {
            throw PluginSession.SessionError.handshake("plugin \(bundleID) is not installed")
        }
        if let existing = sessions[bundleID], await existing.isRunning {
            return Loaded(bundleID: bundleID, capabilities: await existing.capabilities)
        }

        let session = PluginSession(bundlePath: entry.bundlePath, hostExecutableURL: hostExecutableURL)
        var registered: [ProviderID] = []
        var mounted: [String] = []
        do {
            try await session.enable(policy: policy, grantedPermissions: grantedPermissions)
            guard await session.bundleID == bundleID else {
                throw PluginSession.SessionError.handshake("registered bundle id does not match loaded plugin")
            }
            for declaration in await session.providers {
                let validID: (String) -> Bool = { value in
                    !value.isEmpty && value.utf8.count <= 200 && value.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
                    }
                }
                guard validID(bundleID), validID(declaration.id),
                      (declaration.credentials ?? []).count <= 1,
                      (declaration.credentials ?? []).allSatisfy({ validID($0.id) && !$0.label.isEmpty }) else {
                    throw PluginSession.SessionError.handshake("invalid provider credential declaration; at most one API key is supported")
                }
            }
            await session.setUnexpectedExitHandler { [weak self] in
                Task { await self?.handleUnexpectedExit(bundleID: bundleID) }
            }

            // Apply the last committed settings before routes go live, so the first Run already
            // sees the user's protocol/thinking choices. This must be validated exactly like the
            // save path: an IPC success carrying ok:false is a failed enable, not a default run.
            if let settingsProvider, let snapshot = try await settingsProvider.settings(for: bundleID) {
                _ = try await applySettingsSnapshot(snapshot, to: session, bundleID: bundleID)
            }

            let deployments = await session.providers.map { declaration in
                (
                    declaration,
                    PluginProviderAdapter(
                        session: session,
                        providerID: declaration.id,
                        declaration: declaration,
                        credential: { [credential] in try credential(bundleID, declaration) }
                    )
                )
            }
            if let router {
                for (declaration, adapter) in deployments {
                    try await router.register(
                        provider: adapter,
                        id: ProviderID(declaration.id),
                        models: declaration.models.map { ModelID($0) }
                    )
                    registered.append(ProviderID(declaration.id))
                }
            }

            for capability in await session.capabilities where capability.kind == "hook" {
                let bridge = PluginHookBridge(bundleID: bundleID, declaration: capability, session: session)
                await pipeline.install(bridge)
                mounted.append(bridge.handlerID)
            }

            let capabilityLabels = await session.capabilities.map {
                $0.kind == "settings" ? $0.id : "\($0.kind).\($0.id)"
            } + session.providers.map { "provider.\($0.id)" }
            try await registry.upsert(.init(
                bundleID: entry.bundleID, version: entry.version, bundlePath: entry.bundlePath,
                enabled: true, grants: entry.grants,
                capabilities: capabilityLabels,
                permissions: await session.permissions
            ))

            sessions[bundleID] = session
            adapters[bundleID] = deployments.map(\.1)
            handlerIDs[bundleID] = mounted
            stateChangeHandler?()
            return Loaded(bundleID: bundleID, capabilities: await session.capabilities)
        } catch {
            for providerID in registered {
                if let router { _ = await router.unregister(providerID: providerID) }
            }
            for handlerID in mounted {
                _ = await pipeline.uninstall(handlerID: handlerID)
            }
            await session.disable()
            throw error
        }
    }

    /// Disables a plugin. The registry is written first: if the disk refuses, nothing is torn down
    /// and the caller sees why. After that, routes go, in-flight calls are cancelled, hooks unmount,
    /// and only then does the host stop. One plugin's teardown never touches another's routes.
    public func disable(bundleID: String) async throws {
        if disabling.contains(bundleID) { return }
        disabling.insert(bundleID)
        defer { disabling.remove(bundleID) }

        if let entry = await registry.entry(bundleID), entry.enabled {
            var disabled = entry
            disabled.enabled = false
            try await registry.upsert(disabled)
        }
        await teardown(bundleID)
        stateChangeHandler?()
    }

    public func uninstall(bundleID: String) async throws {
        try await disable(bundleID: bundleID)
        try await registry.remove(bundleID)
    }

    /// Process shutdown: tear hosts down without touching the registry. Exiting the Core is not the
    /// user disabling a plugin, and flipping `enabled` here would mean a restart never restores.
    public func shutdown() async {
        for bundleID in Array(sessions.keys) {
            await teardown(bundleID)
        }
    }

    public func isRunning(bundleID: String) async -> Bool {
        guard let session = sessions[bundleID] else { return false }
        return await session.isRunning
    }

    public func processIdentifier(bundleID: String) async -> Int32? {
        await sessions[bundleID]?.processIdentifier
    }

    public func runningBundleIDs() async -> [String] {
        var running: [String] = []
        for (bundleID, session) in sessions where await session.isRunning {
            running.append(bundleID)
        }
        return running.sorted()
    }

    /// Adapters created by the last successful enable. Exposed for read-only inspection and for tests
    /// that install a recording wrapper; the coordinator owns the routes when a router was supplied.
    public func providerBindings(bundleID: String) async -> [ProviderBinding] {
        guard let session = sessions[bundleID] else { return [] }
        let providers = await session.providers
        let built = adapters[bundleID] ?? []
        return Array(zip(providers, built)).map { ProviderBinding(declaration: $0.0, adapter: $0.1) }
    }

    /// Model metadata declared by running providers, for the frontend's model area. Routing
    /// authority stays with `ModelRouter`; this only reports what plugins declared.
    public func modelDeclarations() async -> [(providerID: String, model: ProviderModel)] {
        var result: [(String, ProviderModel)] = []
        for (_, session) in sessions {
            for declaration in await session.providers {
                let details = Dictionary(
                    (declaration.modelDetails ?? []).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for modelID in declaration.models {
                    // Plugins that have not declared metadata still get an entry, so the frontend
                    // never has to treat "absent from details" as a different kind of model.
                    result.append((declaration.id, details[modelID] ?? ProviderModel(id: modelID)))
                }
            }
        }
        return result.sorted {
            $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0
        }
    }

    /// Applies a committed settings snapshot to a running plugin. A disabled plugin is a no-op:
    /// its saved configuration is applied by `enable` when it starts again. The plugin must answer
    /// `ok: true`; an IPC success carrying a semantic rejection is still a failure here.
    @discardableResult
    public func applySettings(bundleID: String, config: JSONValue) async throws -> SettingsResponse {
        guard let session = sessions[bundleID], await session.isRunning else {
            return SettingsResponse(ok: true)
        }
        return try await applySettingsSnapshot(
            PluginSettingsSnapshot(version: 1, config: config),
            to: session, bundleID: bundleID
        )
    }

    // MARK: - live provider state and temporary thinking

    public struct ProviderStateReport: Sendable {
        public let providerID: String
        /// The plugin's own answer; `nil` when it declares no state capability.
        public let state: ProviderState?
        /// The frontend's temporary thinking selection, when one is active.
        public let reasoningOverride: String?
    }

    public enum ReasoningError: Error, CustomStringConvertible, Equatable {
        case invalidRequest
        case unknownProvider(String)
        case unknownModel(provider: String, model: String)
        case undeclaredLevel(provider: String, model: String, level: String)

        public var description: String {
            switch self {
            case .invalidRequest:
                "a reasoning level needs a provider and a model; clearing needs only the provider"
            case .unknownProvider(let provider):
                "no running provider \(provider)"
            case .unknownModel(let provider, let model):
                "provider \(provider) does not offer model \(model)"
            case .undeclaredLevel(let provider, let model, let level):
                "provider \(provider) does not declare thinking level \(level) for \(model)"
            }
        }
    }

    /// Installs one provider-wide temporary thinking level. The level must be one the provider
    /// declared for the model; an id the plugin never offered is refused instead of forwarded.
    public func setReasoningOverride(providerID: String, level: String?, model: String?) async throws {
        let bundleIDs = Array(sessions.keys)
        for bundleID in bundleIDs {
            guard let session = sessions[bundleID], await session.isRunning else { continue }
            let providers = await session.providers
            guard let index = providers.firstIndex(where: { $0.id == providerID }) else { continue }
            let declaration = providers[index]
            if let level {
                guard let model else { throw ReasoningError.invalidRequest }
                guard declaration.models.contains(model) else {
                    throw ReasoningError.unknownModel(provider: providerID, model: model)
                }
                let details = (declaration.modelDetails ?? []).first { $0.id == model }
                // Validation is against everything the plugin declared for this model. Which ladder
                // applies depends on the protocol the plugin will speak, which is the plugin's
                // business; the Core must not hardcode a protocol or a level vocabulary.
                let legacyLevels = details?.thinkingLevels ?? []
                let profileLevels = (details?.thinkingProfiles ?? []).flatMap(\.levels)
                guard (legacyLevels + profileLevels).contains(where: { $0.id == level }) else {
                    throw ReasoningError.undeclaredLevel(provider: providerID, model: model, level: level)
                }
            }
            guard let adapter = adapters[bundleID], index < adapter.count else {
                throw ReasoningError.unknownProvider(providerID)
            }
            adapter[index].setReasoningOverride(level)
            return
        }
        throw ReasoningError.unknownProvider(providerID)
    }

    /// Live state for every running provider. A provider that declares no state capability is
    /// reported with `state == nil` rather than a guessed default.
    public func providerStates() async -> [ProviderStateReport] {
        let snapshot = sessions
        let adapterSnapshot = adapters
        var result: [ProviderStateReport] = []
        for (bundleID, session) in snapshot where await session.isRunning {
            let providers = await session.providers
            let built = adapterSnapshot[bundleID] ?? []
            for (index, declaration) in providers.enumerated() {
                guard index < built.count else { continue }
                result.append(ProviderStateReport(
                    providerID: declaration.id,
                    state: await built[index].providerState(),
                    reasoningOverride: built[index].reasoningOverride
                ))
            }
        }
        return result.sorted { $0.providerID < $1.providerID }
    }

    /// One validation path for both startup restore and live save. A plugin that declares settings
    /// but has a saved snapshot must answer ok:true; a missing capability with a saved snapshot is a
    /// hard failure rather than a silent fallback to defaults.
    private func applySettingsSnapshot(
        _ snapshot: PluginSettingsSnapshot, to session: PluginSession, bundleID: String
    ) async throws -> SettingsResponse {
        guard let capability = await session.settingsCapability else {
            throw PluginSettingsApplyError.rejected(
                "plugin \(bundleID) has saved settings but does not declare a settings capability"
            )
        }
        let raw = try await session.invoke(
            capability: capability,
            payload: .encode(SettingsInvocation(op: .apply, config: snapshot.config)),
            requestID: "settings-apply-\(UUID().uuidString)"
        )
        let response = try raw.decode(SettingsResponse.self)
        guard response.ok == true else {
            throw PluginSettingsApplyError.rejected(response.error ?? "plugin returned ok=false")
        }
        return response
    }

    /// Only successfully enabled plugin declarations can authorize secret delivery.
    public func credentialProviders() async -> [(bundleID: String, declaration: ProviderIdentity)] {
        var result: [(String, ProviderIdentity)] = []
        for (bundleID, session) in sessions {
            for declaration in await session.providers { result.append((bundleID, declaration)) }
        }
        return result
    }

    // MARK: - teardown

    private func teardown(_ bundleID: String) async {
        if let session = sessions[bundleID] {
            let providers = await session.providers
            if let router {
                for declaration in providers {
                    _ = await router.unregister(providerID: ProviderID(declaration.id))
                }
            }
        }
        // Stop in-flight provider work before the host goes away, so disable does not depend on the
        // OS killing the process to end a stream.
        for adapter in adapters[bundleID] ?? [] {
            await adapter.cancelAll()
        }
        for handlerID in handlerIDs[bundleID] ?? [] {
            _ = await pipeline.uninstall(handlerID: handlerID)
        }
        handlerIDs[bundleID] = nil
        adapters[bundleID] = nil
        if let session = sessions.removeValue(forKey: bundleID) {
            await session.disable()
        }
    }

    /// An unexpected host exit has the same effect as a disable, scoped to that plugin, and the
    /// registry records `enabled=false` so a restart does not immediately revive a crashing plugin.
    private func handleUnexpectedExit(bundleID: String) async {
        if disabling.contains(bundleID) { return }
        await teardown(bundleID)
        if let entry = await registry.entry(bundleID), entry.enabled {
            var disabled = entry
            disabled.enabled = false
            try? await registry.upsert(disabled)
        }
        stateChangeHandler?()
    }
}
