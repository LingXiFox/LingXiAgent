import Foundation
import LingXiPlatform
import LingXiProtocol

/// 强类型上下文对象唯一标识符
public struct ContextObjectID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(_ rawValue: String) throws {
        // 安全防御：严格禁止路径穿越，只允许字母数字短横线与下划线
        guard !rawValue.isEmpty,
              rawValue.count <= 128,
              rawValue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Invalid ContextObjectID: \(rawValue)")
        }
        self.rawValue = rawValue
    }

    public init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 依据工具调用与内容哈希确定性生成 ContextObjectID
    public static func generate(toolName: String, callID: ToolCallID, content: String) -> ContextObjectID {
        let sanitizedTool = toolName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let cleanTool = sanitizedTool.isEmpty ? "obj" : sanitizedTool
        let cleanCall = callID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(12)

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hashStr = String(format: "%08llx", hash)
        return ContextObjectID(unchecked: "obj_\(cleanTool)_\(cleanCall)_\(hashStr)")
    }

    /// 内容的身份：纯内容寻址，与后端、来源、turn、page-out 次数无关。
    ///
    /// 冻结语义（契约「补充冻结：ECoreObjectID 身份」）：
    /// - 相同 payload + 不同 backend → 相同 ID；
    /// - 相同 payload + 不同 turn / 不同 occurrence → 允许同一 ID（这是 payload 去重，不是生命周期合并）；
    /// - sessionID / toolCallID / origin / turn / 保留度等一律不属于对象身份，见 `ECoreReference`。
    ///
    /// 采用抗碰撞的 SHA256 而非 FNV-1a：ObjectID 同时承担 payload identity、内容去重与
    /// Exact Restore 定位，碰撞意味着把错误的 payload 当成正确对象恢复回来，
    /// 不属于可容忍的普通哈希冲突。摘要件复用平台层权威实现
    /// （`PlatformCrypto.sha256Hex`：Darwin 走 CryptoKit，其余平台走零依赖的 CompactSHA256），
    /// 不另写第二套内容哈希。
    ///
    /// 权威语义（契约「补充冻结：ECoreObjectID 身份」）：
    ///
    ///     ECoreObjectID = SHA256(canonicalPayloadBytes)
    ///
    /// 相同 canonical payload → 相同 ID；backend、session、tool/origin/occurrence 一律不影响 ID。
    public static func identify(content: String) -> ContextObjectID {
        ContextObjectID(unchecked: "obj_\(PlatformCrypto.sha256Hex(content))")
    }

    /// 仅供解析改动前落盘的遗留对象（文件名即 ID）。不得用于新写入。
    public static func legacyToolScoped(toolName: String, callID: ToolCallID, content: String) -> ContextObjectID {
        generate(toolName: toolName, callID: callID, content: content)
    }
}

/// 外部权威观测对象元数据（E-Core Context Object Metadata）
/// E-Core 对象的来源。见 `Docs/Decisions/PE-Core-Git-Semantics-Freeze-2026-09-30.md` 第八、九节：
/// E-Core 保存的是「从 P-Core 移出的完整 Context Object」，不限于工具产物，因此身份不能绑死 toolCallID。
public enum ECoreObjectOrigin: String, Sendable, Equatable, Codable {
    case toolCall
    case message
    case page
}

/// 一次具体的 P-Core → E-Core 引用关系。
///
/// 冻结语义：`ECoreObjectID` 只是内容身份；sessionID、toolCallID、origin、turn、保留度元数据、
/// page-out 原因、索引摘要统统属于「某一次引用」，因此必须与对象分离。允许多个引用指向同一
/// objectID（payload 去重），但**不得**因去重而合并、覆盖或跨 session 串用引用的元数据。
public struct ECoreReference: Sendable, Equatable, Codable {
    public let referenceID: String
    public let objectID: ContextObjectID
    public let sessionID: SessionID
    public let origin: ECoreObjectOrigin
    /// 仅工具来源携带；非工具引用不得伪造一个 toolCallID。
    public let toolCallID: ToolCallID?
    public let toolName: String?
    /// 进入 P-Core Index 的轻量摘要。禁止携带完整 payload（契约第一节）。
    public let summary: String
    /// 哪一次 Context occurrence 被移出。必须是 occurrence 级标识，不能是 source 级：
    /// 同一份内容在 Turn 15 与 Turn 40 各被移出一次，是两条引用、一个对象。
    public let contextOccurrenceID: String
    /// 第几轮淘汰事件。同一次 page-out 因 I/O 重试必须复用同一 epoch，从而得到同一 referenceID。
    public let evictionEpoch: Int
    public let createdTurn: Int?
    public let pageOutReason: String?
    public let createdAt: Date

    public init(
        objectID: ContextObjectID,
        sessionID: SessionID,
        origin: ECoreObjectOrigin,
        contextOccurrenceID: String,
        evictionEpoch: Int,
        summary: String,
        toolCallID: ToolCallID? = nil,
        toolName: String? = nil,
        createdTurn: Int? = nil,
        pageOutReason: String? = nil,
        createdAt: Date = .now
    ) {
        self.objectID = objectID
        self.sessionID = sessionID
        self.origin = origin
        self.contextOccurrenceID = contextOccurrenceID
        self.evictionEpoch = evictionEpoch
        self.summary = summary
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.createdTurn = createdTurn
        self.pageOutReason = pageOutReason
        self.createdAt = createdAt
        self.referenceID = ECoreReference.makeReferenceID(
            sessionID: sessionID, contextOccurrenceID: contextOccurrenceID, evictionEpoch: evictionEpoch
        )
    }

    /// 引用身份由 occurrence 决定，不由 payload 身份决定：
    /// 用 objectID 参与派生会让「同一 occurrence 的内容变化」连带改变引用身份，
    /// 而同一 occurrence 的重复 page-out（重试）必须幂等地落回同一条引用。
    public static func makeReferenceID(sessionID: SessionID, contextOccurrenceID: String, evictionEpoch: Int) -> String {
        "ref_\(PlatformCrypto.sha256Hex("\(sessionID.rawValue)\u{1f}\(contextOccurrenceID)\u{1f}\(evictionEpoch)"))"
    }
}

public struct ObservationMetadata: Sendable, Equatable, Codable {
    public let objectID: ContextObjectID
    public let toolCallID: ToolCallID
    public let toolName: String
    public let contentType: String
    public let totalLines: Int
    public let totalBytes: Int
    public let createdAt: Date
    public let contentHash: String
    /// nil 表示写入方未声明来源，按 `.toolCall` 解释（兼容既有对象与磁盘元数据）。
    public let origin: ECoreObjectOrigin?

    public init(
        objectID: ContextObjectID,
        toolCallID: ToolCallID,
        toolName: String,
        contentType: String = "text/plain",
        totalLines: Int,
        totalBytes: Int,
        createdAt: Date = .now,
        contentHash: String,
        origin: ECoreObjectOrigin? = nil
    ) {
        self.objectID = objectID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.contentType = contentType
        self.totalLines = totalLines
        self.totalBytes = totalBytes
        self.createdAt = createdAt
        self.contentHash = contentHash
        self.origin = origin
    }

    /// 是否随 toolCallID 生死。rewind 裁剪只能作用于工具产物。
    public var isToolArtifact: Bool { origin == nil || origin == .toolCall }
}

/// 召回切片数据传输对象
public struct RecallChunk: Sendable, Equatable, Codable {
    public let objectID: ContextObjectID
    public let offsetBytes: Int
    public let lengthBytes: Int
    public let content: String
    public let hasMore: Bool
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let totalBytes: Int

    public init(
        objectID: ContextObjectID,
        offsetBytes: Int,
        lengthBytes: Int,
        content: String,
        hasMore: Bool,
        startLine: Int,
        endLine: Int,
        totalLines: Int,
        totalBytes: Int
    ) {
        self.objectID = objectID
        self.offsetBytes = offsetBytes
        self.lengthBytes = lengthBytes
        self.content = content
        self.hasMore = hasMore
        self.startLine = startLine
        self.endLine = endLine
        self.totalLines = totalLines
        self.totalBytes = totalBytes
    }
}

/// 会话级外部存储指标（O(1) 维护，避免重复整盘扫描）
public struct SessionStorageMetrics: Sendable, Equatable {
    public let count: Int
    public let totalBytes: Int

    public init(count: Int = 0, totalBytes: Int = 0) {
        self.count = count
        self.totalBytes = totalBytes
    }
}

/// E-Core 对象 Fabric 存储器：负责管理会话级外部持久化对象。
/// 遵循三大纪律八项注意：
/// 1. Fail-Open：所有写入与读取异常降级处理，绝不崩溃智能体主流程。
/// 2. 安全防路径穿越：严密过滤 objectID 字符。
/// 3. 原子写入与去重。
public actor ECoreObjectStore {
    public let baseDirectory: URL
    public let configuration: ContextObjectFabricConfiguration
    public let telemetryLogger: ECoreTelemetryLogger
    private var metadataCache: [SessionID: [ContextObjectID: ObservationMetadata]] = [:]
    /// `eCorePersistenceEnabled == false` 时的 session-scoped 载荷后端。E-Core 是必选逻辑核心，
    /// 关闭持久化只表示载荷随会话结束消失，不表示 page-out 可以被拒绝或改投他处。
    private var memoryPayloads: [SessionID: [ContextObjectID: String]] = [:]
    private var heatStates: [SessionID: [ContextObjectID: ECoreHeatState]] = [:]
    private var projectionCounts: [SessionID: [ContextObjectID: Int]] = [:]
    private var cachedMetrics: [SessionID: SessionStorageMetrics] = [:]
    /// 权威物理普查：objectID -> 载荷字节数，覆盖当前**真实存在**的每一个 E-Core 载荷。
    ///
    /// 键是内容寻址的 objectID，所以这张表本质是集合，而普查需要的正是集合语义：
    /// 同一份字节既经 `store()` 又经 `pageOut()` 落盘、或一份载荷被四十条引用指向，都只占一项。
    /// 按引用计数会让一个去重存储的读数随 churn 增长——那正是泄漏检测器最不能有的性质。
    ///
    /// 之所以不从 `ObservationMetadata` 派生：`pageOut()` 有意不写 `.meta.json`。那不是遗漏，
    /// 而是职责边界——`ObservationMetadata` 描述工具产物语义（`toolCallID` 非可选），
    /// `ECoreReference` 描述 occurrence 生命周期，都不属于载荷本身。把 page-out 伪装成工具产物
    /// 来让旧口径变对，会同时弄脏这三者的语义。载荷的真相是 `objects/<objectID>.txt`，
    /// 于是普查就直接数它。
    private var physicalObjects: [SessionID: [ContextObjectID: Int]] = [:]
    /// 冷启动扫描每个会话只做一次；`storageMetrics` 的 O(1) 承诺靠它维持。
    private var censusLoaded: Set<SessionID> = []
    /// Developer Debug Mode 旁路。nil 表示未开启，此时下面每一处埋点都只是一次 nil 判断。
    ///
    /// 有意独立于 `configuration.heatTrackingEnabled`：热度统计关掉时，page-out 与 restore 的
    /// 计数仍然必须可用，否则「E-Core 有没有把内容找回来」这个问题会随一个无关开关一起消失。
    private var debugHub: DebugTelemetryHub?

    /// 由 CoreHost 在装配完成后注入。放在 setter 而不是构造参数里，是为了不惊动这一批已有调用方
    /// 与测试的构造签名 —— 观测能力不该要求每个使用者都学会传它。
    func attachDebugHub(_ hub: DebugTelemetryHub?) {
        debugHub = hub
    }
    public struct MutationSubscriptionToken: Hashable, Sendable {
        public let id: UUID
        public init(id: UUID = UUID()) { self.id = id }
    }
    private var mutationHooks: [MutationSubscriptionToken: @Sendable () async -> Void] = [:]

    public init(
        baseDirectory: URL? = nil,
        configuration: ContextObjectFabricConfiguration = ContextObjectFabricConfiguration(),
        telemetryLogger: ECoreTelemetryLogger? = nil
    ) {
        self.configuration = configuration
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        self.telemetryLogger = telemetryLogger ?? ECoreTelemetryLogger(baseDirectory: self.baseDirectory)
    }

    /// 注册变更通知钩子（供统一检索等外部系统感知 E-Core 对象变更，自动失效与增量重建）
    @discardableResult
    public func addMutationHook(_ hook: @escaping @Sendable () async -> Void) -> MutationSubscriptionToken {
        let token = MutationSubscriptionToken()
        mutationHooks[token] = hook
        return token
    }

    /// 注销变更通知钩子
    public func removeMutationHook(token: MutationSubscriptionToken) {
        mutationHooks.removeValue(forKey: token)
    }

    private func notifyMutation() {
        for hook in mutationHooks.values {
            Task { await hook() }
        }
    }

    /// 获取特定 Session 的对象存储根目录
    private func sessionObjectsDirectory(sessionID: SessionID) -> URL {
        let safeSessionID = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return baseDirectory
            .appendingPathComponent(safeSessionID, isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)
    }

    /// 载荷后端。开关的权威语义是「是否持久化」，不是「是否允许 E-Core」：
    /// true 走磁盘，false 走 session-scoped 内存。两种情况下 store() 都返回稳定 ECoreObjectID，
    /// page-out → E-Core → Exact Restore 的生命周期不因该开关改变。
    private var persistsPayloads: Bool { configuration.eCorePersistenceEnabled }

    private func payloadURL(sessionID: SessionID, objectID: ContextObjectID) -> URL {
        sessionObjectsDirectory(sessionID: sessionID)
            .appendingPathComponent("\(objectID.rawValue).txt", isDirectory: false)
    }

    private func metadataURL(sessionID: SessionID, objectID: ContextObjectID) -> URL {
        sessionObjectsDirectory(sessionID: sessionID)
            .appendingPathComponent("\(objectID.rawValue).meta.json", isDirectory: false)
    }

    /// 调用方必须处于 Fail-Open 保护下：持久化后端的磁盘异常沿现有路径降级。
    private func writePayload(sessionID: SessionID, objectID: ContextObjectID, content: String, metadata: ObservationMetadata) throws {        guard persistsPayloads else {
            memoryPayloads[sessionID, default: [:]][objectID] = content
            censusRegister(sessionID: sessionID, objectID: objectID, bytes: content.utf8.count)
            return
        }
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        try FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        let targetURL = payloadURL(sessionID: sessionID, objectID: objectID)
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try content.write(to: targetURL, atomically: false, encoding: .utf8)
        }
        try JSONEncoder().encode(metadata).write(to: metadataURL(sessionID: sessionID, objectID: objectID), options: [])
        censusRegister(sessionID: sessionID, objectID: objectID, bytes: content.utf8.count)
    }

    private func removePayload(sessionID: SessionID, objectID: ContextObjectID) {
        memoryPayloads[sessionID]?.removeValue(forKey: objectID)
        censusUnregister(sessionID: sessionID, objectID: objectID)
        guard persistsPayloads else { return }
        try? FileManager.default.removeItem(at: payloadURL(sessionID: sessionID, objectID: objectID))
        try? FileManager.default.removeItem(at: metadataURL(sessionID: sessionID, objectID: objectID))
    }

    // MARK: - 权威物理普查（physical census）

    /// 把会话的普查从磁盘（或内存后端）建立起来。每个会话只扫一次。
    ///
    /// 读的是 `.txt` 文件大小而不是元数据里记的字节数：载荷被截断写入或外部改动时，
    /// 一个声称「有多少字节」的仪表必须报它测到的值，而不是当初打算写的值。
    private func ensureCensusLoaded(sessionID: SessionID) {
        guard !censusLoaded.contains(sessionID) else { return }
        censusLoaded.insert(sessionID)
        var objects: [ContextObjectID: Int] = [:]
        if persistsPayloads {
            let dir = sessionObjectsDirectory(sessionID: sessionID)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )) ?? []
            for url in files where url.lastPathComponent.hasSuffix(".txt") {
                guard let objectID = try? ContextObjectID(url.deletingPathExtension().lastPathComponent) else { continue }
                objects[objectID] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        } else {
            for (objectID, content) in (memoryPayloads[sessionID] ?? [:]) {
                objects[objectID] = content.utf8.count
            }
        }
        physicalObjects[sessionID] = objects
        refreshCachedMetrics(sessionID: sessionID)
    }

    /// 登记一个载荷。重复登记同内容是无操作，这正是去重语义要求的。
    private func censusRegister(sessionID: SessionID, objectID: ContextObjectID, bytes: Int) {
        ensureCensusLoaded(sessionID: sessionID)
        guard physicalObjects[sessionID]?[objectID] == nil else { return }
        physicalObjects[sessionID, default: [:]][objectID] = max(0, bytes)
        refreshCachedMetrics(sessionID: sessionID)
    }

    private func censusUnregister(sessionID: SessionID, objectID: ContextObjectID) {
        ensureCensusLoaded(sessionID: sessionID)
        guard physicalObjects[sessionID]?.removeValue(forKey: objectID) != nil else { return }
        refreshCachedMetrics(sessionID: sessionID)
    }

    private func refreshCachedMetrics(sessionID: SessionID) {
        let objects = physicalObjects[sessionID] ?? [:]
        cachedMetrics[sessionID] = SessionStorageMetrics(
            count: objects.count,
            totalBytes: objects.values.reduce(0) { $0 + $1 }
        )
    }

    // MARK: - Page-out 引用层（契约「补充冻结：ECoreObjectID 身份」）

    /// 内容级对象记录：只描述 payload 本身。
    /// sessionID / origin / toolCallID / turn / 摘要 / page-out 原因一律在 `ECoreReference` 上，
    /// 不得回填到这里 —— 否则内容去重会把不同 occurrence 的生命周期元数据串在一起。
    private struct ECoreObjectRecord: Codable, Equatable {
        let objectID: ContextObjectID
        let totalBytes: Int
        let totalLines: Int
        let contentHash: String
    }

    private var pageOutObjects: [SessionID: [ContextObjectID: ECoreObjectRecord]] = [:]
    private var pageOutReferences: [SessionID: [String: ECoreReference]] = [:]
    private var lifecycle: [SessionID: ECoreLifecycleSnapshot] = [:]
    private var pendingRecallReferences: [SessionID: [String]] = [:]

    public func lifecycleSnapshot(sessionID: SessionID) -> ECoreLifecycleSnapshot {
        lifecycle[sessionID] ?? ECoreLifecycleSnapshot()
    }

    func noteLifecycle(sessionID: SessionID, phase: ECoreLifecycleEvent.Phase, referenceID: String? = nil, reason: String? = nil) {
        lifecycle[sessionID, default: ECoreLifecycleSnapshot()].record(.init(phase: phase, referenceID: referenceID, reason: reason))
        var detail = DebugECoreEvent(referenceID: referenceID)
        detail.lifecyclePhase = phase.rawValue
        detail.rejectionReason = reason
        debugHub?.record(DebugTelemetryEvent(sequence: 0, timestamp: .now,
            category: phase == .recallRejected ? .eCoreRecallFailed : (phase.rawValue.hasPrefix("pageOut") ? .eCorePageOut : .eCoreExactRestore),
            sessionID: sessionID, referenceID: referenceID, eCoreEvent: detail))
    }

    /// The tool resolves a model-facing ref; admission is decided by Context Assembly.
    func requestRecall(sessionID: SessionID, referenceID: String) async -> ECoreReference? {
        noteLifecycle(sessionID: sessionID, phase: .recallRequested, referenceID: referenceID)
        guard let ref = await reference(sessionID: sessionID, referenceID: referenceID) else {
            noteLifecycle(sessionID: sessionID, phase: .recallRejected, referenceID: referenceID, reason: "referenceNotFound")
            return nil
        }
        noteLifecycle(sessionID: sessionID, phase: .recallResolved, referenceID: referenceID)
        return ref
    }

    func queueRecallAdmission(sessionID: SessionID, referenceID: String) {
        if !(pendingRecallReferences[sessionID] ?? []).contains(referenceID) {
            pendingRecallReferences[sessionID, default: []].append(referenceID)
        }
    }

    func takeRecallAdmissions(sessionID: SessionID) -> [String] {
        pendingRecallReferences.removeValue(forKey: sessionID) ?? []
    }

    /// Give an existing tool artifact a model-facing reference without copying its
    /// payload or changing its heat/ranking identity. Mapping ownership stays here.
    func referenceForStoredObject(sessionID: SessionID, objectID: ContextObjectID, contextOccurrenceID: String, summary: String, toolCallID: ToolCallID, toolName: String) async -> ECoreReference? {
        noteLifecycle(sessionID: sessionID, phase: .pageOutAttempt)
        guard (try? await fetch(sessionID: sessionID, objectID: objectID)) != nil else { return nil }
        let ref = ECoreReference(objectID: objectID, sessionID: sessionID, origin: .toolCall,
            contextOccurrenceID: contextOccurrenceID, evictionEpoch: 0, summary: summary,
            toolCallID: toolCallID, toolName: toolName, pageOutReason: "boundedToolProjection")
        if let existing = await reference(sessionID: sessionID, referenceID: ref.referenceID) {
            noteLifecycle(sessionID: sessionID, phase: .pageOutDeduplicated, referenceID: ref.referenceID)
            return existing
        }
        if persistsPayloads {
            do {
                try FileManager.default.createDirectory(at: referencesDirectory(sessionID: sessionID), withIntermediateDirectories: true)
                try JSONEncoder().encode(ref).write(to: referenceURL(sessionID: sessionID, referenceID: ref.referenceID), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("[E-CORE WARNING] tool reference write failed: \(error)\n".utf8))
            }
        }
        pageOutReferences[sessionID, default: [:]][ref.referenceID] = ref
        noteLifecycle(sessionID: sessionID, phase: .pageOutNew, referenceID: ref.referenceID)
        notifyMutation()
        return ref
    }

    private func referencesDirectory(sessionID: SessionID) -> URL {
        let safe = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return baseDirectory
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("references", isDirectory: true)
    }

    private func referenceURL(sessionID: SessionID, referenceID: String) -> URL {
        referencesDirectory(sessionID: sessionID)
            .appendingPathComponent("\(referenceID).json", isDirectory: false)
    }

    /// P-Core → E-Core 的唯一 page-out 入口：写 payload（内容寻址，天然去重）→ 登记引用 → 返回引用。
    /// 调用方把返回的 `referenceID` 与 `summary` 留在 P-Core Index 里，不留 payload（契约第一节）。
    ///
    /// `contextOccurrenceID` + `evictionEpoch` 是 occurrence 身份：同一内容第二次被移出（不同 epoch）
    /// 得到新引用，但对象不变；同一次 page-out 重试必须传同一组值以幂等落回同一条引用。
    public func pageOut(
        sessionID: SessionID,
        content: String,
        origin: ECoreObjectOrigin,
        contextOccurrenceID: String,
        evictionEpoch: Int,
        summary: String,
        toolCallID: ToolCallID? = nil,
        toolName: String? = nil,
        createdTurn: Int? = nil,
        pageOutReason: String? = nil
    ) async -> ECoreReference {
        noteLifecycle(sessionID: sessionID, phase: .pageOutAttempt)
        let objectID = ContextObjectID.identify(content: content)
        let reference = ECoreReference(
            objectID: objectID,
            sessionID: sessionID,
            origin: origin,
            contextOccurrenceID: contextOccurrenceID,
            evictionEpoch: evictionEpoch,
            summary: summary,
            toolCallID: toolCallID,
            toolName: toolName,
            createdTurn: createdTurn,
            pageOutReason: pageOutReason
        )

        if let existing = await self.reference(sessionID: sessionID, referenceID: reference.referenceID) {
            noteLifecycle(sessionID: sessionID, phase: .pageOutDeduplicated, referenceID: existing.referenceID)
            return existing
        }

        let bytes = content.utf8.count
        let lines = max(1, content.split(separator: "\n", omittingEmptySubsequences: false).count)
        let record = ECoreObjectRecord(
            objectID: objectID, totalBytes: bytes, totalLines: lines, contentHash: PlatformCrypto.sha256Hex(content)
        )

        // Fail-Open：与既有工具产物路径同一口径，磁盘异常降级为内存态，不打断 Agent Loop。
        if persistsPayloads {
            do {
                let dir = referencesDirectory(sessionID: sessionID)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try JSONEncoder().encode(reference).write(to: referenceURL(sessionID: sessionID, referenceID: reference.referenceID), options: [])
            } catch {
                FileHandle.standardError.write(Data("[E-CORE WARNING] page-out reference write failed: \(error)\n".utf8))
            }
        }

        if pageOutObjects[sessionID]?[objectID] == nil {
            do {
                try writePageOutPayload(sessionID: sessionID, objectID: objectID, content: content)
            } catch {
                FileHandle.standardError.write(Data("[E-CORE WARNING] page-out payload write failed: \(error)\n".utf8))
                memoryPayloads[sessionID, default: [:]][objectID] = content
                censusRegister(sessionID: sessionID, objectID: objectID, bytes: bytes)
            }
        }
        let isFirstWriteOfThisObject = pageOutObjects[sessionID]?[objectID] == nil
        pageOutObjects[sessionID, default: [:]][objectID] = record
        pageOutReferences[sessionID, default: [:]][reference.referenceID] = reference
        noteLifecycle(sessionID: sessionID, phase: .pageOutNew, referenceID: reference.referenceID)
        debugHub?.notePageOut(sessionID: sessionID,
                              objectID: objectID.rawValue,
                              bytes: isFirstWriteOfThisObject ? bytes : 0,
                              referenceID: reference.referenceID,
                              toolName: toolName,
                              reason: pageOutReason)
        notifyMutation()
        return reference
    }

    /// payload 只在同一 session 内按内容去重存放；跨 session 不共享文件，避免越会话可见。
    private func writePageOutPayload(sessionID: SessionID, objectID: ContextObjectID, content: String) throws {
        guard persistsPayloads else {
            memoryPayloads[sessionID, default: [:]][objectID] = content
            censusRegister(sessionID: sessionID, objectID: objectID, bytes: content.utf8.count)
            return
        }
        let url = payloadURL(sessionID: sessionID, objectID: objectID)
        let existed = FileManager.default.fileExists(atPath: url.path)
        if !existed {
            let dir = sessionObjectsDirectory(sessionID: sessionID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: false, encoding: .utf8)
        }
        // 登记放在 guard-else-return 之外：早退时文件已经存在，它同样是一个真实载荷，
        // 而重启后的进程内存里并没有它的记录。登记是幂等的，所以两条路径都安全。
        censusRegister(sessionID: sessionID, objectID: objectID, bytes: content.utf8.count)
    }

    /// Exact Restore 的第一跳：referenceID → 引用。不靠词法或语义检索猜对象是什么（契约第九节）。
    public func reference(sessionID: SessionID, referenceID: String) async -> ECoreReference? {
        guard (try? ContextObjectID(referenceID)) != nil else { return nil }
        if let cached = pageOutReferences[sessionID]?[referenceID] {
            return cached
        }
        guard persistsPayloads else { return nil }
        let url = referenceURL(sessionID: sessionID, referenceID: referenceID)
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(ECoreReference.self, from: data),
              loaded.referenceID == referenceID, loaded.sessionID == sessionID else { return nil }
        pageOutReferences[sessionID, default: [:]][referenceID] = loaded
        return loaded    }

    /// Exact Restore：referenceID → ECoreReference → objectID → 完整不可变 payload。
    public func restore(sessionID: SessionID, referenceID: String) async throws -> String? {
        guard let ref = await reference(sessionID: sessionID, referenceID: referenceID) else {
            // 引用查不到：P-Core Index 里还留着一个已经不存在的引用。
            debugHub?.noteRestoreFailure(sessionID: sessionID, referenceID: referenceID, dangling: true)
            return nil
        }
        let payload = try await fetch(sessionID: sessionID, objectID: ref.objectID)
        if payload == nil {
            // 引用在、对象没了：比上一种更糟，说明载荷本身丢了。
            debugHub?.noteRestoreFailure(sessionID: sessionID, referenceID: referenceID, dangling: false)
        } else {
            debugHub?.noteExactRestore(sessionID: sessionID, referenceID: referenceID)
        }
        return payload
    }

    /// 丢弃引用。只有当该 session 内再无引用指向该 payload 时才回收，
    /// 这是内容去重之后必须付的代价：删对象不能再由单次引用决定。
    public func dropReference(sessionID: SessionID, referenceID: String) async {
        // 走 `reference(...)` 而不是直接查内存表：重启后 `pageOutReferences` 是空的，
        // 原先的 `guard ... else { return }` 会让一次冷启动后的删除静默变成无操作，
        // 载荷于是永不回收——那正是「长期存储是否泄漏」这个问题最想发现的东西。
        guard let ref = await reference(sessionID: sessionID, referenceID: referenceID) else { return }
        pageOutReferences[sessionID]?.removeValue(forKey: referenceID)
        if persistsPayloads {
            try? FileManager.default.removeItem(at: referenceURL(sessionID: sessionID, referenceID: referenceID))
        }
        // 同理，判断「还有没有别的引用」之前必须先把目录里的引用补齐，
        // 否则内存里恰好缺一条会被当成「没人引用了」而误删仍被需要的载荷。
        let allReferences = await references(sessionID: sessionID)
        let stillReferenced = allReferences.contains { $0.objectID == ref.objectID }
        if !stillReferenced {
            censusUnregister(sessionID: sessionID, objectID: ref.objectID)
            pageOutObjects[sessionID]?.removeValue(forKey: ref.objectID)
            memoryPayloads[sessionID]?.removeValue(forKey: ref.objectID)
            if persistsPayloads {
                try? FileManager.default.removeItem(at: payloadURL(sessionID: sessionID, objectID: ref.objectID))
            }
        }
        notifyMutation()
    }

    /// rewind 之后，批次证据这类工具来源的 page-out 引用必须跟着 call 一起消失，
    /// 否则模型会召回一份已经没有对应 Tool Call 的历史证据。非工具来源（Message / page）不属于
    /// 任何 tool call，一律留下，否则 §9 的 Exact Restore 会在一次 rewind 之后静默失效。
    private func dropToolReferences(sessionID: SessionID, keepingToolCallIDs: Set<ToolCallID>) async {
        for ref in await references(sessionID: sessionID) {
            guard ref.origin == .toolCall, let callID = ref.toolCallID else { continue }
            guard !keepingToolCallIDs.contains(callID) else { continue }
            await dropReference(sessionID: sessionID, referenceID: ref.referenceID)
        }
    }

    /// 该 session 的全部引用。重启后内存表是空的，而 P-Core Index 每轮都要从引用重建，
    /// 所以持久化后端必须能按目录补齐 —— 否则冷启动后 Index 会凭空消失。
    public func references(sessionID: SessionID) async -> [ECoreReference] {
        if persistsPayloads {
            let dir = referencesDirectory(sessionID: sessionID)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for url in files where url.lastPathComponent.hasSuffix(".json") {
                    let referenceID = url.deletingPathExtension().lastPathComponent
                    if pageOutReferences[sessionID]?[referenceID] != nil { continue }
                    guard let data = try? Data(contentsOf: url),
                          let loaded = try? JSONDecoder().decode(ECoreReference.self, from: data) else { continue }
                    pageOutReferences[sessionID, default: [:]][referenceID] = loaded
                }
            }
        }
        return Array((pageOutReferences[sessionID] ?? [:]).values.sorted {
            if $0.evictionEpoch != $1.evictionEpoch { return $0.evictionEpoch > $1.evictionEpoch }
            if $0.createdTurn != $1.createdTurn { return ($0.createdTurn ?? 0) > ($1.createdTurn ?? 0) }
            return $0.referenceID < $1.referenceID
        })
    }

    /// 旁路存储对象：超过阈值（或 force）则写入 E-Core 后端。
    /// 注意这里不存在「E-Core 被关闭」的状态 —— `eCorePersistenceEnabled` 只切换持久化后端。
    @discardableResult
    public func store(
        sessionID: SessionID,
        toolCallID: ToolCallID,
        toolName: String,
        content: String,
        contentType: String = "text/plain",
        force: Bool = false
    ) async -> ObservationMetadata? {
        let byteCount = content.utf8.count
        guard force || byteCount >= configuration.objectizationThreshold else {
            return nil
        }

        let objectID = ContextObjectID.generate(toolName: toolName, callID: toolCallID, content: content)

        // 计算行数
        var lineCount = 0
        for byte in content.utf8 {
            if byte == 10 { // '\n'
                lineCount += 1
            }
        }
        if !content.isEmpty && !content.hasSuffix("\n") {
            lineCount += 1
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let contentHash = String(format: "%016llx", hash)

        let metadata = ObservationMetadata(
            objectID: objectID,
            toolCallID: toolCallID,
            toolName: toolName,
            contentType: contentType,
            totalLines: max(1, lineCount),
            totalBytes: byteCount,
            createdAt: .now,
            contentHash: contentHash
        )

        // Fail-Open 写入：后端由持久化开关选择，两种后端都在这个 do 的降级保护之内
        do {
            try writePayload(sessionID: sessionID, objectID: objectID, content: content, metadata: metadata)

            if metadataCache[sessionID] == nil {
                metadataCache[sessionID] = [:]
            }
            metadataCache[sessionID]?[objectID] = metadata
            // 指标不在这里累加。`writePayload` 已经把载荷登记进权威普查，
            // 而这里按「本次写入」增量加一次会把 page-out 那份算漏、把重复 store 算重。

            if configuration.heatTrackingEnabled {
                let event = ECoreAccessEvent(
                    sessionID: sessionID,
                    objectID: objectID,
                    eventType: .objectStored,
                    timestamp: .now,
                    offsetBytes: 0,
                    requestedBytes: byteCount,
                    returnedBytes: byteCount,
                    toolCallID: toolCallID
                )
                let logger = self.telemetryLogger
                Task {
                    await logger.appendEvent(event)
                }

                if heatStates[sessionID] == nil {
                    heatStates[sessionID] = [:]
                }
                let weight = configuration.heatWeightPolicy.weight(for: .objectStored)
                if var existing = heatStates[sessionID]?[objectID] {
                    existing.rawHeatScore = ECoreHeatScorer.accumulate(
                        currentScore: existing.rawHeatScore,
                        lastUpdatedAt: existing.lastAccessedAt,
                        now: .now,
                        eventWeight: weight,
                        halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
                    )
                    existing.accessCount += 1
                    existing.lastAccessedAt = .now
                    heatStates[sessionID]?[objectID] = existing
                } else {
                    let initialHeat = (weight.isFinite && weight >= 0) ? weight : 0.0
                    heatStates[sessionID]?[objectID] = ECoreHeatState(
                        objectID: objectID,
                        accessCount: 1,
                        recallCount: 0,
                        lastAccessedAt: .now,
                        rawHeatScore: initialHeat,
                        percentile: 0.5,
                        robustZScore: 0.0,
                        candidateZone: .cold
                    )
                }
            }

            notifyMutation()
            return metadata
        } catch {
            // Fail-open: 记录警告但不中断
            FileHandle.standardError.write(Data("[E-CORE WARNING] Failed to persist object \(objectID.rawValue): \(error)\n".utf8))
            return nil
        }
    }

    /// 旁路记录对象投影观测事件（Phase 0.6: 纯观测，零阻塞，零热度权重贡献）
    public func recordProjection(
        sessionID: SessionID,
        objectID: ContextObjectID,
        originalBytes: Int,
        turnID: String? = nil,
        revision: Int? = nil
    ) {
        guard configuration.heatTrackingEnabled else { return }

        let meta = metadataCache[sessionID]?[objectID]
        let createdAt = meta?.createdAt ?? .now
        let objectAge = max(0.0, Date.now.timeIntervalSince(createdAt))

        let currentCount = (projectionCounts[sessionID]?[objectID] ?? 0) + 1
        if projectionCounts[sessionID] == nil {
            projectionCounts[sessionID] = [:]
        }
        projectionCounts[sessionID]?[objectID] = currentCount

        let event = ECoreAccessEvent(
            sessionID: sessionID,
            objectID: objectID,
            eventType: .objectProjected,
            timestamp: .now,
            offsetBytes: 0,
            requestedBytes: originalBytes,
            returnedBytes: originalBytes,
            toolCallID: meta?.toolCallID,
            turnID: turnID,
            revision: revision,
            projectionCount: currentCount,
            objectAge: objectAge,
            originalBytes: originalBytes
        )
        let logger = self.telemetryLogger
        Task {
            await logger.appendEvent(event)
        }
        // 注意红线：绝对不增加任何 Heat Weight，不改变 candidateZone
    }

    /// 获取完整对象内容
    public func fetch(sessionID: SessionID, objectID: ContextObjectID) async throws -> String? {
        if let inMemory = memoryPayloads[sessionID]?[objectID] {
            return inMemory
        }
        guard persistsPayloads else { return nil }
        let fileURL = payloadURL(sessionID: sessionID, objectID: objectID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 精确范围召回（context_recall 核心调用）
    public func recall(
        sessionID: SessionID,
        objectID: ContextObjectID,
        offsetBytes: Int = 0,
        limitBytes: Int? = nil,
        limitLines: Int? = nil
    ) async throws -> RecallChunk? {
        guard let content = try await fetch(sessionID: sessionID, objectID: objectID) else {
            if configuration.heatTrackingEnabled {
                let missEvent = ECoreAccessEvent(
                    sessionID: sessionID,
                    objectID: objectID,
                    eventType: .recallMiss,
                    timestamp: .now,
                    offsetBytes: offsetBytes,
                    requestedBytes: limitBytes
                )
                let logger = self.telemetryLogger
                Task {
                    await logger.appendEvent(missEvent)
                }

                let missWeight = configuration.heatWeightPolicy.weight(for: .recallMiss)
                if missWeight > 0, var state = heatStates[sessionID]?[objectID] {
                    state.rawHeatScore = ECoreHeatScorer.accumulate(
                        currentScore: state.rawHeatScore,
                        lastUpdatedAt: state.lastAccessedAt,
                        now: .now,
                        eventWeight: missWeight,
                        halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
                    )
                    state.lastAccessedAt = .now
                    heatStates[sessionID]?[objectID] = state
                }
            }
            return nil
        }

        let maxBytes = min(limitBytes ?? configuration.recallMaxBytes, configuration.recallMaxBytes)
        let maxLines = min(limitLines ?? configuration.recallMaxLines, configuration.recallMaxLines)

        let totalBytes = content.utf8.count
        guard offsetBytes >= 0, offsetBytes < totalBytes else {
            return RecallChunk(
                objectID: objectID,
                offsetBytes: offsetBytes,
                lengthBytes: 0,
                content: "",
                hasMore: false,
                startLine: 1,
                endLine: 1,
                totalLines: 1,
                totalBytes: totalBytes
            )
        }

        let utf8Data = Data(content.utf8)
        let startIdx = offsetBytes
        let endIdx = min(totalBytes, startIdx + maxBytes)
        let sliceData = utf8Data.subdata(in: startIdx..<endIdx)

        let sliceString = String(decoding: sliceData, as: UTF8.self)

        // 截断至指定行数限制
        let lines = sliceString.components(separatedBy: "\n")
        let finalSlice: String
        let actualLinesUsed: Int
        if lines.count > maxLines {
            var sliceWithNewline = lines.prefix(maxLines).joined(separator: "\n")
            if startIdx + sliceWithNewline.utf8.count < totalBytes && utf8Data[startIdx + sliceWithNewline.utf8.count] == 10 {
                sliceWithNewline.append("\n")
            }
            finalSlice = sliceWithNewline
            actualLinesUsed = maxLines
        } else {
            finalSlice = sliceString
            actualLinesUsed = lines.count
        }

        let actualLength = finalSlice.utf8.count
        let hasMore = (startIdx + actualLength) < totalBytes

        // 计算当前 offset 处的行号
        let prefixData = utf8Data.prefix(startIdx)
        var startLine = 1
        for b in prefixData {
            if b == 10 { startLine += 1 }
        }
        let endLine = startLine + max(0, actualLinesUsed - 1)

        var totalLines = 0
        for b in utf8Data {
            if b == 10 { totalLines += 1 }
        }
        if !content.isEmpty && !content.hasSuffix("\n") {
            totalLines += 1
        }

        let chunk = RecallChunk(
            objectID: objectID,
            offsetBytes: startIdx,
            lengthBytes: actualLength,
            content: finalSlice,
            hasMore: hasMore,
            startLine: startLine,
            endLine: endLine,
            totalLines: max(1, totalLines),
            totalBytes: totalBytes
        )

        if configuration.heatTrackingEnabled {
            let recallEvent = ECoreAccessEvent(
                sessionID: sessionID,
                objectID: objectID,
                eventType: .objectRecalled,
                timestamp: .now,
                offsetBytes: startIdx,
                requestedBytes: maxBytes,
                returnedBytes: actualLength
            )
            let logger = self.telemetryLogger
            Task {
                await logger.appendEvent(recallEvent)
            }

            let weight = configuration.heatWeightPolicy.weight(for: .objectRecalled)
            var state = heatStates[sessionID]?[objectID] ?? ECoreHeatState(
                objectID: objectID,
                accessCount: 0,
                recallCount: 0,
                lastAccessedAt: .now,
                rawHeatScore: 0.0,
                percentile: 0.5,
                robustZScore: 0.0,
                candidateZone: .cold
            )
            state.rawHeatScore = ECoreHeatScorer.accumulate(
                currentScore: state.rawHeatScore,
                lastUpdatedAt: state.lastAccessedAt,
                now: .now,
                eventWeight: weight,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
            state.accessCount += 1
            state.recallCount += 1
            state.lastAccessedAt = .now
            if heatStates[sessionID] == nil {
                heatStates[sessionID] = [:]
            }
            heatStates[sessionID]?[objectID] = state
        }

        return chunk
    }

    /// 获取对象元数据
    public func metadata(sessionID: SessionID, objectID: ContextObjectID) async -> ObservationMetadata? {
        if let cached = metadataCache[sessionID]?[objectID] {
            return cached
        }
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        let metaURL = objectsDir.appendingPathComponent("\(objectID.rawValue).meta.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(ObservationMetadata.self, from: data) else {
            return nil
        }
        if metadataCache[sessionID] == nil {
            metadataCache[sessionID] = [:]
        }
        metadataCache[sessionID]?[objectID] = meta
        return meta
    }

    /// 检查对象是否存在
    public func hasObject(sessionID: SessionID, objectID: ContextObjectID) async -> Bool {
        if memoryPayloads[sessionID]?[objectID] != nil { return true }
        guard persistsPayloads else { return false }
        return FileManager.default.fileExists(atPath: payloadURL(sessionID: sessionID, objectID: objectID).path)
    }

    /// 列出指定会话下所有沉淀的 E-Core 观测对象元数据
    public func listObjects(sessionID: SessionID) async -> [ObservationMetadata] {
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: objectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Array(metadataCache[sessionID]?.values ?? [:].values)
        }

        var results: [ObservationMetadata] = []
        for url in fileURLs where url.lastPathComponent.hasSuffix(".meta.json") {
            let baseName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            if let objID = try? ContextObjectID(baseName) {
                if let meta = await metadata(sessionID: sessionID, objectID: objID) {
                    results.append(meta)
                }
            }
        }
        if results.isEmpty, let cached = metadataCache[sessionID] {
            return Array(cached.values)
        }
        return results
    }

    /// 在 E-Core 对象织物中按查询关键词检索匹配的上下文对象
    public func search(
        sessionID: SessionID,
        query: String,
        limit: Int = 5
    ) async -> [ObservationMetadata] {
        guard !query.isEmpty else { return [] }
        let objects = await listObjects(sessionID: sessionID)
        let normalizedQuery = query.lowercased()

        var matches: [(meta: ObservationMetadata, score: Double)] = []

        for meta in objects {
            var score = 0.0
            if meta.toolName.localizedCaseInsensitiveContains(normalizedQuery) {
                score += 5.0
            }
            if meta.objectID.rawValue.localizedCaseInsensitiveContains(normalizedQuery) {
                score += 3.0
            }

            if let content = try? await fetch(sessionID: sessionID, objectID: meta.objectID) {
                if content.localizedCaseInsensitiveContains(normalizedQuery) {
                    score += 10.0
                }
            }

            if score > 0 {
                matches.append((meta, score))
            }
        }

        matches.sort(by: { $0.score > $1.score })
        return Array(matches.prefix(limit).map(\.meta))
    }

    /// 语义召回：query → page-out 引用的 summary（与 P-Core Index 同一份 metadata）。
    /// 命中后由调用方按 referenceID 走 Exact Restore 取载荷，这里不返回 payload。
    public func searchReferences(sessionID: SessionID, query: String, limit: Int, recordTelemetry: Bool = true) async -> [ECoreReference] {
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !terms.isEmpty else { return [] }
        let scored = await references(sessionID: sessionID).compactMap { reference -> (ECoreReference, Int)? in
            let haystack = (reference.summary + " " + (reference.toolName ?? "") + " " + reference.objectID.rawValue).lowercased()
            let hits = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return hits > 0 ? (reference, hits) : nil
        }
        let matched = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.referenceID < rhs.0.referenceID
        }.prefix(max(0, limit)).map(\.0)
        // 只记有命中的那次：一次无命中的语义检索值得看见，但它归 recall-miss 那条线，
        // 不该同时把 semanticRecalls 这个「找回来了多少次」的数往上抬。
        if recordTelemetry && !matched.isEmpty {
            debugHub?.noteSemanticRecall(sessionID: sessionID)
        }
        return matched
    }

    /// 依据保留的 ToolCallIDs 裁剪废弃的观测对象文件与缓存（用于撤回或会话状态协同）
    public func prune(sessionID: SessionID, keepingToolCallIDs: Set<ToolCallID>) async {
        // An empty tool set still permits surviving message/page references.
        await dropToolReferences(sessionID: sessionID, keepingToolCallIDs: keepingToolCallIDs)
        let pageOutObjectIDs = Set(await references(sessionID: sessionID).map(\.objectID))
        // 内存后端没有可枚举的目录，改按元数据缓存裁剪；规则一致：只裁工具产物。
        guard persistsPayloads else {
            for (objID, meta) in (metadataCache[sessionID] ?? [:])
            where meta.isToolArtifact && !keepingToolCallIDs.contains(meta.toolCallID) && !pageOutObjectIDs.contains(objID) {
                removePayload(sessionID: sessionID, objectID: objID)
                metadataCache[sessionID]?.removeValue(forKey: objID)
                heatStates[sessionID]?.removeValue(forKey: objID)
                projectionCounts[sessionID]?.removeValue(forKey: objID)
            }
            notifyMutation()
            return
        }
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: objectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in fileURLs where url.lastPathComponent.hasSuffix(".meta.json") {
            let baseName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard let objID = try? ContextObjectID(baseName),
                  let meta = await metadata(sessionID: sessionID, objectID: objID) else { continue }
            // 只有工具产物随 toolCallID 生死。P-Core page-out 的历史 Message / page 不属于任何
            // tool call，若一并裁剪，§9 要求的 Exact Restore 会在一次 rewind 之后静默失效。
            // 内容寻址让工具产物可能与某条 page-out 引用共享同一个 payload 文件，此时文件必须留下。
            if meta.isToolArtifact,
               !keepingToolCallIDs.contains(meta.toolCallID),
               !pageOutObjectIDs.contains(objID) {
                metadataCache[sessionID]?.removeValue(forKey: objID)
                heatStates[sessionID]?.removeValue(forKey: objID)
                projectionCounts[sessionID]?.removeValue(forKey: objID)
                let txtURL = objectsDir.appendingPathComponent("\(objID.rawValue).txt", isDirectory: false)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: txtURL)
                censusUnregister(sessionID: sessionID, objectID: objID)
            }
        }
        if projectionCounts[sessionID]?.isEmpty == true {
            projectionCounts.removeValue(forKey: sessionID)
        }
        // 不再从 metadataCache 反推 cachedMetrics：那个来源看不见 page-out 载荷，
        // 用它覆盖会把刚登记好的权威普查改回旧口径。普查由 register/unregister 维护。
        notifyMutation()
    }

    /// 重置或清理 session 存储
    public func cleanSession(sessionID: SessionID) async {
        metadataCache.removeValue(forKey: sessionID)
        heatStates.removeValue(forKey: sessionID)
        projectionCounts.removeValue(forKey: sessionID)
        cachedMetrics.removeValue(forKey: sessionID)
        memoryPayloads.removeValue(forKey: sessionID)
        pageOutObjects.removeValue(forKey: sessionID)
        pageOutReferences.removeValue(forKey: sessionID)
        pendingRecallReferences.removeValue(forKey: sessionID)
        lifecycle.removeValue(forKey: sessionID)
        physicalObjects.removeValue(forKey: sessionID)
        censusLoaded.remove(sessionID)
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        try? FileManager.default.removeItem(at: objectsDir)
        try? FileManager.default.removeItem(at: referencesDirectory(sessionID: sessionID))
        notifyMutation()
    }

    /// 会话级外部存储指标（O(1) 内存访问，仅冷启动时扫描一次）。
    ///
    /// 这是**权威物理普查**：覆盖 `store()` 与 `pageOut()` 两条来源的全部载荷，按 objectID
    /// 去重。旧实现从 `listObjects()` 派生，而那条路径只认 `.meta.json`，因此看不见任何
    /// page-out 内容——`ECoreStateSnapshot.objectCount/totalBytes` 于是系统性少算，
    /// 偏偏少算的就是 endurance test 要测的那部分。
    public func storageMetrics(for sessionID: SessionID) async -> SessionStorageMetrics {
        ensureCensusLoaded(sessionID: sessionID)
        return cachedMetrics[sessionID] ?? SessionStorageMetrics()
    }

    /// 获取特定对象的投影计数（供测试与诊断使用）
    public func projectionCount(sessionID: SessionID, objectID: ContextObjectID) -> Int? {
        projectionCounts[sessionID]?[objectID]
    }

    /// 获取特定会话的全部投影计数状态（供测试与诊断使用）
    public func allProjectionCounts(sessionID: SessionID) -> [ContextObjectID: Int]? {
        projectionCounts[sessionID]
    }

    /// 获取当前内存中的热度状态（Derived State，供可观测性与测试使用）
    public func heatState(
        sessionID: SessionID,
        objectID: ContextObjectID,
        now: Date? = nil
    ) -> ECoreHeatState? {
        guard var state = heatStates[sessionID]?[objectID] else { return nil }
        if let now {
            let elapsed = max(0.0, now.timeIntervalSince(state.lastAccessedAt))
            state.rawHeatScore = ECoreHeatScorer.decayedScore(
                currentScore: state.rawHeatScore,
                elapsedSeconds: elapsed,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
        }
        return state
    }

    /// 生成当前会话的 E-Core 热度调试与可观测性快照（Phase 0 惰性统计计算，按需全量计算）
    public func heatSnapshot(
        sessionID: SessionID,
        topN: Int = 10,
        now: Date = .now
    ) async -> ECoreHeatSnapshot? {
        guard configuration.heatTrackingEnabled else { return nil }
        guard var states = heatStates[sessionID], !states.isEmpty else {
            return nil
        }

        // 1. 基于当前时间计算每个对象的有效衰减热度（纯时间流逝衰减，不增加事件权重）
        for (id, var s) in states {
            let elapsed = max(0.0, now.timeIntervalSince(s.lastAccessedAt))
            s.rawHeatScore = ECoreHeatScorer.decayedScore(
                currentScore: s.rawHeatScore,
                elapsedSeconds: elapsed,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
            states[id] = s
        }

        let allScores = states.values.map(\.rawHeatScore).sorted()
        let median = RobustDistributionCalculator.median(allScores)
        let mad = RobustDistributionCalculator.mad(allScores, median: median)

        let p50 = RobustDistributionCalculator.quantile(0.50, sortedValues: allScores)
        let p70 = RobustDistributionCalculator.quantile(0.70, sortedValues: allScores)
        let p80 = RobustDistributionCalculator.quantile(0.80, sortedValues: allScores)
        let p90 = RobustDistributionCalculator.quantile(0.90, sortedValues: allScores)
        let p95 = RobustDistributionCalculator.quantile(0.95, sortedValues: allScores)

        // 2. 为每个对象计算 percentile、robustZScore 和 candidateZone
        // 约定：percentile >= 0.8 为 hot，否则为 cold
        var hotCount = 0
        var coldCount = 0

        for (id, var s) in states {
            let rank = RobustDistributionCalculator.percentileRank(value: s.rawHeatScore, sortedValues: allScores)
            let zScore = RobustDistributionCalculator.robustZScore(value: s.rawHeatScore, median: median, mad: mad)
            s.percentile = rank
            s.robustZScore = zScore
            if rank >= 0.8 {
                s.candidateZone = .hot
                hotCount += 1
            } else {
                s.candidateZone = .cold
                coldCount += 1
            }
            states[id] = s
        }
        // 有意不写回 heatStates：上面两步都只在局部副本上算。写回会让 `rawHeatScore` 就地衰减，
        // 而 `lastAccessedAt` 不变，于是下一次读取会对同一段时间再衰减一遍 —— 观测本身改变被观测量，
        // 长跑越久偏得越多。持久衰减由真正发生过访问的写入路径负责，与只读的 heatState 保持一致。

        // 3. 排序提取 Top-N Hottest
        let sortedByHeat = states.values.sorted {
            if $0.rawHeatScore != $1.rawHeatScore {
                return $0.rawHeatScore > $1.rawHeatScore
            }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }
        let topHottest = Array(sortedByHeat.prefix(max(1, topN)))

        return ECoreHeatSnapshot(
            sessionID: sessionID,
            objectCount: states.count,
            hotCount: hotCount,
            coldCount: coldCount,
            medianHeat: median,
            madHeat: mad,
            p50: p50,
            p70: p70,
            p80: p80,
            p90: p90,
            p95: p95,
            topHottestObjects: topHottest
        )
    }

    /// 导出当前会话的 E-Core 观测期统计指标（完全只读、旁路）
    public func exportObservationMetrics(
        sessionID: SessionID,
        now: Date = .now
    ) async -> ECoreObservationMetrics {
        let events = await telemetryLogger.readEvents(for: sessionID)
        let metas = await listObjects(sessionID: sessionID)
        return ECoreObservationAnalyzer.analyze(
            events: events,
            metadataList: metas,
            now: now,
            halfLifeSeconds: configuration.heatDecayHalfLifeSeconds,
            weightPolicy: configuration.heatWeightPolicy
        )
    }

    /// 导出所有会话全局聚合的 E-Core 观测期统计指标（完全只读、旁路）
    public func exportGlobalObservationMetrics(
        now: Date = .now
    ) async -> ECoreObservationMetrics {
        return ECoreObservationAnalyzer.analyzeDirectory(
            baseDirectory: baseDirectory,
            now: now,
            halfLifeSeconds: configuration.heatDecayHalfLifeSeconds,
            weightPolicy: configuration.heatWeightPolicy
        )
    }
}
