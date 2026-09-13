import Foundation
import LingXiProtocol

/// P-Core 上下文投影器（Context Projection）
/// 负责在构建发送给 Provider 的请求时，将超大或已归档的 ToolResult 转换为确定性、高复用率的稳定 Placeholder。
///
/// 核心原则：
/// 1. Canonical Truth 永不可变：SessionStore 始终保存完整真实的原始 ToolResult，P-Core 仅为向 Provider 暴露的短暂投影。
/// 2. FULL_SENDS 语义保证：每个 ToolResult 保证至少被完整发送 fullSendCount 次（默认 2 次），从第 3 次起转为 1KB 稳定首尾 Placeholder。
/// 3. Fail-Open 铁律：任何投影、读取或持久化异常均捕获并静默回退至透传原始 ToolResult，绝不阻断主流程。
public struct ContextProjection: Sendable {
    public let configuration: ContextObjectFabricConfiguration

    public init(configuration: ContextObjectFabricConfiguration = ContextObjectFabricConfiguration()) {
        self.configuration = configuration
    }

    /// 将 ContextEntry 数组投影为面向 Provider 的上下文条目列表。
    public func project(
        entries: [ContextEntry],
        session: Session,
        ecoreStore: ECoreObjectStore
    ) async -> [ContextEntry] {
        guard configuration.observationProjectionEnabled else {
            return entries
        }

        // 收集 Session 中全部 Assistant 消息的时间戳或索引，以便确定因果先后
        let messages = session.messages
        var assistantCountAfterMessageID: [MessageID: Int] = [:]

        for (idx, msg) in messages.enumerated() {
            if msg.role == .tool {
                // 统计该 Tool 结果消息之后，已经产生的 Assistant 响应消息数
                let laterAssistants = messages[(idx + 1)...].filter { $0.role == .assistant }.count
                assistantCountAfterMessageID[msg.id] = laterAssistants
            }
        }

        var projectedEntries: [ContextEntry] = []
        projectedEntries.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.source == .toolResult,
                  case let .toolResult(result) = entry.part,
                  let messageID = entry.messageID else {
                projectedEntries.append(entry)
                continue
            }

            let assistantCount = assistantCountAfterMessageID[messageID] ?? 0

            // 规则：前 fullSendCount 次请求，Provider 必须见到完整全文！
            guard assistantCount >= configuration.fullSendCount else {
                projectedEntries.append(entry)
                continue
            }

            // 检查大小是否达到独立对象化阈值（10KB）
            let byteCount = result.content.utf8.count
            guard byteCount >= configuration.objectizationThreshold else {
                // 小于阈值的结果保持完整内联，避免无谓的对象碎片
                projectedEntries.append(entry)
                continue
            }

            // 满足条件：构建 1KB 稳定首尾 Placeholder
            let toolName = result.toolName ?? "tool"
            let objectID = ContextObjectID.generate(toolName: toolName, callID: result.callID, content: result.content)

            // 确保该对象已在 E-Core 中安全归档（Fail-Open）
            await ecoreStore.store(
                sessionID: session.id,
                toolCallID: result.callID,
                toolName: toolName,
                content: result.content,
                force: true
            )

            let placeholder = buildPlaceholder(
                objectID: objectID,
                toolName: toolName,
                content: result.content,
                excerptBytes: configuration.placeholderExcerpt
            )

            // 构造投影后的替代 ToolResult，外部 Canonical SessionStore 不受影响
            let projectedResult = ToolResult(
                callID: result.callID,
                success: result.success,
                content: placeholder,
                toolName: result.toolName,
                metadata: result.metadata.merging(["context_object_id": objectID.rawValue, "projected": "true"]) { current, _ in current }
            )

            let projectedEntry = ContextEntry(
                messageID: entry.messageID,
                role: entry.role,
                source: entry.source,
                part: .toolResult(projectedResult)
            )
            projectedEntries.append(projectedEntry)
        }

        return projectedEntries
    }

    /// 构建符合规范的稳定首尾 Placeholder（总计约 1KB 摘要）
    private func buildPlaceholder(
        objectID: ContextObjectID,
        toolName: String,
        content: String,
        excerptBytes: Int
    ) -> String {
        let totalBytes = content.utf8.count
        var lineCount = 0
        for byte in content.utf8 {
            if byte == 10 { lineCount += 1 }
        }
        if !content.isEmpty && !content.hasSuffix("\n") { lineCount += 1 }

        let halfExcerpt = max(64, excerptBytes / 2) // 默认 512 bytes
        let data = Data(content.utf8)

        let headData = data.prefix(halfExcerpt)
        let headExcerpt = String(decoding: headData, as: UTF8.self)

        let tailData = data.suffix(halfExcerpt)
        let tailExcerpt = String(decoding: tailData, as: UTF8.self)

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let contentHash = String(format: "%08llx", hash)

        return """
        [Context Object: \(objectID.rawValue)]
        Tool: \(toolName)
        Size: \(totalBytes) bytes, \(max(1, lineCount)) lines
        Content Type: text/plain
        Hash: \(contentHash)
        --- First \(headData.count) bytes ---
        \(headExcerpt)
        --- Last \(tailData.count) bytes ---
        \(tailExcerpt)
        ---
        To retrieve additional lines or full content, use `context_recall(id: "\(objectID.rawValue)", offset: <bytes>, limit: <bytes>)`.
        """
    }
}
