import Foundation

/// 统一前端抽象，解耦表现层与业务中枢。
/// 任何交互层（TUI、GUI、Web、Daemon Remote 等）均实现该协议，
/// 由 Composition Root 装配依赖并调用启动。
public protocol Frontend: AnyObject, Sendable {
    /// 运行前端界面，挂载到由 Composition Root 准备完毕的 ApplicationStore
    @MainActor
    func run(with store: ApplicationStore) async throws
}
