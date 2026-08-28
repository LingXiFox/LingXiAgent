import Foundation
import LingXiProtocol

/// Agent 最小编排入口（Session 化）。
/// sendMessage：append user → SessionContextBuilder 构建模型输入 → 推理。
/// 高频 delta 只走 DMA + 本轮内存 buffer 聚合；
/// Session 在 turn 完成时一次性写入最终 assistant content。
/// 本类型不解析任何 Provider JSON。
public actor AgentRuntime {
    private let store: any SessionStore
    private let contextBuilder: SessionContextBuilder
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let eventSink: @Sendable (CoreEvent) async -> Void
    private var runtimes: [SessionID: SessionRuntime] = [:]

    init(
        store: any SessionStore,
        contextBuilder: SessionContextBuilder,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void
    ) {
        self.store = store
        self.contextBuilder = contextBuilder
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.eventSink = eventSink
    }

    // MARK: - Session 生命周期

    public func createSession() async throws -> SessionID {
        let session = try await store.create()
        runtimes[session.id] = makeRuntime(for: session.id)
        await eventSink(.sessionCreated(session.id))
        return session.id
    }

    public func listSessions() async throws -> [SessionInfo] {
        try await store.listSessions().map { $0.toInfo() }
    }

    public func sessionSnapshot(_ id: SessionID) async throws -> SessionSnapshot {
        try await store.session(id).toSnapshot()
    }

    // MARK: - 对话

    /// 在 Session 中发起一轮对话，返回该轮的 DMA 通道。
    public func sendMessage(_ sessionID: SessionID, _ content: String) async throws -> OpenedStream {
        guard let runtime = runtimes[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        return try await runtime.startTurn(content)
    }

    // MARK: - Private

    private func makeRuntime(for sessionID: SessionID) -> SessionRuntime {
        SessionRuntime(
            store: store,
            sessionID: sessionID,
            modelBus: modelBus,
            dataPlane: dataPlane,
            contextBuilder: contextBuilder,
            eventSink: eventSink
        )
    }
}
