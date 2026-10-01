import Foundation
import LingXiProtocol
import LingXiPluginSDK

// Core 交给插件的运行快照。
//
// 这里是快照的唯一装配点:每个字段都取 Core 当下真的知道的状态,拿不到的一律缺席,
// 由插件侧以 `PluginInfoUnavailable` 感知。曾经的 `DefaultPluginInfoHub` 用
// `unknown` / `idle` / `0` / 当前目录预置过这些值,那等于让 SDK 冒充宿主。

extension CoreHost {
    /// 装配一次权威快照。
    ///
    /// - Parameter sessionID: 触发快照的会话。没有会话上下文时只发布工作区段落 ——
    ///   上下文与 P/E 指标都是会话级的,没有会话就没什么可说。
    func pluginRuntimeSnapshot(sessionID: SessionID?) async -> PluginRuntimeSnapshot {
        let summary = await getWorkspaceSummary()
        let workspace = PluginWorkspaceInfo(
            rootPath: summary.rootPath,
            isGitRepository: summary.isGitRepository,
            currentGitBranch: summary.gitBranch,
            // 非 Git 工作区没有"变更文件数"这个概念,不是 0。
            dirtyFileCount: summary.isGitRepository ? summary.changedFileCount : nil,
            coreVersion: CoreHost.coreVersion
        )

        guard let sessionID, let session = try? await sessionStore.session(sessionID) else {
            return PluginRuntimeSnapshot(workspace: workspace)
        }

        // E-Core 的两个计数直接来自对象库;P-Core 的 token 占用只有在实际组装模型
        // 请求时才存在,这里不猜。
        let eCoreObjects = await ecoreStoreRef.listObjects(sessionID: sessionID).count
        let eCoreReferences = await ecoreStoreRef.references(sessionID: sessionID).count

        return PluginRuntimeSnapshot(
            contextState: PluginContextStateInfo(messageCount: session.messages.count),
            peCore: PluginPECoreInfo(
                eCoreObjects: eCoreObjects,
                eCoreReferences: eCoreReferences,
                reasoningEffort: session.reasoningEffort.rawValue,
                backgroundTaskCount: await backgroundManagerRef.runningTasksCount
            ),
            workspace: workspace
        )
    }

    /// 把上面的装配能力接到插件宿主层。必须在插件被发现之前调用,否则第一批插件
    /// 进程会带着没有 provider 的宿主跑起来。
    func installPluginSnapshotProvider() async {
        await extensionPlatform.setPluginSnapshotProvider(
            ClosurePluginRuntimeSnapshotProvider { [weak self] sessionID in
                guard let self else { return PluginRuntimeSnapshot() }
                return await self.pluginRuntimeSnapshot(sessionID: sessionID)
            }
        )
    }
}
