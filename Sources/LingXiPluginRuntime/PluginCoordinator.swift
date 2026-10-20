import Foundation
import LingXiKernel
import LingXiPluginABI

/// Ties the registry, the per-plugin host sessions and the kernel hook pipeline together. This is the
/// only object that knows both a plugin and the kernel, and it lives outside both.
public actor PluginCoordinator {
    public struct Loaded: Sendable {
        public let bundleID: String
        public let capabilities: [DeclaredCapability]
    }

    private let hostExecutableURL: URL
    private let registry: PluginRegistry
    private let pipeline: HookPipeline
    private var sessions: [String: PluginSession] = [:]
    private var handlerIDs: [String: [String]] = [:]

    public init(hostExecutableURL: URL, registry: PluginRegistry, pipeline: HookPipeline) {
        self.hostExecutableURL = hostExecutableURL
        self.registry = registry
        self.pipeline = pipeline
    }

    /// Installs a bundle in the registry without starting it. Enabling is a separate, explicit act.
    public func install(bundleID: String, version: String, bundlePath: String) async throws {
        try await registry.upsert(.init(bundleID: bundleID, version: version, bundlePath: bundlePath, enabled: false))
    }

    @discardableResult
    public func enable(
        bundleID: String,
        policy: SignaturePolicy = .development,
        grantedPermissions: [String] = []
    ) async throws -> Loaded {
        guard let entry = await registry.entry(bundleID) else {
            throw PluginSession.SessionError.handshake("plugin \(bundleID) is not installed")
        }
        if let existing = sessions[bundleID], await existing.isRunning {
            return Loaded(bundleID: bundleID, capabilities: await existing.capabilities)
        }

        let session = PluginSession(bundlePath: entry.bundlePath, hostExecutableURL: hostExecutableURL)
        try await session.enable(policy: policy, grantedPermissions: grantedPermissions)
        let capabilities = await session.capabilities
        var mounted: [String] = []
        for capability in capabilities where capability.kind == "hook" {
            let bridge = PluginHookBridge(bundleID: bundleID, declaration: capability, session: session)
            await pipeline.install(bridge)
            mounted.append(bridge.handlerID)
        }
        sessions[bundleID] = session
        handlerIDs[bundleID] = mounted
        try await registry.upsert(.init(
            bundleID: entry.bundleID, version: entry.version, bundlePath: entry.bundlePath, enabled: true
        ))
        return Loaded(bundleID: bundleID, capabilities: capabilities)
    }

    /// Revocation order matters: routes go first, so no new Run can reach a plugin that is being torn
    /// down; only then does the process stop. The registry is written last, and it never lies about a
    /// still-running host.
    public func disable(bundleID: String) async {
        for handlerID in handlerIDs[bundleID] ?? [] {
            _ = await pipeline.uninstall(handlerID: handlerID)
        }
        handlerIDs[bundleID] = nil
        if let session = sessions.removeValue(forKey: bundleID) {
            await session.disable()
        }
        if let entry = await registry.entry(bundleID) {
            try? await registry.upsert(.init(
                bundleID: entry.bundleID, version: entry.version, bundlePath: entry.bundlePath, enabled: false
            ))
        }
    }

    public func uninstall(bundleID: String) async throws {
        await disable(bundleID: bundleID)
        try await registry.remove(bundleID)
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
}
