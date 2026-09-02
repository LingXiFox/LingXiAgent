import Foundation
import LingXiProtocol

public enum ExtensionType: String, Codable, Sendable, CaseIterable {
    case skill, command, hook, plugin, mcp
}

public enum ExtensionScope: String, Codable, Sendable, CaseIterable {
    case global, project
}

public enum ExtensionLifecycleState: String, Codable, Sendable, Equatable {
    case discovered, installed, loaded, enabled, disabled, failed, incompatible, uninstalled
}

public struct ExtensionCompatibility: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let minimumCoreVersion: String?
    public let maximumCoreVersion: String?

    public init(schemaVersion: Int = 1, minimumCoreVersion: String? = nil, maximumCoreVersion: String? = nil) {
        self.schemaVersion = schemaVersion
        self.minimumCoreVersion = minimumCoreVersion
        self.maximumCoreVersion = maximumCoreVersion
    }

    public func supports(coreVersion: String, schema: Int = 1) -> Bool {
        guard schemaVersion == schema, let current = Self.version(coreVersion) else { return false }
        if let minimumCoreVersion {
            guard let minimum = Self.version(minimumCoreVersion) else { return false }
            if current.lexicographicallyPrecedes(minimum) { return false }
        }
        if let maximumCoreVersion {
            guard let maximum = Self.version(maximumCoreVersion) else { return false }
            if maximum.lexicographicallyPrecedes(current) { return false }
        }
        return true
    }

    private static func version(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0).map { $0 >= 0 } == true }) else { return nil }
        return parts.map { Int($0)! } + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}

public struct ExtensionProvenance: Codable, Sendable, Equatable {
    public let scope: ExtensionScope
    public let location: String
    public let discoveredAt: Date

    public init(scope: ExtensionScope, location: String, discoveredAt: Date = .now) {
        self.scope = scope
        self.location = location
        self.discoveredAt = discoveredAt
    }
}

public struct ExtensionDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let type: ExtensionType
    public let source: String
    public let scope: ExtensionScope
    public var enabled: Bool
    public let capabilities: Set<ToolCapabilityKind>
    public let compatibility: ExtensionCompatibility
    public var lifecycleState: ExtensionLifecycleState
    public let provenance: ExtensionProvenance

    public init(
        id: String,
        version: String = "1.0.0",
        type: ExtensionType,
        source: String,
        scope: ExtensionScope = .project,
        enabled: Bool = true,
        capabilities: Set<ToolCapabilityKind> = [],
        compatibility: ExtensionCompatibility = ExtensionCompatibility(),
        lifecycleState: ExtensionLifecycleState = .discovered,
        provenance: ExtensionProvenance? = nil
    ) {
        self.id = id
        self.version = version
        self.type = type
        self.source = source
        self.scope = scope
        self.enabled = enabled
        self.capabilities = capabilities
        self.compatibility = compatibility
        self.lifecycleState = lifecycleState
        self.provenance = provenance ?? ExtensionProvenance(scope: scope, location: source)
    }

    public var key: String { "\(scope.rawValue):\(type.rawValue):\(id)" }

    public func validated(coreVersion: String = CoreHost.coreVersion) throws -> ExtensionDescriptor {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw ExtensionError.invalidManifest("invalid extension id") }
        guard !version.isEmpty, ExtensionCompatibility.versionForValidation(version) else { throw ExtensionError.invalidManifest("invalid extension version") }
        guard !source.isEmpty else { throw ExtensionError.invalidManifest("extension source is empty") }
        guard provenance.scope == scope else { throw ExtensionError.invalidManifest("provenance scope mismatch") }
        guard compatibility.supports(coreVersion: coreVersion) else { throw ExtensionError.incompatible(id) }
        return self
    }
}

extension ExtensionCompatibility {
    fileprivate static func versionForValidation(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { Int($0).map { $0 >= 0 } == true }
    }
}

public enum ExtensionError: Error, Sendable, Equatable {
    case invalidManifest(String)
    case duplicate(String)
    case notFound(String)
    case incompatible(String)
    case capabilityDenied(String, ToolCapabilityKind)
    case lifecycle(String)
    case package(String)
}

public struct ExtensionDiagnostic: Codable, Sendable, Equatable {
    public let extensionID: String?
    public let scope: ExtensionScope?
    public let location: String
    public let message: String

    public init(extensionID: String? = nil, scope: ExtensionScope? = nil, location: String, message: String) {
        self.extensionID = extensionID
        self.scope = scope
        self.location = location
        self.message = message
    }
}

public struct ExtensionDiscoveryResult: Sendable, Equatable {
    public let extensions: [ExtensionDescriptor]
    public let diagnostics: [ExtensionDiagnostic]

    public init(extensions: [ExtensionDescriptor], diagnostics: [ExtensionDiagnostic] = []) {
        self.extensions = extensions
        self.diagnostics = diagnostics
    }
}

public enum ExtensionDiscovery {
    public static func skills(globalRoot: URL, projectRoot: URL, coreVersion: String = CoreHost.coreVersion) -> ExtensionDiscoveryResult {
        discover(type: .skill, globalDirectories: [globalRoot.appendingPathComponent("skills", isDirectory: true), globalRoot.appendingPathComponent(".lingxi/skills", isDirectory: true)], projectDirectories: [projectRoot.appendingPathComponent(".lingxi/skills", isDirectory: true)], marker: "SKILL.md", coreVersion: coreVersion)
    }

    public static func commands(globalRoot: URL, projectRoot: URL, coreVersion: String = CoreHost.coreVersion) -> ExtensionDiscoveryResult {
        discover(type: .command, globalDirectories: [globalRoot.appendingPathComponent("commands", isDirectory: true), globalRoot.appendingPathComponent(".lingxi/commands", isDirectory: true)], projectDirectories: [projectRoot.appendingPathComponent(".lingxi/commands", isDirectory: true)], marker: nil, coreVersion: coreVersion)
    }

    private static func discover(type: ExtensionType, globalDirectories: [URL], projectDirectories: [URL], marker: String?, coreVersion: String) -> ExtensionDiscoveryResult {
        var result: [ExtensionDescriptor] = []
        var diagnostics: [ExtensionDiagnostic] = []
        for (scope, directories) in [(ExtensionScope.global, globalDirectories), (.project, projectDirectories)] {
            var seen = Set<String>()
            for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let valid = marker.map { isDirectory && FileManager.default.fileExists(atPath: entry.appendingPathComponent($0).path) } ?? !isDirectory
                guard valid else { continue }
                let id = entry.lastPathComponent.replacingOccurrences(of: ".md", with: "")
                guard seen.insert(id).inserted else { continue }
                let descriptor = ExtensionDescriptor(id: id, type: type, source: entry.path, scope: scope, provenance: ExtensionProvenance(scope: scope, location: entry.path))
                do { result.append(try descriptor.validated(coreVersion: coreVersion)) }
                catch { diagnostics.append(ExtensionDiagnostic(extensionID: id, scope: scope, location: entry.path, message: String(describing: error))) }
            }
            }
        }
        let projectIDs = Set(result.filter { $0.scope == .project }.map { $0.id })
        let effective = result.filter { $0.scope == .project || !projectIDs.contains($0.id) }.sorted { $0.id == $1.id ? $0.scope.rawValue > $1.scope.rawValue : $0.id < $1.id }
        return ExtensionDiscoveryResult(extensions: effective, diagnostics: diagnostics)
    }
}

public actor ExtensionRegistry {
    private var descriptors: [String: ExtensionDescriptor] = [:]
    private var storedDiagnostics: [ExtensionDiagnostic] = []

    public init() {}

    public func register(_ descriptor: ExtensionDescriptor, coreVersion: String = CoreHost.coreVersion) throws {
        let value = try descriptor.validated(coreVersion: coreVersion)
        guard descriptors[value.key] == nil else { throw ExtensionError.duplicate(value.key) }
        descriptors[value.key] = value
    }

    public func replace(_ values: [ExtensionDescriptor], diagnostics: [ExtensionDiagnostic] = [], coreVersion: String = CoreHost.coreVersion) {
        var next: [String: ExtensionDescriptor] = [:]
        var failures = diagnostics
        for value in values {
            do {
                let valid = try value.validated(coreVersion: coreVersion)
                if next[valid.key] == nil { next[valid.key] = valid } else { failures.append(ExtensionDiagnostic(extensionID: valid.id, scope: valid.scope, location: valid.source, message: "duplicate extension")) }
            } catch { failures.append(ExtensionDiagnostic(extensionID: value.id, scope: value.scope, location: value.source, message: String(describing: error))) }
        }
        descriptors = next
        storedDiagnostics = failures
    }

    public func descriptor(id: String, type: ExtensionType? = nil, scope: ExtensionScope? = nil) -> ExtensionDescriptor? {
        if let scope { return descriptors["\(scope.rawValue):\(type?.rawValue ?? "plugin"):\(id)"] }
        let matches = descriptors.values.filter { $0.id == id && (type == nil || $0.type == type) }
        return matches.first(where: { $0.scope == .project }) ?? matches.first(where: { $0.scope == .global })
    }

    public func effective(type: ExtensionType) -> [ExtensionDescriptor] {
        let all = descriptors.values.filter { $0.type == type }
        let ids = Set(all.map(\.id))
        return ids.compactMap { descriptor(id: $0, type: type) }.filter { $0.enabled && $0.lifecycleState == .enabled || ($0.enabled && $0.lifecycleState == .discovered) }.sorted { $0.id < $1.id }
    }

    public func all() -> [ExtensionDescriptor] { descriptors.values.sorted { $0.key < $1.key } }
    public func diagnostics() -> [ExtensionDiagnostic] { storedDiagnostics }
    public func upsert(_ descriptor: ExtensionDescriptor, coreVersion: String = CoreHost.coreVersion) throws { descriptors[descriptor.key] = try descriptor.validated(coreVersion: coreVersion) }
    public func remove(id: String, type: ExtensionType, scope: ExtensionScope) { descriptors.removeValue(forKey: "\(scope.rawValue):\(type.rawValue):\(id)") }
    public func remove(type: ExtensionType, scope: ExtensionScope) { descriptors = descriptors.filter { $0.value.type != type || $0.value.scope != scope } }
}

public enum ExtensionHookEvent: String, Codable, Sendable, CaseIterable {
    case agentRunStart, agentRunEnd, toolBefore, toolAfter, taskStart, taskEnd, workflowStart, workflowEnd, sessionStart, sessionEnd
}

public struct ExtensionEvent: Codable, Sendable, Equatable {
    public let kind: ExtensionHookEvent
    public let subjectID: String
    public let metadata: [String: String]

    public init(kind: ExtensionHookEvent, subjectID: String, metadata: [String: String] = [:]) {
        self.kind = kind
        self.subjectID = subjectID
        self.metadata = metadata
    }
}

public struct ExtensionHookDiagnostic: Sendable, Equatable {
    public let extensionID: String
    public let event: ExtensionHookEvent
    public let outcome: String
    public let message: String?

    public init(extensionID: String, event: ExtensionHookEvent, outcome: String, message: String? = nil) {
        self.extensionID = extensionID
        self.event = event
        self.outcome = outcome
        self.message = message
    }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let capabilities: Set<ToolCapabilityKind>
    public let compatibility: ExtensionCompatibility

    public init(id: String, version: String, capabilities: Set<ToolCapabilityKind> = [], compatibility: ExtensionCompatibility = ExtensionCompatibility()) {
        self.id = id
        self.version = version
        self.capabilities = capabilities
        self.compatibility = compatibility
    }
}

public actor ExtensionPlatform {
    public let registry: ExtensionRegistry
    public let globalRoot: URL
    public let projectRoot: URL
    private let permissions: PermissionEngine
    private let deadlinePolicy: ExecutionDeadlinePolicy
    private let coreVersion: String
    private var hooks: [String: (event: ExtensionHookEvent, timeout: Double, handler: @Sendable (ExtensionEvent) async throws -> Void)] = [:]
    private var mcpRegistry: MCPServerRegistry?

    public init(globalRoot: URL, projectRoot: URL, permissions: PermissionEngine, registry: ExtensionRegistry = ExtensionRegistry(), deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy(), coreVersion: String = CoreHost.coreVersion) {
        self.globalRoot = globalRoot.standardizedFileURL
        self.projectRoot = projectRoot.standardizedFileURL
        self.permissions = permissions
        self.registry = registry
        self.deadlinePolicy = deadlinePolicy
        self.coreVersion = coreVersion
    }

    public func restore() async {
        var values: [ExtensionDescriptor] = []
        var diagnostics: [ExtensionDiagnostic] = []
        for (scope, url) in stateURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            do { values += try JSONDecoder().decode([ExtensionDescriptor].self, from: data) }
            catch { diagnostics.append(ExtensionDiagnostic(scope: scope, location: url.path, message: "registry decode failed: \(error)")) }
        }
        await registry.replace(values, diagnostics: diagnostics, coreVersion: coreVersion)
    }

    @discardableResult
    public func discover() async -> ExtensionDiscoveryResult {
        let skills = ExtensionDiscovery.skills(globalRoot: globalRoot, projectRoot: projectRoot, coreVersion: coreVersion)
        let commands = ExtensionDiscovery.commands(globalRoot: globalRoot, projectRoot: projectRoot, coreVersion: coreVersion)
        let result = ExtensionDiscoveryResult(extensions: skills.extensions + commands.extensions, diagnostics: skills.diagnostics + commands.diagnostics)
        let preserved = (await registry.all()).filter { $0.type != .skill && $0.type != .command }
        await registry.replace(preserved + result.extensions, diagnostics: result.diagnostics, coreVersion: coreVersion)
        await persist()
        return result
    }

    public func list(type: ExtensionType? = nil) async -> [ExtensionDescriptor] {
        let all = await registry.all()
        return all.filter { type == nil || $0.type == type }
    }

    public func effective(type: ExtensionType) async -> [ExtensionDescriptor] { await registry.effective(type: type) }
    public func diagnostics() async -> [ExtensionDiagnostic] { await registry.diagnostics() }

    @discardableResult
    public func reload() async -> ExtensionDiscoveryResult { await discover() }

    public func enable(id: String, type: ExtensionType? = nil, scope: ExtensionScope? = nil) async throws {
        try await setLifecycle(id: id, type: type, scope: scope, enabled: true)
    }

    public func disable(id: String, type: ExtensionType? = nil, scope: ExtensionScope? = nil) async throws {
        try await setLifecycle(id: id, type: type, scope: scope, enabled: false)
    }

    public func requireCapability(extensionID: String, capability: ToolCapabilityKind, resource: String = "extension") async throws {
        guard let descriptor = await registry.descriptor(id: extensionID) else { throw ExtensionError.notFound(extensionID) }
        guard descriptor.capabilities.contains(capability) else { throw ExtensionError.capabilityDenied(extensionID, capability) }
        let request = PermissionRequest(permissionID: PermissionID("extension-\(UUID().uuidString)"), sessionID: SessionID("extension"), toolCallID: ToolCallID("extension-\(UUID().uuidString)"), toolID: ToolID(extensionID), capabilities: [capability], resource: resource, description: "Extension capability \(capability.rawValue)")
        let resolution = await permissions.check(request)
        guard resolution.decision == .allow else { throw ExtensionError.capabilityDenied(extensionID, capability) }
    }

    public func registerHook(extensionID: String, event: ExtensionHookEvent, timeoutSeconds: Double = 5, handler: @escaping @Sendable (ExtensionEvent) async throws -> Void) async throws {
        guard let descriptor = await registry.descriptor(id: extensionID, type: .hook), descriptor.enabled else { throw ExtensionError.lifecycle("hook is not enabled") }
        guard timeoutSeconds > 0 else { throw ExtensionError.invalidManifest("hook timeout must be positive") }
        _ = descriptor
        hooks["\(extensionID):\(event.rawValue)"] = (event, timeoutSeconds, handler)
    }

    public func emit(_ event: ExtensionEvent) async -> [ExtensionHookDiagnostic] {
        let registrations = hooks.filter { $0.value.event == event.kind }
        var diagnostics: [ExtensionHookDiagnostic] = []
        for (key, registration) in registrations {
            let id = String(key.split(separator: ":").first ?? "unknown")
            do {
                guard let descriptor = await registry.descriptor(id: id, type: .hook), descriptor.enabled else { throw ExtensionError.lifecycle("hook is disabled") }
                let request = PermissionRequest(permissionID: PermissionID("hook-\(UUID().uuidString)"), sessionID: SessionID("extension-hook"), toolCallID: ToolCallID("hook-\(UUID().uuidString)"), toolID: ToolID(id), capabilities: descriptor.capabilities, resource: descriptor.source, description: "Extension hook \(event.kind.rawValue)")
                guard (await permissions.check(request)).decision == .allow else { throw ExtensionError.capabilityDenied(id, descriptor.capabilities.first ?? .projectRead) }
                let deadline = deadlinePolicy.deadline(for: .quickFilesystem, requested: .milliseconds(Int(registration.timeout * 1_000)))
                try await ExecutionWatchdog.run(deadline) { try await registration.handler(event) }
                diagnostics.append(ExtensionHookDiagnostic(extensionID: id, event: event.kind, outcome: "success"))
            } catch let error as CoreError where error.code == .commandTimedOut {
                diagnostics.append(ExtensionHookDiagnostic(extensionID: id, event: event.kind, outcome: "timedOut", message: error.message))
            } catch is CancellationError {
                diagnostics.append(ExtensionHookDiagnostic(extensionID: id, event: event.kind, outcome: "cancelled"))
            } catch {
                diagnostics.append(ExtensionHookDiagnostic(extensionID: id, event: event.kind, outcome: "failure", message: String(describing: error)))
            }
        }
        return diagnostics
    }

    public func attachMCPRegistry(_ registry: MCPServerRegistry) { mcpRegistry = registry }

    public func registerMCP(_ configuration: MCPServerConfiguration, scope: ExtensionScope = .project) async throws {
        let descriptor = ExtensionDescriptor(id: configuration.serverID.rawValue, version: "1.0.0", type: .mcp, source: "mcp.json:\(configuration.serverID.rawValue)", scope: scope, enabled: configuration.enabled, capabilities: [.networkAccess, .externalService], lifecycleState: configuration.enabled ? .enabled : .disabled)
        try await registry.upsert(descriptor, coreVersion: coreVersion)
        await mcpRegistry?.register(configuration)
        await persist()
    }

    public func reloadMCP(_ configurations: [MCPServerConfiguration], scope: ExtensionScope = .project) async throws {
        await mcpRegistry?.replace(configurations)
        await registry.remove(type: .mcp, scope: scope)
        for configuration in configurations { try await registerMCP(configuration, scope: scope) }
    }

    public func health(of serverID: MCPServerID, connections: MCPConnectionManager) async -> MCPConnectionManager.Health { await connections.health(for: serverID) }

    public func installPlugin(from package: URL, scope: ExtensionScope = .global) async throws -> ExtensionDescriptor {
        try await authorizeManagement(operation: "install")
        let manifest = try decodeManifest(package)
        let descriptor = try ExtensionDescriptor(id: manifest.id, version: manifest.version, type: .plugin, source: package.path, scope: scope, enabled: false, capabilities: manifest.capabilities, compatibility: manifest.compatibility, lifecycleState: .installed).validated(coreVersion: coreVersion)
        let destination = packageRoot(scope).appendingPathComponent(descriptor.id, isDirectory: true).appendingPathComponent(descriptor.version, isDirectory: true)
        try copyPackage(package, to: destination)
        var installed = descriptor
        installed = ExtensionDescriptor(id: descriptor.id, version: descriptor.version, type: .plugin, source: destination.path, scope: scope, enabled: false, capabilities: descriptor.capabilities, compatibility: descriptor.compatibility, lifecycleState: .installed, provenance: ExtensionProvenance(scope: scope, location: destination.path))
        try await registry.upsert(installed, coreVersion: coreVersion)
        await persist()
        return installed
    }

    public func loadPlugin(id: String, scope: ExtensionScope = .global) async throws -> ExtensionDescriptor {
        guard let current = await registry.descriptor(id: id, type: .plugin, scope: scope), current.lifecycleState != .uninstalled else { throw ExtensionError.notFound(id) }
        let loaded = ExtensionDescriptor(id: current.id, version: current.version, type: current.type, source: current.source, scope: current.scope, enabled: current.enabled, capabilities: current.capabilities, compatibility: current.compatibility, lifecycleState: .loaded, provenance: current.provenance)
        try await registry.upsert(loaded, coreVersion: coreVersion)
        await persist()
        return loaded
    }

    public func updatePlugin(id: String, from package: URL, scope: ExtensionScope = .global) async throws -> ExtensionDescriptor {
        try await authorizeManagement(operation: "update")
        guard let current = await registry.descriptor(id: id, type: .plugin, scope: scope) else { throw ExtensionError.notFound(id) }
        let manifest = try decodeManifest(package)
        guard manifest.id == id else { throw ExtensionError.package("plugin id changed") }
        let candidate = try ExtensionDescriptor(id: manifest.id, version: manifest.version, type: .plugin, source: package.path, scope: scope, enabled: current.enabled, capabilities: manifest.capabilities, compatibility: manifest.compatibility, lifecycleState: current.enabled ? .enabled : .disabled).validated(coreVersion: coreVersion)
        let destination = packageRoot(scope).appendingPathComponent(candidate.id, isDirectory: true).appendingPathComponent(candidate.version, isDirectory: true)
        try copyPackage(package, to: destination)
        let updated = ExtensionDescriptor(id: candidate.id, version: candidate.version, type: .plugin, source: destination.path, scope: scope, enabled: candidate.enabled, capabilities: candidate.capabilities, compatibility: candidate.compatibility, lifecycleState: candidate.lifecycleState, provenance: ExtensionProvenance(scope: scope, location: destination.path))
        try await registry.upsert(updated, coreVersion: coreVersion)
        await persist()
        return updated
    }

    public func uninstallPlugin(id: String, scope: ExtensionScope = .global) async throws {
        try await authorizeManagement(operation: "uninstall")
        guard let current = await registry.descriptor(id: id, type: .plugin, scope: scope) else { throw ExtensionError.notFound(id) }
        let source = URL(fileURLWithPath: current.source)
        if FileManager.default.fileExists(atPath: source.path) {
            let backupDirectory = packageRoot(scope).appendingPathComponent(".backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let backup = backupDirectory.appendingPathComponent("\(id)-\(current.version)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: backup)
            try FileManager.default.removeItem(at: source)
        }
        await registry.remove(id: id, type: .plugin, scope: scope)
        await persist()
    }

    private func setLifecycle(id: String, type: ExtensionType?, scope: ExtensionScope?, enabled: Bool) async throws {
        guard var descriptor = await registry.descriptor(id: id, type: type, scope: scope) else { throw ExtensionError.notFound(id) }
        if enabled { try await requireDeclaredCapabilities(descriptor) }
        descriptor.enabled = enabled
        descriptor.lifecycleState = enabled ? .enabled : .disabled
        try await registry.upsert(descriptor, coreVersion: coreVersion)
        if descriptor.type == .mcp { await mcpRegistry?.setEnabled(MCPServerID(descriptor.id), enabled: enabled) }
        await persist()
    }

    private func requireDeclaredCapabilities(_ descriptor: ExtensionDescriptor) async throws {
        for capability in descriptor.capabilities { try await requireCapability(extensionID: descriptor.id, capability: capability, resource: descriptor.source) }
    }

    private func authorizeManagement(operation: String) async throws {
        let request = PermissionRequest(permissionID: PermissionID("extension-management-\(UUID().uuidString)"), sessionID: SessionID("extension-management"), toolCallID: ToolCallID("extension-management-\(UUID().uuidString)"), toolID: ToolID("extension-management"), capabilities: [.externalFilesystem], resource: operation, description: "Extension \(operation)")
        guard (await permissions.check(request)).decision == .allow else { throw ExtensionError.capabilityDenied("extension-management", .externalFilesystem) }
    }

    private func decodeManifest(_ package: URL) throws -> PluginManifest {
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("extension.json").path) else { throw ExtensionError.package("extension.json missing") }
        do { return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: package.appendingPathComponent("extension.json"))) }
        catch { throw ExtensionError.invalidManifest(String(describing: error)) }
    }

    private func copyPackage(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { throw ExtensionError.package("package version already exists") }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func packageRoot(_ scope: ExtensionScope) -> URL {
        switch scope {
        case .global: globalRoot.appendingPathComponent("extensions", isDirectory: true)
        case .project: projectRoot.appendingPathComponent(".lingxi/extensions", isDirectory: true)
        }
    }

    private func stateURLs() -> [(ExtensionScope, URL)] {
        [(.global, globalRoot.appendingPathComponent("extension-registry.json")), (.project, projectRoot.appendingPathComponent(".lingxi/extension-registry.json"))]
    }

    private func persist() async {
        let values = await registry.all()
        for (scope, url) in stateURLs() {
            let scoped = values.filter { $0.scope == scope }
            guard let data = try? JSONEncoder.sorted.encode(scoped) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
