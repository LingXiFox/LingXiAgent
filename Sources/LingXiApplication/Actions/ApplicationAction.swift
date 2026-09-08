import Foundation
import LingXiProtocol
import LingXiClient

public typealias ModelID = String

/// 应用程序业务动作（Frontend 对 ApplicationStore 发起的全部操作入口）。
public enum ApplicationAction: Sendable {
    // MARK: - 会话管理
    case createSession(title: String? = nil, mode: AgentMode = .build)
    case switchSession(SessionID)
    case renameSession(SessionID, newTitle: String)
    case deleteSession(SessionID)
    case listSessions

    // MARK: - Prompt & 执行
    case submitPrompt(String)
    case cancelRun(RunID, reason: String? = nil)
    case stopCurrentRun
    case setMode(AgentMode)
    case setPermissionConfiguration(PermissionConfiguration)
    case setReasoningEffort(ReasoningEffort)

    // MARK: - HITL 交互
    case respondInteraction(interactionID: InteractionID, resolution: InteractionResolution)
    case grantPermission(interactionID: InteractionID, decision: PermissionDecision)
    case replyQuestion(interactionID: InteractionID, reply: QuestionReply)
    case submitDecision(interactionID: InteractionID, decision: String)

    // MARK: - Provider & Model
    case selectModel(ModelID)
    case listProviders
    case listModels

    // MARK: - 上下文与扩展
    case compactContext(SessionID? = nil)
    case refreshExtensions
    case refreshDiagnostics

    // MARK: - 命令总线
    case executeCommand(rawInput: String)

    // MARK: - 连接生命周期
    case connect
    case disconnect
    case reconnect

    // MARK: - 内部语义事件派发（由 Store 订阅 Client 后触发）
    case _connectionStateChanged(ConnectionState)
    case _runtimeEventReceived(RuntimeEventEnvelope)
    case _sessionEventReceived(SessionEventEnvelope)
    case _streamFrameReceived(StreamFrame)
    case _snapshotResynced(SessionSnapshot)
    case _runtimeInfoResynced(RuntimeInfo)
    case _runtimeHealthResynced(RuntimeHealth)
    case _runtimeCapabilitiesResynced(RuntimeCapabilities)
}
