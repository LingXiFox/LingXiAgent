import Foundation
import LingXiProtocol

/// 模型网关：Core 内所有模型推理的正式入口。
/// 持有当前 Provider，屏蔽 Provider 的构建与选择细节。
public struct ModelGateway: Sendable {
    public struct Unavailable: Sendable, Equatable {
        public let missingRequirements: [String]
    }

    private let provider: (any ModelProvider)?
    public let modelID: ModelID?
    public let missingRequirements: [String]

    public init(provider: (any ModelProvider)?, modelID: ModelID?, missingRequirements: [String] = []) {
        self.provider = provider
        self.modelID = modelID
        self.missingRequirements = missingRequirements
    }

    public var isConfigured: Bool { provider != nil && modelID != nil }

    public var status: ProviderStatus {
        ProviderStatus(
            configured: isConfigured,
            model: modelID?.rawValue,
            baseURL: nil,
            missingRequirements: missingRequirements
        )
    }

    /// Fast Path：进入模型高速总线。
    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        guard let provider else {
            throw CoreError(
                code: .provider,
                message: "未配置模型 Provider，缺少环境变量: \(missingRequirements.joined(separator: ", "))"
            )
        }
        return try await provider.stream(request)
    }
}

/// 模型高速总线：Agent 与 ModelGateway 之间的 Fast Path 正式边界。
/// ponytail: 当前为直接透传；未来 Context 注入、Tool 调度、多 Provider Router
/// 都从这一层接入，Agent 调用方式不变。
public struct ModelBus: Sendable {
    public let gateway: ModelGateway

    public init(gateway: ModelGateway) {
        self.gateway = gateway
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        try await gateway.stream(request)
    }
}
