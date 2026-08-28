import Foundation
import LingXiProtocol

/// 最小 Context L1：Session 历史 → 模型输入消息。
/// 按序全量携带 user / assistant content；reasoning 不参与。
/// ponytail: 无 token budget / compaction / L2 / L3；
/// 未来 Context Engine 从本类型接管，AgentRuntime 调用方式不变。
public struct SessionContextBuilder: Sendable {
    public init() {}

    public func buildModelMessages(from history: [Message]) -> [ModelMessage] {
        history.map { message in
            ModelMessage(role: modelRole(message.role), parts: message.parts.map(modelPart))
        }
    }

    private func modelRole(_ role: MessageRole) -> ModelRole {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
    }

    private func modelPart(_ part: SessionMessagePart) -> ModelContentPart {
        switch part {
        case let .text(text): .text(text)
        case let .toolCall(call): .toolCall(call)
        case let .toolResult(result): .toolResult(result)
        }
    }
}
