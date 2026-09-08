import Foundation
import LingXiProtocol

public typealias LingXiVNextClient = LingXiClientVNext

/// LingXiClientVNext：基于冻结 Protocol vNext 契约的全新正式客户端 SDK。
/// 仅负责 transport, connection, RPC, correlation, reconnect, replay, stream delivery, resource transfer。
/// 严格不包含 Timeline/UI/Thinking 投影，由上层 Application/TUI 实现。
public final class LingXiClientVNext: Sendable {
    public let transport: any ClientTransport
    public let sync: WatermarkSynchronizer
    public let streamBuffer: StreamFrameReorderBuffer
    public let replayCoordinator: EventReplayCoordinator

    // MARK: - 13 个 Typed Domain Facades
    public let runtime: RuntimeDomainClient
    public let session: SessionDomainClient
    public let turn: TurnDomainClient
    public let run: RunDomainClient
    public let interaction: InteractionDomainClient
    public let provider: ProviderDomainClient
    public let model: ModelDomainClient
    public let context: ContextDomainClient
    public let extensionDomain: ExtensionDomainClient
    public let workspace: WorkspaceDomainClient
    public let resource: ResourceDomainClient
    public let diagnostics: DiagnosticsDomainClient
    public let credential: CredentialDomainClient

    public init(
        transport: any ClientTransport,
        handshakeImmediately: Bool = true
    ) async throws {
        self.transport = transport
        let sync = WatermarkSynchronizer()
        let streamBuffer = StreamFrameReorderBuffer()
        self.sync = sync
        self.streamBuffer = streamBuffer
        self.replayCoordinator = EventReplayCoordinator(transport: transport, sync: sync, streamBuffer: streamBuffer)

        self.runtime = RuntimeDomainClient(transport: transport, replayCoordinator: replayCoordinator)
        self.session = SessionDomainClient(transport: transport, replayCoordinator: replayCoordinator)
        self.turn = TurnDomainClient(transport: transport)
        self.run = RunDomainClient(transport: transport)
        self.interaction = InteractionDomainClient(transport: transport)
        self.provider = ProviderDomainClient(transport: transport)
        self.model = ModelDomainClient(transport: transport)
        self.context = ContextDomainClient(transport: transport)
        self.extensionDomain = ExtensionDomainClient(transport: transport)
        self.workspace = WorkspaceDomainClient(transport: transport)
        self.resource = ResourceDomainClient(transport: transport)
        self.diagnostics = DiagnosticsDomainClient(transport: transport)
        self.credential = CredentialDomainClient(transport: transport)

        if handshakeImmediately {
            try await transport.connect()
        }
    }

    // MARK: - Application-Facing Factories (安全边界：严禁普通应用调用方伪造 trusted principal / workspace / admin identity)

    /// Application 面向消费方的标准连接工厂：
    /// 强制以未特权匿名安全上下文连接（isSystemAdmin = false, principal = nil, workspaceID = nil），
    /// 杜绝普通调用方伪造 trusted principal / workspace / admin 身份。
    public static func connectInProcess(
        service: any LingXiProtocolService,
        handshakeImmediately: Bool = true
    ) async throws -> LingXiClientVNext {
        let unprivilegedAuth = ContentAuthorizationContext.anonymous
        let transport = InProcessTransport(
            service: service,
            authorizationContext: unprivilegedAuth
        )
        return try await LingXiClientVNext(transport: transport, handshakeImmediately: handshakeImmediately)
    }

    /// 便捷工厂别名：强制使用非特权/匿名安全上下文
    public static func inProcess(
        service: any LingXiProtocolService,
        handshakeImmediately: Bool = true
    ) async throws -> LingXiClientVNext {
        try await connectInProcess(
            service: service,
            handshakeImmediately: handshakeImmediately
        )
    }

    /// Application 组合根使用的 stdio 工厂；普通调用方不能注入特权身份。
    public static func stdioCore(
        corePath: String? = nil,
        interactive: Bool = true,
        handshakeImmediately: Bool = true
    ) async throws -> LingXiClientVNext {
        let transport = try VNextStdioTransport(corePath: corePath, interactive: interactive)
        return try await LingXiClientVNext(transport: transport, handshakeImmediately: handshakeImmediately)
    }

    // MARK: - Security Boundary / Composition Root Trusted Factory

    /// 仅限系统内部 Bootstrap / 组合根（Composition Root）在受信任安全边界内注入特权与认证凭据
    public static func bootstrapTrustedInProcess(
        service: any LingXiProtocolService,
        trustedAuthorization: ContentAuthorizationContext,
        handshakeImmediately: Bool = true
    ) async throws -> LingXiClientVNext {
        let transport = InProcessTransport(
            service: service,
            authorizationContext: trustedAuthorization
        )
        return try await LingXiClientVNext(transport: transport, handshakeImmediately: handshakeImmediately)
    }

    // MARK: - Connection & Lifecycle
    public func connect() async throws {
        try await transport.connect()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    /// 执行重连流程：触发 transport 重新握手并保证状态机转变
    public func reconnect() async throws {
        try await transport.connect()
    }

    public var connectionState: ConnectionState {
        get async {
            await transport.connectionState
        }
    }

    public var stateUpdates: AsyncStream<ConnectionState> {
        transport.stateStream
    }

    // MARK: - High-Frequency StreamFrames
    /// 订阅 StreamFrame 数据帧：经由 StreamFrameReorderBuffer 严格保序、去重、缓存
    public func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64? = nil) async throws -> AsyncStream<StreamFrame> {
        let rawStream = try await transport.subscribeStreamFrames(streamID: streamID, afterIndex: afterIndex)
        return await streamBuffer.orderedStream(streamID: streamID, source: rawStream)
    }

    // MARK: - Watermark Synchronization
    /// 等待 CommandReceipt 中的全部 observedThrough 水位线被本地观察到。
    /// - Parameters:
    ///   - receipt: 命令回执。
    ///   - timeout: 超时时间。
    ///   - policy: 水位线同步策略。默认 .requireAllScopes（严禁静默跳过未订阅 scope）。
    ///   - autoSubscribeUnsubscribedScopes: 若为 true，对于未订阅 scope 自动拉起对应 consumer，并等待全部 watermark。
    public func awaitReceipt<T>(
        _ receipt: CommandReceipt<T>,
        timeout: TimeInterval = 10.0,
        policy: WatermarkSyncPolicy = .requireAllScopes,
        autoSubscribeUnsubscribedScopes: Bool = false
    ) async throws {
        if autoSubscribeUnsubscribedScopes {
            for watermark in receipt.observedThrough {
                if !(await sync.isScopeSubscribed(watermark.scope)) {
                    switch watermark.scope {
                    case let .session(sessionID):
                        // nil means live-only on the Core event log. Start at sequence zero so
                        // an automatically created consumer can observe this receipt's history.
                        let replayStart = EventCursor(generationID: watermark.cursor.generationID, sequence: 0)
                        let stream = try await session.events(sessionID: sessionID, after: replayStart)
                        Task {
                            for await _ in stream {}
                        }
                    case .runtime:
                        let replayStart = EventCursor(generationID: watermark.cursor.generationID, sequence: 0)
                        let stream = await runtime.events(after: replayStart)
                        Task {
                            for await _ in stream {}
                        }
                    case .unknown:
                        break
                    }
                }
            }
        }
        try await sync.awaitReceipt(receipt, timeout: timeout, policy: policy)
    }
}
