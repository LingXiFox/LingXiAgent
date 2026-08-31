import Foundation
import LingXiProtocol

/// 模型网关：Core 内所有模型推理的正式入口。
/// 持有当前 Provider，屏蔽 Provider 的构建与选择细节。
public struct ModelGateway: Sendable {
    public struct Unavailable: Sendable, Equatable {
        public let missingRequirements: [String]
    }

    private let provider: (any ModelProvider)?
    public let endpoint: ResolvedModelEndpoint?
    public let missingRequirements: [String]
    public let reasoning: String?
    public var modelID: ModelID? { endpoint?.modelID }
    public var contextProfile: ModelContextProfile { endpoint?.contextProfile ?? ModelContextProfile() }

    public init(provider: (any ModelProvider)?, modelID: ModelID?, missingRequirements: [String] = [], contextProfile: ModelContextProfile = ModelContextProfile(), reasoning: String? = nil) {
        self.provider = provider
        endpoint = modelID.map { ResolvedModelEndpoint(providerID: "default", modelID: $0, baseURL: nil, wireProtocol: .chatCompletions, contextProfile: contextProfile) }
        self.missingRequirements = missingRequirements
        self.reasoning = reasoning
    }

    public init(assembly: ModelRuntimeAssembly?, missingRequirements: [String] = [], reasoning: String? = nil) {
        provider = assembly?.provider
        endpoint = assembly?.endpoint
        self.missingRequirements = missingRequirements
        self.reasoning = reasoning
    }

    public var isConfigured: Bool { provider != nil && modelID != nil }

    public var status: ProviderStatus {
        ProviderStatus(
            configured: isConfigured,
            model: modelID?.rawValue,
            baseURL: endpoint?.baseURL?.absoluteString,
            missingRequirements: missingRequirements
        )
    }

    /// Fast Path：进入模型高速总线。
    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        guard let provider else {
            throw CoreError(
                code: .provider,
                message: "未配置模型 Provider；请检查 providers.json 与 CredentialStore: \(missingRequirements.joined(separator: ", "))"
            )
        }
        return try await provider.stream(request)
    }
}

/// 模型高速总线：所有 Adapter 在这里收口为“恰好一个合法 terminal”。
public struct ModelBus: Sendable {
    public let gateway: ModelGateway

    public init(gateway: ModelGateway) {
        self.gateway = gateway
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let source = try await gateway.stream(request)
        return AsyncThrowingStream { continuation in
            let pump = Task {
                var terminal: ModelFinishReason?
                var completedCalls = 0
                do {
                    for try await event in source {
                        if terminal != nil {
                            continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider terminal 后仍返回事件")))
                            continuation.finish()
                            return
                        }
                        switch event {
                        case .toolCallCompleted:
                            completedCalls += 1
                            continuation.yield(event)
                        case let .completed(reason):
                            terminal = reason
                        case .failed:
                            continuation.yield(event)
                            continuation.finish()
                            return
                        default:
                            continuation.yield(event)
                        }
                    }
                    if Task.isCancelled { continuation.finish(); return }
                    guard let terminal else {
                        continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider stream 缺少 terminal")))
                        continuation.finish()
                        return
                    }
                    guard (completedCalls > 0) == (terminal == .toolCalls) else {
                        continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider terminal 与 ToolCall 不一致")))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.completed(terminal))
                    continuation.finish()
                } catch let error as CoreError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider stream 连接中断")))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in pump.cancel() }
        }
    }
}
