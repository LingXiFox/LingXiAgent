import Foundation
import LingXiProtocol

/// 统一前端运行时协议 (FrontendRuntime)。
/// 前端视图层（TUI、GUI、Web、Headless）仅面向此协议编程，完全解耦具体 Store 依赖。
public protocol FrontendRuntime: AnyObject, Sendable {
    /// 获取当前权威应用状态快照
    var state: ApplicationState { get async }

    /// 订阅增量变更流 (带 Revision 与 ChangeSet)
    var updates: AsyncStream<ApplicationUpdate> { get async }

    /// 向业务中枢派发前端意图
    func dispatch(_ action: ApplicationAction) async

    /// 获取当前可用应用命令注册列表
    var availableCommands: [ApplicationCommand] { get async }

    /// 获取工作区符号与引用候选列表
    func workspaceReferenceCandidates() async -> [String]

    /// 获取后台任务列表
    func getBackgroundTasks() async throws -> [BackgroundTaskSnapshot]

    /// 终止指定后台任务
    func terminateBackgroundTask(id: String) async throws -> Bool

    /// 执行前端命令
    func executeCommand(_ input: String) async throws -> ApplicationCommandResult
}

public extension FrontendRuntime {
    func workspaceReferenceCandidates() async -> [String] {
        []
    }

    func getBackgroundTasks() async throws -> [BackgroundTaskSnapshot] {
        []
    }

    func terminateBackgroundTask(id: String) async throws -> Bool {
        false
    }

    func executeCommand(_ input: String) async throws -> ApplicationCommandResult {
        ApplicationCommandResult(output: "Command not supported in this runtime")
    }
}

/// 统一前端交互抽象，解耦表现层与业务中枢。
/// 任何交互层（TUI、GUI、Web、Daemon Remote 等）均实现该协议，
/// 由 Composition Root 装配依赖并调用启动。
public protocol Frontend: AnyObject, Sendable {
    /// 运行前端界面，挂载到统一准备完毕的 FrontendRuntime
    @MainActor
    func run(with runtime: any FrontendRuntime) async throws
}

public extension Frontend {
    /// 兼容旧版基于具体 ApplicationStore 启动的签名
    @MainActor
    func run(with store: ApplicationStore) async throws {
        try await run(with: store as any FrontendRuntime)
    }
}
