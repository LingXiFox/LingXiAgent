import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint {
    public static let coreVersion = "0.1.0"
    public static let protocolVersion = "1"

    public let info: CoreInfo
    private let bus = CommandBus()
    private let dataPlane = DataPlane()
    private let sessionStore: any SessionStore
    private let gateway: ModelGateway
    private let permissionEngine: PermissionEngine
    private let toolRuntime: ToolRuntime
    private var agent: AgentRuntime?
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]

    /// - Parameter providerAssembly: 显式注入 Provider 运行时（测试用）；nil 时从环境装配。
    public init(
        providerAssembly: ModelRuntimeAssembly? = nil,
        sessionStore: (any SessionStore)? = nil,
        workspaceRoot: WorkspaceRoot? = nil,
        permissionDecision: PermissionDecision? = nil
    ) throws {
        info = CoreInfo(
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: Self.protocolVersion
        )
        self.sessionStore = sessionStore ?? InMemorySessionStore()
        let workspace = try workspaceRoot ?? WorkspaceRoot.fromEnvironment()
        let configuredDecision = PermissionDecision(
            rawValue: ProcessInfo.processInfo.environment["LINGXI_TOOL_PERMISSION"] ?? ""
        ) ?? .ask
        let permissions = PermissionEngine(defaultDecision: permissionDecision ?? configuredDecision)
        permissionEngine = permissions
        toolRuntime = ToolRuntime(registry: .builtin(workspace: workspace), permissions: permissions)

        let (assembly, missing) = ProviderSetup.resolve()
        let effective = providerAssembly ?? assembly
        gateway = ModelGateway(
            provider: effective.provider,
            modelID: effective.modelID.rawValue.isEmpty ? nil : effective.modelID,
            missingRequirements: providerAssembly == nil ? missing : []
        )
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        await bus.add(.ping) { _ in .pong }
        await bus.add(.getInfo) { [self] _ in .info(info) }
        await bus.add(.getState) { [self] _ in .state(await state) }
        await bus.add(.getProviderStatus) { [self] _ in
            .providerStatus(await providerStatus)
        }
        await bus.add(.createSession) { [self] _ in
            let agent = try await requireAgent()
            let id = try await agent.createSession()
            let session = try await sessionStore.session(id)
            return .sessionCreated(session.toInfo())
        }
        await bus.add(.listSessions) { [self] _ in
            let agent = try await requireAgent()
            return .sessionList(try await agent.listSessions())
        }
        await bus.add(.getSession) { [self] command in
            let agent = try await requireAgent()
            guard case let .getSession(sessionID) = command else {
                return .error(CoreError(code: .unsupportedCommand, message: "getSession 参数缺失"))
            }
            return .sessionDetail(try await agent.sessionSnapshot(sessionID))
        }
        await bus.add(.replyPermission) { [self] command in
            guard case let .replyPermission(reply) = command else {
                return .error(CoreError(code: .unsupportedCommand, message: "replyPermission 参数缺失"))
            }
            try await permissionEngine.reply(reply)
            return .permissionReplyAccepted(reply.permissionID)
        }
        // .openTestStream / .sendMessage 属于数据面，不在控制面路由表中。

        let agent = AgentRuntime(
            store: sessionStore,
            contextBuilder: SessionContextBuilder(),
            modelBus: ModelBus(gateway: gateway),
            dataPlane: dataPlane,
            toolRuntime: toolRuntime
        ) { [weak self] event in
            await self?.broadcast(event)
        }
        self.agent = agent
        setState(.ready)
    }

    public func shutdown() async {
        setState(.shuttingDown)
        await dataPlane.closeAll()
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
    }

    // MARK: - CoreEndpoint（控制面）

    public func handle(_ command: ClientCommand) async throws -> CoreResponse {
        try await bus.dispatch(command)
    }

    public func events() -> AsyncStream<CoreEvent> {
        AsyncStream { continuation in
            let key = UUID()
            eventContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(key) }
            }
        }
    }

    // MARK: - CoreEndpoint（数据面）

    public func openDataStream(_ command: ClientCommand) async throws -> OpenedStream {
        switch command {
        case .openTestStream:
            return await dataPlane.openTestStream()
        case let .sendMessage(sessionID, content):
            let agent = try requireAgent()
            return try await agent.sendMessage(sessionID, content)
        default:
            throw CoreError(code: .unsupportedCommand, message: "该命令不属于数据面")
        }
    }

    // MARK: - 事件广播

    /// Agent 等模块经此把语义事件送入所有控制面订阅者。
    public func broadcast(_ event: CoreEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    // MARK: - Private

    private func requireAgent() throws -> AgentRuntime {
        guard let agent else {
            throw CoreError(code: .notReady, message: "Agent 尚未启动")
        }
        return agent
    }

    private var providerStatus: ProviderStatus {
        ProviderStatus(
            configured: gateway.isConfigured,
            model: gateway.modelID?.rawValue,
            baseURL: nil,
            missingRequirements: gateway.missingRequirements
        )
    }

    private func setState(_ newState: CoreState) {
        state = newState
        eventContinuations.values.forEach { $0.yield(.stateChanged(newState)) }
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }
}
