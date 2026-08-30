import Foundation
import LingXiProtocol

/// 所有客户端访问 Core 的正式入口。
/// 面向未来 GUI 复用：不含任何 Terminal 概念。
public struct LingXiClient: Sendable {
    private let connection: any LingXiConnection

    public init(connection: any LingXiConnection) {
        self.connection = connection
    }

    /// 进程内连接（测试 / 嵌入式场景）。
    public static func inProcess(endpoint: any CoreEndpoint) -> LingXiClient {
        LingXiClient(connection: InProcessConnection(endpoint: endpoint))
    }

    /// 启动 LingXiCoreHost 子进程并连接。
    /// - Parameter corePath: core 可执行文件路径；
    ///   默认取环境变量 LINGXI_CORE_PATH，或本可执行文件同目录下的 LingXiCoreHost。
    public static func stdioCore(corePath: String? = nil, interactive: Bool = false) throws -> LingXiClient {
        LingXiClient(connection: try StdioConnection(corePath: resolveCorePath(corePath), interactive: interactive))
    }

    // MARK: - Core API

    public func coreInfo() async throws -> CoreInfo {
        guard case let .info(info) = try await connection.send(.getInfo) else {
            throw CoreError(code: .transport, message: "getInfo 收到非预期响应")
        }
        return info
    }

    public func coreState() async throws -> CoreState {
        guard case let .state(state) = try await connection.send(.getState) else {
            throw CoreError(code: .transport, message: "getState 收到非预期响应")
        }
        return state
    }

    /// ping → pong。成功即返回，失败抛错。
    public func ping() async throws {
        guard case .pong = try await connection.send(.ping) else {
            throw CoreError(code: .transport, message: "ping 收到非预期响应")
        }
    }

    /// 查询 Provider 配置状态（不含任何凭据）。
    public func providerStatus() async throws -> ProviderStatus {
        guard case let .providerStatus(status) = try await connection.send(.getProviderStatus) else {
            throw CoreError(code: .transport, message: "getProviderStatus 收到非预期响应")
        }
        return status
    }

    /// 订阅控制面语义事件（如状态变化）。
    public func events() async -> AsyncStream<CoreEvent> {
        await connection.events()
    }

    /// 订阅 Tool stdout/stderr 数据面；不经过 CoreEvent。
    public func toolOutputEvents() async -> AsyncStream<ToolOutputChunk> {
        await connection.toolOutputEvents()
    }

    /// 打开内置测试 Streaming DMA 通道。
    public func openTestStream() async throws -> AsyncThrowingStream<StreamChunk, Error> {
        try await connection.openTestStream()
    }

    // MARK: - Session API

    /// 创建新 Session。
    public func createSession() async throws -> SessionID {
        guard case let .sessionCreated(info) = try await connection.send(.createSession) else {
            throw CoreError(code: .transport, message: "createSession 收到非预期响应")
        }
        return info.id
    }

    /// 列出全部 Session（摘要）。
    public func sessions() async throws -> [SessionInfo] {
        guard case let .sessionList(infos) = try await connection.send(.listSessions) else {
            throw CoreError(code: .transport, message: "listSessions 收到非预期响应")
        }
        return infos
    }

    /// 查询 Session 完整消息历史（权威数据在 Core）。
    public func session(_ id: SessionID) async throws -> SessionSnapshot {
        guard case let .sessionDetail(snapshot) = try await connection.send(.getSession(sessionID: id)) else {
            throw CoreError(code: .transport, message: "getSession 收到非预期响应")
        }
        return snapshot
    }

    /// 对当前一次 Permission Request 作出 allow once 或 deny 答复。
    public func replyPermission(_ reply: PermissionReply) async throws {
        guard case .permissionReplyAccepted = try await connection.send(.replyPermission(reply)) else {
            throw CoreError(code: .transport, message: "replyPermission 收到非预期响应")
        }
    }

    public func replyQuestion(_ reply: QuestionReply) async throws {
        guard case let .questionReplyAccepted(questionID) = try await connection.send(.replyQuestion(reply)), questionID == reply.questionID else {
            throw CoreError(code: .transport, message: "replyQuestion 收到非预期响应")
        }
    }

    public func context(_ sessionID: SessionID) async throws -> ContextDebugSnapshot? {
        guard case let .context(snapshot) = try await connection.send(.getContext(sessionID: sessionID)) else {
            throw CoreError(code: .transport, message: "getContext 收到非预期响应")
        }
        return snapshot
    }

    public func performance(_ sessionID: SessionID) async throws -> TurnPerformanceReport? {
        guard case let .performance(report) = try await connection.send(.getPerformance(sessionID: sessionID)) else {
            throw CoreError(code: .transport, message: "getPerformance 收到非预期响应")
        }
        return report
    }

    public func permissionConfiguration() async throws -> PermissionConfiguration {
        guard case let .permissionConfiguration(configuration) = try await connection.send(.getPermissionConfiguration) else {
            throw CoreError(code: .transport, message: "getPermissionConfiguration 收到非预期响应")
        }
        return configuration
    }

    public func setPermissionConfiguration(_ configuration: PermissionConfiguration) async throws {
        guard case .permissionConfiguration = try await connection.send(.setPermissionConfiguration(configuration)) else {
            throw CoreError(code: .transport, message: "setPermissionConfiguration 收到非预期响应")
        }
    }

    public func projectCache() async throws -> ProjectCacheDebugSnapshot {
        guard case let .projectCache(snapshot) = try await connection.send(.getProjectCache) else {
            throw CoreError(code: .transport, message: "getProjectCache 收到非预期响应")
        }
        return snapshot
    }

    public func compact(_ sessionID: SessionID) async throws -> CompactSessionResponse {
        guard case let .compactSession(response) = try await connection.send(.compactSession(sessionID: sessionID)) else {
            throw CoreError(code: .transport, message: "compactSession 收到非预期响应")
        }
        return response
    }

    public func listChildSessions(_ parentSessionID: SessionID) async throws -> [SessionInfo] {
        guard case let .childSessionList(sessions) = try await connection.send(.listChildSessions(parentSessionID: parentSessionID)) else { throw CoreError(code: .transport, message: "listChildSessions 收到非预期响应") }
        return sessions
    }

    public func listAgentRuns(_ sessionID: SessionID) async throws -> [AgentRunInfo] {
        guard case let .agentRunList(runs) = try await connection.send(.listAgentRuns(sessionID: sessionID)) else { throw CoreError(code: .transport, message: "listAgentRuns 收到非预期响应") }
        return runs
    }

    public func getAgentRun(_ runID: AgentRunID) async throws -> AgentRunInfo {
        guard case let .agentRun(run) = try await connection.send(.getAgentRun(runID: runID)) else { throw CoreError(code: .transport, message: "getAgentRun 收到非预期响应") }
        return run
    }

    public func getAgentTree(_ rootSessionID: SessionID) async throws -> AgentTreeNode {
        guard case let .agentTree(tree) = try await connection.send(.getAgentTree(rootSessionID: rootSessionID)) else { throw CoreError(code: .transport, message: "getAgentTree 收到非预期响应") }
        return tree
    }

    public func subagentResult(_ runID: AgentRunID) async throws -> SubagentResult {
        guard case let .subagentResult(result) = try await connection.send(.getSubagentResult(runID: runID)) else { throw CoreError(code: .transport, message: "getSubagentResult 收到非预期响应") }
        return result
    }

    public func cancelAgentRun(_ runID: AgentRunID) async throws {
        guard case let .agentRunCancelled(id) = try await connection.send(.cancelAgentRun(runID: runID)), id == runID else { throw CoreError(code: .transport, message: "cancelAgentRun 收到非预期响应") }
    }

    /// 在 Session 中发起一轮对话，返回 Streaming DMA 通道。
    /// text/reasoning delta 从通道逐块流出（kind 区分）；
    /// turnCompleted / turnFailed 经 events() 交付。
    public func sendMessage(
        sessionID: SessionID,
        content: String
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        try await connection.sendMessage(sessionID: sessionID, content: content)
    }

    public func close() async {
        await connection.close()
    }

    // MARK: - Private

    private static func resolveCorePath(_ explicit: String?) -> String {
        if let explicit { return explicit }
        if let env = ProcessInfo.processInfo.environment["LINGXI_CORE_PATH"], !env.isEmpty {
            return env
        }
        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        return executableDir.appendingPathComponent("LingXiCoreHost").path
    }
}
