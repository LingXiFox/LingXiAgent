import Foundation
import LingXiProtocol

/// Provider 接口：LingXi Domain 正式边界。
/// 任何 Provider（OpenAI 原生 / Anthropic / Gemini / 兼容端点）实现此接口，
/// 上层（Gateway / Bus / Agent）永远只看到 LingXi 领域类型。
public protocol ModelProvider: Sendable {
    /// 建立推理流。连接 / HTTP 失败直接 throw（Provider Error）；
    /// 成功后返回 ModelEvent 流（流中途失败以 .failed 事件交付）。
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error>
}
