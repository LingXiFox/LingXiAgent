import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态与对外契约实现。
public actor CoreHost: CoreEndpoint {
    public static let coreVersion = "0.1.0"
    public static let protocolVersion = "1"

    public let info: CoreInfo
    private let bus = CommandBus()
    private let dataPlane = DataPlane()
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]

    public init() {
        info = CoreInfo(
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: Self.protocolVersion
        )
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        await bus.add(.ping) { .pong }
        await bus.add(.getInfo) { [self] in .info(info) }
        await bus.add(.getState) { [self] in .state(await state) }
        // .openTestStream 属于数据面，不在控制面路由表中。
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

    public func openTestStream() async throws -> OpenedStream {
        await dataPlane.openTestStream()
    }

    // MARK: - Private

    private func setState(_ newState: CoreState) {
        state = newState
        eventContinuations.values.forEach { $0.yield(.stateChanged(newState)) }
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }
}
