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
    public static func stdioCore(corePath: String? = nil) throws -> LingXiClient {
        LingXiClient(connection: try StdioConnection(corePath: resolveCorePath(corePath)))
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
