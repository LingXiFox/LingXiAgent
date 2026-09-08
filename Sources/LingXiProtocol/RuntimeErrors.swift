import Foundation

/// RuntimeError 分类。支持未知扩展与 fallback。
public enum RuntimeErrorCategory: String, Codable, Sendable, Equatable {
    case runtime
    case provider
    case tool
    case permission
    case workflow
    case context
    case `extension`
    case configuration
    case authentication
    case validation
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = RuntimeErrorCategory(rawValue: raw) ?? .unknown
    }
}

/// 重试策略。
public enum Retryability: String, Codable, Sendable, Equatable {
    case none
    case transient
    case afterDelay
    case afterUserAction
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Retryability(rawValue: raw) ?? .unknown
    }
}

/// 错误来源。
public enum ErrorSource: String, Codable, Sendable, Equatable {
    case core
    case provider
    case tool
    case client
    case user
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ErrorSource(rawValue: raw) ?? .unknown
    }
}

/// Protocol 强类型 RuntimeError。
public struct RuntimeError: Codable, Sendable, Equatable, Error, CustomStringConvertible {
    public let id: RuntimeErrorID
    public let category: RuntimeErrorCategory
    public let code: String
    public let message: String
    public let retryability: Retryability
    public let source: ErrorSource
    public let diagnosticsRef: ContentRef?

    public init(
        id: RuntimeErrorID = RuntimeErrorID(),
        category: RuntimeErrorCategory,
        code: String,
        message: String,
        retryability: Retryability = .none,
        source: ErrorSource = .core,
        diagnosticsRef: ContentRef? = nil
    ) {
        self.id = id
        self.category = category
        self.code = code
        self.message = message
        self.retryability = retryability
        self.source = source
        self.diagnosticsRef = diagnosticsRef
    }

    public var description: String {
        "[\(category.rawValue):\(code)] \(message)"
    }
}

// MARK: - Legacy CoreError Compatibility

extension RuntimeError {
    public init(from coreError: CoreError) {
        let category: RuntimeErrorCategory
        let retryability: Retryability
        let source: ErrorSource

        switch coreError.code {
        case .provider, .modelStream:
            category = .provider
            retryability = .transient
            source = .provider
        case .toolNotFound, .toolArgumentInvalid, .toolValidationError, .toolExecutionFailed, .toolCancelled, .executionStateUnknown:
            category = .tool
            retryability = .none
            source = .tool
        case .permissionDenied, .permissionCancelled, .workspaceViolation, .resourceOutsideWorkspace, .symlinkEscape:
            category = .permission
            retryability = .afterUserAction
            source = .core
        case .contextBudgetExceeded, .contextProtocolViolation, .contextProfileNotViable:
            category = .context
            retryability = .none
            source = .core
        case .mcpToolLeaseMissing, .mcpToolSchemaChanged, .mcpToolSchemaTooLarge, .mcpToolSchemaBudgetExceeded, .mcpServerUnavailable, .mcpDiscoveryLimitExceeded, .mcpProtocolUnsupported, .mcpTaskExecutionUnsupported, .mcpInputRequiredUnavailable:
            category = .extension
            retryability = .transient
            source = .tool
        case .subagentModelNotAllowed, .subagentDepthExceeded:
            category = .workflow
            retryability = .none
            source = .core
        case .unsupportedCommand:
            category = .validation
            retryability = .none
            source = .client
        default:
            category = .runtime
            retryability = .none
            source = .core
        }

        self.init(
            category: category,
            code: coreError.code.rawValue,
            message: coreError.message,
            retryability: retryability,
            source: source
        )
    }

    public func toCoreError() -> CoreError {
        let code = CoreError.Code(rawValue: self.code) ?? .commandFailed
        return CoreError(code: code, message: self.message)
    }
}

extension CoreError {
    public var asRuntimeError: RuntimeError {
        RuntimeError(from: self)
    }
}

