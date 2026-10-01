import Foundation
import Testing
@testable import LingXiPluginSDK

/// 运行时信息的权威语义:只有 Core 推送过快照之后才有值,推送不了就显式不可用。
///
/// 这一组测试存在的理由是一个具体的旧行为:`DefaultPluginInfoHub` 曾经预置
/// `activeModelID = "unknown"`、P/E `idle`、TTFT `0`、workspace 取当前工作目录,
/// 于是「宿主没告诉我」和「宿主真的空闲」在插件眼里长得一样。
struct PluginInfoHubTests {

    private func workspace(_ path: String = "/repo") -> PluginWorkspaceInfo {
        PluginWorkspaceInfo(rootPath: path, isGitRepository: true, coreVersion: "1.1.0")
    }

    @Test("with no snapshot received, every section reports unavailable")
    func emptyHubIsUnavailable() async {
        let hub = DefaultPluginInfoHub()
        for field in PluginInfoField.allCases {
            await #expect(throws: PluginInfoUnavailable(field: field, lastObservedAt: nil)) {
                try await read(hub, field)
            }
        }
    }

    @Test("a section Core did not state is unavailable, even though the snapshot arrived")
    func partialSnapshot() async throws {
        let hub = DefaultPluginInfoHub()
        let observedAt = Date(timeIntervalSince1970: 777)
        // 没有会话上下文时,Core 只发布工作区段落。
        await hub.apply(PluginRuntimeSnapshot(observedAt: observedAt, workspace: workspace()))
        #expect(try await hub.getWorkspaceInfo().rootPath == "/repo")
        await #expect(throws: PluginInfoUnavailable(field: .contextState, lastObservedAt: observedAt)) {
            try await hub.getContextState()
        }
    }

    @Test("the newest snapshot wins, and a stale one cannot overwrite it")
    func ordering() async throws {
        let hub = DefaultPluginInfoHub()
        let newer = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 1_000)
        await hub.apply(PluginRuntimeSnapshot(observedAt: newer, workspace: workspace("/newer")))
        await hub.apply(PluginRuntimeSnapshot(observedAt: older, workspace: workspace("/older")))
        #expect(try await hub.getWorkspaceInfo().rootPath == "/newer")
        #expect(await hub.latestSnapshot?.observedAt == newer)
    }

    /// 一次快照是完整替换,不是增量合并:Core 每次都发布它当下知道的全貌。
    /// 合并语义会在会话结束时留下上一个会话的 P/E 指标,那是比缺席更糟的错数据。
    @Test("a newer snapshot replaces the previous one rather than merging into it")
    func snapshotsReplace() async throws {
        let hub = DefaultPluginInfoHub()
        await hub.apply(PluginRuntimeSnapshot(
            observedAt: Date(timeIntervalSince1970: 1),
            peCore: PluginPECoreInfo(eCoreObjects: 7, eCoreReferences: 4),
            workspace: workspace()))
        await hub.apply(PluginRuntimeSnapshot(
            observedAt: Date(timeIntervalSince1970: 2),
            workspace: workspace("/second")))
        #expect(try await hub.getWorkspaceInfo().rootPath == "/second")
        await #expect(throws: PluginInfoUnavailable(field: .peCore, lastObservedAt: Date(timeIntervalSince1970: 2))) {
            _ = try await hub.getPECoreInfo()
        }
    }

    @Test("absent fields stay nil instead of being filled with plausible zeros")
    func noFabricatedValues() async throws {
        let hub = DefaultPluginInfoHub()
        await hub.apply(PluginRuntimeSnapshot(
            contextState: PluginContextStateInfo(),
            peCore: PluginPECoreInfo(eCoreObjects: 0),
            workspace: workspace("/x")))
        let context = try await hub.getContextState()
        #expect(context.activeModelID == nil)
        #expect(context.messageCount == nil)
        #expect(context.totalTokenUsage == nil)
        #expect(context.contextWindowPercentage == nil)
        #expect(context.isCompacted == nil)
        #expect(context.recentTurns == nil)
        // E-Core 计数为 0 是真值(该会话确实没有对象),与「没告诉」不同。
        #expect(try await hub.getPECoreInfo().eCoreObjects == 0)
        // Core 目前不发布性能段落:它缺席,而不是 0 ms。
        await #expect(throws: (any Error).self) { _ = try await hub.getPerformanceInfo() }
    }

    @Test("unavailability names the missing section and the last observation time")
    func errorCarriesContext() async throws {
        let hub = DefaultPluginInfoHub()
        let observed = Date(timeIntervalSince1970: 500)
        await hub.apply(PluginRuntimeSnapshot(observedAt: observed, workspace: nil))
        do {
            _ = try await hub.getPECoreInfo()
            Issue.record("expected PluginInfoUnavailable")
        } catch let error as PluginInfoUnavailable {
            #expect(error.field == .peCore)
            #expect(error.lastObservedAt == observed)
            #expect(error.description.contains("peCore"))
        }
    }

    private func read(_ hub: DefaultPluginInfoHub, _ field: PluginInfoField) async throws -> Any {
        switch field {
        case .contextState: return try await hub.getContextState()
        case .peCore: return try await hub.getPECoreInfo()
        case .performance: return try await hub.getPerformanceInfo()
        case .workspace: return try await hub.getWorkspaceInfo()
        }
    }
}
