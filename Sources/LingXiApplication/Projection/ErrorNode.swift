import Foundation
import LingXiProtocol

/// 运行时异常/错误节点。
public struct ErrorNode: Sendable, Equatable {
    public let errorID: RuntimeErrorID
    public let code: String
    public let message: String
    public let details: [String: String]

    public init(
        errorID: RuntimeErrorID = RuntimeErrorID(),
        code: String,
        message: String,
        details: [String: String] = [:]
    ) {
        self.errorID = errorID
        self.code = code
        self.message = message
        self.details = details
    }

    public init(from error: RuntimeError) {
        self.errorID = error.id
        self.code = error.code
        self.message = error.message
        self.details = [
            "category": error.category.rawValue,
            "source": error.source.rawValue,
            "retryability": error.retryability.rawValue
        ]
    }
}
