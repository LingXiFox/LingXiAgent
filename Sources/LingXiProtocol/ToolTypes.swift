import Foundation

/// LingXi 的 Tool 领域类型；不包含任何 Provider 原生 schema 或 DTO。
public struct ToolID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ToolCallID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ToolInputType: String, Sendable, Equatable, Codable {
    case string
    case integer
    case number
    case boolean
    case object
    case array
}

public struct ToolInputProperty: Sendable, Equatable, Codable {
    public let type: ToolInputType
    public let description: String
    public let enumValues: [String]?
    public let minimum: Double?
    public let maximum: Double?

    public init(type: ToolInputType, description: String, enumValues: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct ToolInputSchema: Sendable, Equatable, Codable {
    public let properties: [String: ToolInputProperty]
    public let required: [String]

    public init(properties: [String: ToolInputProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }
}

public enum ToolCapabilityKind: String, Sendable, Equatable, Hashable, Codable {
    case projectRead
    case projectWrite
    case processExecute
    case repositoryRead
    case repositoryWrite
    case externalFilesystem
    case networkAccess
    case destructive
    case userInteraction
}

public struct ToolCapability: Sendable, Equatable, Codable {
    public let kinds: Set<ToolCapabilityKind>

    public init(_ kinds: Set<ToolCapabilityKind>) {
        self.kinds = kinds
    }

    public init(readOnly: Bool) {
        kinds = readOnly ? [.projectRead] : [.projectWrite]
    }

    public var readOnly: Bool {
        !kinds.contains(.projectWrite) && !kinds.contains(.repositoryWrite) && !kinds.contains(.processExecute) && !kinds.contains(.destructive)
    }
}

public struct ToolDefinition: Sendable, Equatable, Codable {
    public let id: ToolID
    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema
    public let capability: ToolCapability

    public init(
        id: ToolID,
        name: String? = nil,
        description: String,
        inputSchema: ToolInputSchema,
        capability: ToolCapability
    ) {
        self.id = id
        self.name = name ?? id.rawValue
        self.description = description
        self.inputSchema = inputSchema
        self.capability = capability
    }
}

public struct ToolCall: Sendable, Equatable, Codable {
    public let callID: ToolCallID
    public let toolID: ToolID
    /// Provider Adapter 已聚合的完整 JSON object，Tool Runtime 负责解码并校验。
    public let arguments: String

    public var toolName: String { toolID.rawValue }

    public init(callID: ToolCallID, toolID: ToolID, arguments: String) {
        self.callID = callID
        self.toolID = toolID
        self.arguments = arguments
    }
}

public struct ToolError: Sendable, Equatable, Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ToolOutcome: String, Sendable, Equatable, Codable {
    case success
    case failure
    case denied
    case cancelled
    case timedOut
}

public struct ToolProvenance: Sendable, Equatable, Codable {
    public let projectID: String?
    public let rootBindingID: String?
    public let projectFileID: String?
    public let relativePath: String?
    public let contentHash: String?
    public let version: String?

    public init(projectID: String? = nil, rootBindingID: String? = nil, projectFileID: String? = nil, relativePath: String? = nil, contentHash: String? = nil, version: String? = nil) {
        self.projectID = projectID
        self.rootBindingID = rootBindingID
        self.projectFileID = projectFileID
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.version = version
    }
}

public struct ToolTouchedResource: Sendable, Equatable, Codable {
    public let locator: String
    public let operation: String

    public init(locator: String, operation: String) {
        self.locator = locator
        self.operation = operation
    }
}

public struct ToolTiming: Sendable, Equatable, Codable {
    public let milliseconds: Double

    public init(milliseconds: Double = 0) { self.milliseconds = milliseconds }
}

public struct ToolOutputMetadata: Sendable, Equatable, Codable {
    public let truncated: Bool
    public let totalCharacters: Int
    public let totalBytes: Int
    public let visibleCharacters: Int
    public let visibleBytes: Int
    public let outputBlobRef: String?

    public init(truncated: Bool = false, totalCharacters: Int = 0, totalBytes: Int? = nil, visibleCharacters: Int? = nil, visibleBytes: Int? = nil, outputBlobRef: String? = nil) {
        self.truncated = truncated
        self.totalCharacters = totalCharacters
        self.totalBytes = totalBytes ?? totalCharacters
        self.visibleCharacters = visibleCharacters ?? totalCharacters
        self.visibleBytes = visibleBytes ?? self.visibleCharacters
        self.outputBlobRef = outputBlobRef
    }
}

public struct ToolResult: Sendable, Equatable, Codable {
    public let callID: ToolCallID
    public let success: Bool
    public let content: String
    public let error: ToolError?
    public let toolName: String?
    public let outcome: ToolOutcome
    public let summary: String
    public let metadata: [String: String]
    public let provenance: ToolProvenance?
    public let touchedResources: [ToolTouchedResource]
    public let timing: ToolTiming
    public let output: ToolOutputMetadata
    public let exitCode: Int?

    public init(callID: ToolCallID, success: Bool, content: String, error: ToolError? = nil, toolName: String? = nil, outcome: ToolOutcome? = nil, summary: String = "", metadata: [String: String] = [:], provenance: ToolProvenance? = nil, touchedResources: [ToolTouchedResource] = [], timing: ToolTiming = ToolTiming(), output: ToolOutputMetadata? = nil, exitCode: Int? = nil) {
        self.callID = callID
        self.success = success
        self.content = content
        self.error = error
        self.toolName = toolName
        self.outcome = outcome ?? (success ? .success : .failure)
        self.summary = summary
        self.metadata = metadata
        self.provenance = provenance
        self.touchedResources = touchedResources
        self.timing = timing
        self.output = output ?? ToolOutputMetadata(totalCharacters: content.count)
        self.exitCode = exitCode
    }
}
