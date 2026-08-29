/// Core 向客户端广播的语义事件（控制面）。
/// 高频 Streaming 数据（textDelta / reasoningDelta）不走这里，走 Data Plane。
public enum CoreEvent: Sendable, Equatable {
    case stateChanged(CoreState)
    case sessionCreated(SessionID)
    case turnStarted(TurnHandle)
    case turnCompleted(TurnResult)
    case turnFailed(TurnFailure)
    case toolCallCompleted(ToolCall)
    case toolResult(ToolResult)
    case permissionAsked(PermissionRequest)
    case questionAsked(QuestionRequest)
}
