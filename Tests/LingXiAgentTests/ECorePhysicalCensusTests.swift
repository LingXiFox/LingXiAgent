import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// The authoritative E-Core physical census.
///
/// `storageMetrics` used to be derived from `listObjects()`, which enumerates `.meta.json`, while
/// `pageOut()` deliberately writes only `<objectID>.txt`. So every page-out payload was invisible
/// to `objectCount` / `totalBytes` — the exact population a P/E-Core endurance run measures, and
/// the reason a leak could not be distinguished from a correct deduplicating store.
///
/// These tests pin the census to physical payloads rather than to any metadata shape, because the
/// point of the fix is that the number tracks bytes on disk (or in the memory backend) no matter
/// which of the three object kinds produced them.
@Suite("E-Core authoritative physical census", .serialized)
struct ECorePhysicalCensusTests {

    private func makeStore(persisting: Bool = true) -> (ECoreObjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-census-\(UUID().uuidString)")
        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: persisting,
            objectizationThreshold: 1,
            heatTrackingEnabled: true
        )
        return (ECoreObjectStore(baseDirectory: dir, configuration: config), dir)
    }

    private func reopen(_ dir: URL) -> ECoreObjectStore {
        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            objectizationThreshold: 1,
            heatTrackingEnabled: true
        )
        // A fresh instance over the same directory is the cold-start case: nothing in memory,
        // the disk is the only truth.
        return ECoreObjectStore(baseDirectory: dir, configuration: config)
    }

    private func pageOut(_ store: ECoreObjectStore, _ session: SessionID, content: String,
                         occurrence: String, epoch: Int = 1, tool: String? = nil) async -> ECoreReference {
        await store.pageOut(sessionID: session, content: content, origin: .message,
                            contextOccurrenceID: occurrence, evictionEpoch: epoch,
                            summary: "census probe", toolName: tool)
    }

    // MARK: - Requirement: page-out payloads are in the census at all

    @Test("a page-out payload is counted, with its real byte size")
    func pageOutIsInCensus() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-pageout")
        let content = String(repeating: "page-out payload line\n", count: 12)

        #expect(await store.storageMetrics(for: session).count == 0, "空会话不应有载荷")

        _ = await pageOut(store, session, content: content, occurrence: "occ-1")

        let metrics = await store.storageMetrics(for: session)
        #expect(metrics.count == 1, "page-out 载荷没进普查：\(metrics.count)")
        #expect(metrics.totalBytes == content.utf8.count,
                "字节数应为真实载荷大小：\(metrics.totalBytes) vs \(content.utf8.count)")
    }

    @Test("both object kinds reach the same census")
    func storeAndPageOutBothCounted() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-union")
        let stored = "tool artifact content for census"
        let paged = String(repeating: "paged out content\n", count: 5)

        _ = await store.store(sessionID: session, toolCallID: ToolCallID("call-a"),
                              toolName: "read_file", content: stored, force: true)
        _ = await pageOut(store, session, content: paged, occurrence: "occ-a")

        let metrics = await store.storageMetrics(for: session)
        #expect(metrics.count == 2, "两条来源应合并成一个口径：\(metrics.count)")
        #expect(metrics.totalBytes == stored.utf8.count + paged.utf8.count,
                "总字节应覆盖 store() 与 pageOut() 两份载荷")
    }

    // MARK: - Requirements 1..4: dedupe and the object/reference boundary

    @Test("repeated page-out of identical content adds references, not objects")
    func duplicatePageOutCountsOnce() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-dedupe")
        let content = String(repeating: "same bytes every time\n", count: 8)

        let first = await pageOut(store, session, content: content, occurrence: "turn-1")
        let second = await pageOut(store, session, content: content, occurrence: "turn-2")
        let third = await pageOut(store, session, content: content, occurrence: "turn-3", epoch: 2)

        // Distinct occurrences must stay distinct references.
        #expect(first.referenceID != second.referenceID && second.referenceID != third.referenceID,
                "occurrence 身份被合并了，Exact Restore 会指错")
        #expect(first.objectID == second.objectID && second.objectID == third.objectID,
                "同内容应落回同一个 payload 身份")

        let metrics = await store.storageMetrics(for: session)
        #expect(metrics.count == 1, "三个引用把对象数撑到了 \(metrics.count)")
        #expect(metrics.totalBytes == content.utf8.count,
                "重复 page-out 把字节数撑大了：\(metrics.totalBytes)")

        // The census must not be a reference count wearing another name.
        #expect(await store.references(sessionID: session).count == 3)
    }

    @Test("dropping one of several references leaves the object in place")
    func dropOneReferenceKeepsObject() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-partial")
        let content = String(repeating: "shared by two references\n", count: 6)

        let first = await pageOut(store, session, content: content, occurrence: "occ-1")
        let second = await pageOut(store, session, content: content, occurrence: "occ-2")
        #expect(await store.storageMetrics(for: session).count == 1)

        await store.dropReference(sessionID: session, referenceID: first.referenceID)

        let after = await store.storageMetrics(for: session)
        #expect(after.count == 1, "还有一个引用指向它，对象不该消失")
        #expect(after.totalBytes == content.utf8.count)
        // And it must still be exactly restorable through the surviving reference.
        #expect(try await store.restore(sessionID: session, referenceID: second.referenceID) == content,
                "幸存引用被连带破坏了")
    }

    // MARK: - Requirement 5: last reference reclaims

    @Test("dropping the last reference reduces count and bytes")
    func dropLastReferenceReclaims() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-reclaim")
        let content = String(repeating: "reclaimable payload\n", count: 7)

        let a = await pageOut(store, session, content: content, occurrence: "occ-1")
        let b = await pageOut(store, session, content: content, occurrence: "occ-2")
        await store.dropReference(sessionID: session, referenceID: a.referenceID)
        #expect(await store.storageMetrics(for: session).count == 1)

        await store.dropReference(sessionID: session, referenceID: b.referenceID)
        let after = await store.storageMetrics(for: session)
        #expect(after.count == 0, "最后一个引用删完，对象数应归零：\(after.count)")
        #expect(after.totalBytes == 0, "字节数没跟着降：\(after.totalBytes)")
        #expect(await store.hasObject(sessionID: session, objectID: a.objectID) == false,
                "普查说没了，磁盘上却还留着")
    }

    // MARK: - Requirements 6 and 7: restart and memory backend

    @Test("the census is identical across a Core restart")
    func censusSurvivesRestartIdentically() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-restart")
        let kept = String(repeating: "kept across restart\n", count: 9)
        let dropped = String(repeating: "dropped across restart\n", count: 4)

        _ = await store.store(sessionID: session, toolCallID: ToolCallID("call-k"),
                              toolName: "read_file", content: kept, force: true)
        let survivor = await pageOut(store, session, content: kept, occurrence: "occ-k")
        let gone = await pageOut(store, session, content: dropped, occurrence: "occ-gone")
        await store.dropReference(sessionID: session, referenceID: gone.referenceID)

        let before = await store.storageMetrics(for: session)
        // `kept` arrives through both `store()` and `pageOut()`; one content-addressed payload
        // counts once, and the dropped object is gone, so exactly one object remains.
        #expect(before.count == 1, "重启前基线就不对：\(before.count)")

        let reopened = reopen(dir)
        let after = await reopened.storageMetrics(for: session)
        #expect(after == before,
                "重启前后 storageMetrics 必须完全一致，否则长期趋势无法判读：\(before) -> \(after)")

        // A census that matches but cannot serve payloads from a cold start is useless: this is
        // the same reference, created by the previous process, restored by the new one.
        #expect(try await reopened.restore(sessionID: session,
                                       referenceID: survivor.referenceID) == kept,
                "重启后 Exact Restore 取不回原载荷，普查的「存在」就是虚报")
    }

    /// The cold-start reclaim bug.
    ///
    /// `dropReference` read only the in-memory reference table, which is empty after a restart, so
    /// it returned early and the payload was never reclaimed. A census that is right at restart but
    /// cannot shrink afterwards would still report a leak forever, which is the failure this whole
    /// exercise is trying to make visible.
    @Test("a reference created before a restart can still be dropped after it")
    func dropReferenceWorksAfterRestart() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-cold-drop")
        let content = String(repeating: "orphan after restart\n", count: 6)

        let reference = await pageOut(store, session, content: content, occurrence: "occ-1")
        #expect(await store.storageMetrics(for: session).count == 1)

        let reopened = reopen(dir)
        await reopened.dropReference(sessionID: session, referenceID: reference.referenceID)

        let after = await reopened.storageMetrics(for: session)
        #expect(after.count == 0, "重启后删除失效，载荷成为永久孤儿：\(after)")
        #expect(after.totalBytes == 0)
    }

    @Test("the memory backend reports a census with the same semantics")
    func memoryBackendCensusIsConsistent() async {
        let (store, dir) = makeStore(persisting: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-memory")
        let content = String(repeating: "memory payload\n", count: 10)

        _ = await store.store(sessionID: session, toolCallID: ToolCallID("m-1"),
                              toolName: "grep_search", content: "tool artifact", force: true)
        let a = await pageOut(store, session, content: content, occurrence: "occ-1")
        let b = await pageOut(store, session, content: content, occurrence: "occ-2")

        let metrics = await store.storageMetrics(for: session)
        #expect(metrics.count == 2, "内存后端应给出同样口径：\(metrics.count)")
        #expect(metrics.totalBytes == "tool artifact".utf8.count + content.utf8.count)

        await store.dropReference(sessionID: session, referenceID: a.referenceID)
        #expect(await store.storageMetrics(for: session).count == 2, "还有引用时不该减少")
        await store.dropReference(sessionID: session, referenceID: b.referenceID)
        let final = await store.storageMetrics(for: session)
        #expect(final.count == 1, "最后一个引用删完应回到只剩工具产物：\(final.count)")
    }

    // MARK: - Object identity, unified (Phase 1)

    /// `store()` and `pageOut()` both derive identity as `SHA256(canonicalPayloadBytes)`, so
    /// identical bytes arriving through both paths occupy ONE file and the census reports one
    /// object. The legacy tool-scoped form (`generate`) remains readable through
    /// `ContextObjectID.legacyToolScoped` for objects written before this change; references
    /// carry their object id, so old files keep resolving, but no new path may write it.
    ///
    /// Dedupe must still not merge lifecycle: two references to one payload keep their own
    /// occurrence identity and metadata.
    @Test("identical bytes via both paths are one payload with two independent references")
    func sameBytesViaBothPathsShareOneObject() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-divergence")
        let content = String(repeating: "shared bytes\n", count: 6)

        let stored = await store.store(sessionID: session, toolCallID: ToolCallID("d-1"),
                                       toolName: "read_file", content: content, force: true)
        let paged = await pageOut(store, session, content: content, occurrence: "occ-d")

        #expect(stored != nil)
        #expect(stored?.objectID == paged.objectID,
                "一套 payload 只允许一个内容寻址身份；出现两个就说明 id 派生又分叉了")
        #expect(await store.storageMetrics(for: session).count == 1,
                "同一个文件不得被普查数成两个对象")
        // Payload dedupe must not collapse the two references into one lifecycle.
        #expect(paged.contextOccurrenceID == "occ-d")
        #expect(try await store.restore(sessionID: session, referenceID: paged.referenceID) == content,
                "去重后每个引用仍要能各自 Exact Restore 回完整载荷")
    }

    // MARK: - prune and cleanSession

    @Test("pruning a tool artifact shrinks the census by exactly that object")
    func pruneShrinksCensus() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-prune")
        let keptByReference = String(repeating: "paged and referenced\n", count: 5)

        _ = await store.store(sessionID: session, toolCallID: ToolCallID("keep"),
                              toolName: "read_file", content: "kept artifact", force: true)
        _ = await store.store(sessionID: session, toolCallID: ToolCallID("drop"),
                              toolName: "grep_search", content: "dropped artifact", force: true)
        let paged = await pageOut(store, session, content: keptByReference, occurrence: "occ-p")
        #expect(await store.storageMetrics(for: session).count == 3)

        await store.prune(sessionID: session, keepingToolCallIDs: [ToolCallID("keep")])
        let after = await store.storageMetrics(for: session)
        #expect(after.count == 2, "prune 后应只剩保留产物与 page-out 载荷：\(after.count)")
        #expect(try await store.restore(sessionID: session, referenceID: paged.referenceID) == keptByReference,
                "prune 误伤了仍被引用的 page-out 载荷")
    }

    @Test("cleanSession zeroes the census and it stays zero after a reopen")
    func cleanSessionZeroes() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID("s-census-clean")
        _ = await pageOut(store, session, content: "clear me", occurrence: "occ-1")
        #expect(await store.storageMetrics(for: session).count == 1)

        await store.cleanSession(sessionID: session)
        #expect(await store.storageMetrics(for: session).count == 0)

        // cleanSession deletes the directory; a reopened store must agree, not resurrect a cache.
        let reopened = reopen(dir)
        #expect(await reopened.storageMetrics(for: session).count == 0)
    }

    // MARK: - Protocol compatibility

    @Test("a panel from a pre-census Core still decodes, and says its count is not physical")
    func legacyPanelDecodes() throws {
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DebugECorePanel(objectCount: 3, metaIndexObjectCount: 3))
        ) as! [String: Any]
        json.removeValue(forKey: "censusIsPhysical")
        json.removeValue(forKey: "metaIndexObjectCount")
        json.removeValue(forKey: "metaIndexTotalBytes")
        let decoded = try JSONDecoder().decode(DebugECorePanel.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.objectCount == 3)
        #expect(decoded.censusIsPhysical == false, "旧 Core 的 objectCount 是 meta-index 口径，不能被当成权威普查")
        #expect(decoded.metaIndexObjectCount == nil)

        let current = DebugECorePanel(objectCount: 5, metaIndexObjectCount: 2)
        let roundTrip = try JSONDecoder().decode(DebugECorePanel.self, from: JSONEncoder().encode(current))
        #expect(roundTrip == current)
        #expect(roundTrip.censusBlindSpotObjectCount == 3)
    }
}
