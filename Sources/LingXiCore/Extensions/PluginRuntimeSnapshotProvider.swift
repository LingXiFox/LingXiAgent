import Foundation
import LingXiProtocol
import LingXiPluginSDK

/// Core 交给插件的唯一权威运行快照来源。
///
/// 快照只能由 Core 装配:SDK 侧不读 Core 的文件、不开 SQLite、不扫工作区,也不
/// 猜环境变量。插件能看到的一切宿主状态,都必须经过这里。
public protocol PluginRuntimeSnapshotProviding: Sendable {
    /// - Parameter sessionID: 触发本次快照的会话;`nil` 表示握手期还没有会话上下文。
    func snapshot(sessionID: SessionID?) async -> PluginRuntimeSnapshot
}

/// 没有接入真实宿主状态时的 provider。
///
/// 它只声明协议版本,四个段落一律缺席 —— 于是插件读到 `PluginInfoUnavailable`。
/// 这是有意的:宁可让插件知道「宿主没告诉我」,也不要让它以为宿主真的空闲。
public struct EmptyPluginRuntimeSnapshotProvider: PluginRuntimeSnapshotProviding {
    public init() {}

    public func snapshot(sessionID: SessionID?) async -> PluginRuntimeSnapshot {
        PluginRuntimeSnapshot()
    }
}

/// 闭包形式的 provider:CoreHost 用自己的状态装配快照,而不让扩展层反向依赖宿主。
public struct ClosurePluginRuntimeSnapshotProvider: PluginRuntimeSnapshotProviding {
    private let build: @Sendable (SessionID?) async -> PluginRuntimeSnapshot

    public init(_ build: @escaping @Sendable (SessionID?) async -> PluginRuntimeSnapshot) {
        self.build = build
    }

    public func snapshot(sessionID: SessionID?) async -> PluginRuntimeSnapshot {
        await build(sessionID)
    }
}
