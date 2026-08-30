import Foundation

public protocol FilePermissionAdapter: Sendable {
    func secureDirectory(at url: URL) throws
    func secureFile(at url: URL) throws
}

public struct PlatformFilePermissionAdapter: FilePermissionAdapter {
    public init() {}

    public func secureDirectory(at url: URL) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #endif
    }

    public func secureFile(at url: URL) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}

enum ConfigurationDocument: CaseIterable {
    case core, providers, mcp, plugins

    var filename: String {
        switch self {
        case .core: "config.json"
        case .providers: "providers.json"
        case .mcp: "mcp.json"
        case .plugins: "plugins.json"
        }
    }

    var resourceName: String {
        switch self {
        case .core: "config"
        case .providers: "providers"
        case .mcp: "mcp"
        case .plugins: "plugins"
        }
    }

    var schemaURI: String {
        switch self {
        case .core: ConfigurationSchemaURI.core
        case .providers: ConfigurationSchemaURI.providers
        case .mcp: ConfigurationSchemaURI.mcp
        case .plugins: ConfigurationSchemaURI.plugins
        }
    }
}

enum ConfigurationResources {
    static func schemaData(for document: ConfigurationDocument) throws -> Data {
        try data(named: "\(document.resourceName).schema", subdirectory: "Schemas")
    }

    static func defaultData(for document: ConfigurationDocument) throws -> Data {
        try data(named: document.resourceName, subdirectory: "Defaults")
    }

    private static func data(named name: String, subdirectory: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Configuration/\(subdirectory)"
        ) else {
            throw ConfigurationValidationError(path: "$", reason: "missing bundled resource Configuration/\(subdirectory)/\(name).json")
        }
        return try Data(contentsOf: url)
    }
}

public actor ConfigurationStore {
    public let dataRoot: URL
    private let permissions: any FilePermissionAdapter

    public init(dataRoot: URL, permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        self.permissions = permissions
        try FileManager.default.createDirectory(at: self.dataRoot, withIntermediateDirectories: true)
        try permissions.secureDirectory(at: self.dataRoot)
    }

    public func load() throws -> ConfigurationSnapshot {
        try bootstrap()
        return ConfigurationSnapshot(
            core: try load(.core, as: CoreConfiguration.self),
            providers: try load(.providers, as: ProvidersConfiguration.self),
            mcp: try load(.mcp, as: MCPConfiguration.self),
            plugins: try load(.plugins, as: PluginsConfiguration.self)
        )
    }

    public func save(_ snapshot: ConfigurationSnapshot) throws {
        try save(snapshot.core, as: .core)
        try save(snapshot.providers, as: .providers)
        try save(snapshot.mcp, as: .mcp)
        try save(snapshot.plugins, as: .plugins)
    }

    public func saveCore(_ configuration: CoreConfiguration) throws { try save(configuration, as: .core) }
    public func saveProviders(_ configuration: ProvidersConfiguration) throws { try save(configuration, as: .providers) }
    public func saveMCP(_ configuration: MCPConfiguration) throws { try save(configuration, as: .mcp) }
    public func savePlugins(_ configuration: PluginsConfiguration) throws { try save(configuration, as: .plugins) }

    private func bootstrap() throws {
        for document in ConfigurationDocument.allCases {
            let url = dataRoot.appendingPathComponent(document.filename)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                try permissions.secureFile(at: url)
                continue
            }
            let data = try ConfigurationResources.defaultData(for: document)
            try JSONSchemaValidator.validate(documentData: data, schemaData: ConfigurationResources.schemaData(for: document))
            try atomicWrite(data, to: url)
        }
    }

    private func load<T: Decodable>(_ document: ConfigurationDocument, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: dataRoot.appendingPathComponent(document.filename))
        try JSONSchemaValidator.validate(documentData: data, schemaData: ConfigurationResources.schemaData(for: document))
        return try ConfigurationDecoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, as document: ConfigurationDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try JSONSchemaValidator.validate(documentData: data, schemaData: ConfigurationResources.schemaData(for: document))
        try atomicWrite(data, to: dataRoot.appendingPathComponent(document.filename))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try permissions.secureFile(at: url)
    }
}
