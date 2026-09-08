import Foundation

/// 产品级运行时状态（由 Application 层直接产生，Frontend 无需组合底层状态推测）。
public enum ProductRuntimeStatus: String, Sendable, Equatable, CaseIterable {
    case ready = "Ready"
    case thinking = "Thinking"
    case waitingForProvider = "WaitingForProvider"
    case rateLimited = "RateLimited"
    case runningTool = "RunningTool"
    case runningSubagents = "RunningSubagents"
    case paging = "Paging"
    case actionRequired = "ActionRequired"
    case reconnecting = "Reconnecting"
    case disconnected = "Disconnected"
    case error = "Error"
}
