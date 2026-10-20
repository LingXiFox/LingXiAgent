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
    private let credential: @Sendable (String) -> String?
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
        credential: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.hostExecutableURL = hostExecutableURL
        self.registry = registry
        self.pipeline = pipeline
        self.router = router
        self.credential = credential
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
            await session.setUnexpectedExitHandler { [weak self] in
                Task { await self?.handleUnexpectedExit(bundleID: bundleID) }
            }

            let deployments = await session.providers.map { declaration in
                (
                    declaration,
                    PluginProviderAdapter(
                        session: session,
                        providerID: declaration.id,
                        declaration: declaration,
                        credential: { [credential] in credential("provider.\(declaration.id)") }
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

            let capabilityLabels = await session.capabilities.map { "\($0.kind).\($0.id)" }
                + session.providers.map { "provider.\($0.id)" }
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
