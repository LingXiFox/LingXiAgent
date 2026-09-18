import Foundation
import LingXiProtocol

/// 统一语义检索运行时 (RetrievalRuntime)
/// 负责管理 BM25 Index Snapshot 的异步生命周期、后台低优先级预热、原子无缝替换与只读检索服务
/// 铁律：
/// 1. 绝不阻塞 Agent Loop 或主线程，首次调用若索引在 building 立即返回 warming 状态
/// 2. 后台单次执行 Snapshot 构建，禁止常驻高 CPU 循环 Worker
/// 3. 新 Snapshot 构建成功后执行原子指针替换，若构建失败严格 Fail-Open 保持旧 Snapshot
/// 4. 遵守 Audit #46 & #54：按 WorkspaceRevision / ECoreRevision / IndexRevision 追踪版本与失效，提供原子 Swap
public actor RetrievalRuntime {
    public enum InvalidationSource: String, Sendable, Codable {
        case workspace
        case ecore
        case all
    }

    private(set) public var state: RetrievalRuntimeState = .uninitialized
    private(set) public var activeSnapshot: BM25IndexSnapshot?
    private var buildingTask: Task<Void, Never>?
    public private(set) var isBuilding: Bool = false
    private var queuedBuildRoot: URL?
    private var queuedBuildSessionID: SessionID?
    public private(set) var buildGeneration: UInt64 = 0

    private let registry: UnifiedRetrievalRegistry
    private let config: BM25Config
    private let tokenizer: any RetrievalTokenizer

    // Audit #46: 三维版本感知与生命周期管理
    public private(set) var workspaceRevision: Int = 1
    public private(set) var ecoreRevision: Int = 1
    public private(set) var indexRevision: Int = 0

    public private(set) var lastBuildDurationMs: Double = 0.0
    public private(set) var lastBuildError: String? = nil
    public private(set) var totalSnapshotsBuilt: Int = 0

    private var lastProjectRoot: URL?
    private var lastSessionID: SessionID?

    public var desiredRevision: Int {
        workspaceRevision + ecoreRevision
    }

    public var isStale: Bool {
        indexRevision < desiredRevision
    }

    public var staleness: Int {
        max(0, desiredRevision - indexRevision)
    }

    public init(
        registry: UnifiedRetrievalRegistry,
        config: BM25Config = .standard,
        tokenizer: any RetrievalTokenizer = CodeAwareTokenizer()
    ) {
        self.registry = registry
        self.config = config
        self.tokenizer = tokenizer
    }

    /// 显式使特定语料源失效并递增 Revision，支持可选触发后台平滑重建 (Audit #46)
    public func markDirty(
        source: InvalidationSource = .all,
        projectRoot: URL? = nil,
        sessionID: SessionID? = nil,
        autoRebuild: Bool = true
    ) {
        switch source {
        case .workspace:
            workspaceRevision += 1
        case .ecore:
            ecoreRevision += 1
        case .all:
            workspaceRevision += 1
            ecoreRevision += 1
        }

        if let root = projectRoot ?? lastProjectRoot, autoRebuild {
            triggerWarmup(projectRoot: root, sessionID: sessionID ?? lastSessionID, force: true)
        }
    }

    /// 等待后台预热就绪（主要用于测试或显式同步场景）
    public func waitForReady(timeoutMs: Double = 5000) async -> Bool {
        if state == .ready && !isStale { return true }
        if let task = buildingTask {
            _ = await task.value
            return state == .ready
        }
        let start = DispatchTime.now()
        while state == .building || state == .uninitialized {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            if elapsed > timeoutMs { return false }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        return state == .ready
    }

    /// 触发后台异步预热 (Single-Flight，杜绝 Rebuild Storm)
    public func triggerWarmup(
        projectRoot: URL,
        sessionID: SessionID? = nil,
        force: Bool = false
    ) {
        self.lastProjectRoot = projectRoot
        if let sessionID { self.lastSessionID = sessionID }

        if isBuilding {
            // 已有单飞构建正在执行，仅更新排队构建请求，杜绝并发 Rebuild 堆叠风暴
            self.queuedBuildRoot = projectRoot
            self.queuedBuildSessionID = sessionID
            return
        }

        if !force && (state == .ready && !isStale) {
            return
        }

        startSingleFlightBuild(projectRoot: projectRoot, sessionID: sessionID)
    }

    private func startSingleFlightBuild(projectRoot: URL, sessionID: SessionID?) {
        self.isBuilding = true
        self.state = .building
        self.lastBuildError = nil
        self.buildGeneration &+= 1
        let currentGeneration = self.buildGeneration
        let targetRevision = self.desiredRevision

        let currentRegistry = self.registry
        let currentConfig = self.config
        let currentTokenizer = self.tokenizer

        // 启动唯一后台单飞构建任务
        self.buildingTask = Task(priority: .medium) { [weak self] in
            let startTime = DispatchTime.now()
            let chunks = await currentRegistry.enumerateAllChunks(projectRoot: projectRoot, sessionID: sessionID)
            let snapshot = BM25IndexSnapshot(chunks: chunks, config: currentConfig, tokenizer: currentTokenizer)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await self?.finishSingleFlightBuild(
                snapshot: snapshot,
                generation: currentGeneration,
                durationMs: elapsedMs,
                revision: targetRevision
            )
        }
    }

    private func finishSingleFlightBuild(
        snapshot: BM25IndexSnapshot,
        generation: UInt64,
        durationMs: Double,
        revision: Int
    ) {
        self.isBuilding = false
        self.buildingTask = nil

        guard generation == self.buildGeneration else {
            // 过期构建直接丢弃，杜绝旧快照覆盖新快照
            return
        }

        self.activeSnapshot = snapshot
        self.state = .ready
        self.lastBuildDurationMs = durationMs
        self.lastBuildError = nil
        self.totalSnapshotsBuilt += 1
        self.indexRevision = revision

        // 检查是否有并发变更产生的后续构建需求
        if let nextRoot = self.queuedBuildRoot ?? (self.isStale ? self.lastProjectRoot : nil) {
            let nextSession = self.queuedBuildSessionID ?? self.lastSessionID
            self.queuedBuildRoot = nil
            self.queuedBuildSessionID = nil
            if self.isStale {
                startSingleFlightBuild(projectRoot: nextRoot, sessionID: nextSession)
            }
        }
    }

    /// 原子替换为新快照 (Atomic Swap)
    public func applySnapshot(_ snapshot: BM25IndexSnapshot, durationMs: Double = 0.0, revision: Int? = nil) {
        finishSingleFlightBuild(
            snapshot: snapshot,
            generation: self.buildGeneration,
            durationMs: durationMs,
            revision: revision ?? self.desiredRevision
        )
    }

    /// 处理构建失败：Fail-Open 保护，有旧快照继续使用旧快照
    public func handleBuildFailure(_ errorMessage: String) {
        self.isBuilding = false
        self.lastBuildError = errorMessage
        self.buildingTask = nil
        if activeSnapshot != nil {
            self.state = .ready
        } else {
            self.state = .failed
        }
        // Audit Round 7 Phase D: 失败后若有排队的重建请求，继续启动 queued request
        if let nextRoot = self.queuedBuildRoot ?? (self.isStale ? self.lastProjectRoot : nil) {
            let nextSession = self.queuedBuildSessionID ?? self.lastSessionID
            self.queuedBuildRoot = nil
            self.queuedBuildSessionID = nil
            if self.isStale {
                startSingleFlightBuild(projectRoot: nextRoot, sessionID: nextSession)
            }
        }
    }

    /// 执行只读语义检索
    /// - 若有可用 snapshot，立即毫秒级返回搜索结果（无论后台是否正在预热新 snapshot）
    /// - 若无可用 snapshot 且处于 building 状态，立即返回 warming（耗时 < 1ms，绝不阻塞交互）
    /// - 若未初始化，立即返回 warming 并触发预热
    public func search(
        query: String,
        lexicalHints: [String]? = nil,
        symbolHints: [String]? = nil,
        scope: RetrievalScope = .all,
        limit: Int = 5,
        projectRoot: URL? = nil,
        sessionID: SessionID? = nil
    ) -> RetrievalSearchResult {
        // 1. 如果已有就绪快照，立即执行并发无锁搜索（零阻塞，支持 sessionID 隔离）
        if let snapshot = activeSnapshot {
            let results = snapshot.search(
                query: query,
                lexicalHints: lexicalHints,
                symbolHints: symbolHints,
                scope: scope,
                limit: limit,
                sessionID: sessionID
            )
            return .results(results)
        }

        // 2. 如果无可用快照，检查当前状态
        switch state {
        case .building:
            return .warming(message: "Retrieval index is warming up in background. Please retry shortly or use fallback tools.")
        case .uninitialized:
            if let root = projectRoot {
                triggerWarmup(projectRoot: root, sessionID: sessionID)
            }
            return .warming(message: "Retrieval index warmup started in background. Please retry shortly or use fallback tools.")
        case .failed:
            return .unavailable(reason: lastBuildError ?? "Retrieval index warmup failed.")
        case .ready:
            // 兜底防御
            return .warming(message: "Retrieval index is initializing.")
        }
    }

    /// 预留增量更新接口（为未来增量通知提供统一接入桩）
    public func updateIncremental(chunksToAdd: [RetrievalChunk], chunksToRemove: Set<String>) async {
        // Phase R1.2: 保持架构预留，暂不引入复杂 Watcher
    }

    /// 显式使当前快照失效 (Hard Generation Barrier - Audit Round 7 Phase D)
    public func invalidate() {
        self.buildGeneration &+= 1
        self.isBuilding = false
        self.queuedBuildRoot = nil
        self.queuedBuildSessionID = nil
        self.buildingTask?.cancel()
        self.buildingTask = nil
        self.activeSnapshot = nil
        self.state = .uninitialized
        self.indexRevision = 0
    }

    /// 检索系统内存与快照指标诊断（Audit #54 系统级观测指标）
    public struct MemoryDiagnostics: Sendable, Equatable {
        public let status: String
        public let hasSnapshot: Bool
        public let totalDocuments: Int
        public let vocabularySize: Int
        public let totalPostingsCount: Int
        public let estimatedMemoryBytes: Int
        public let totalSnapshotsBuilt: Int
        public let lastBuildDurationMs: Double
        public let workspaceRevision: Int
        public let ecoreRevision: Int
        public let indexRevision: Int
        public let staleness: Int
        public let isStale: Bool
    }

    /// 获取检索系统内存与快照指标诊断
    public var memoryDiagnostics: MemoryDiagnostics {
        guard let snapshot = activeSnapshot else {
            return MemoryDiagnostics(
                status: state.rawValue,
                hasSnapshot: false,
                totalDocuments: 0,
                vocabularySize: 0,
                totalPostingsCount: 0,
                estimatedMemoryBytes: 0,
                totalSnapshotsBuilt: totalSnapshotsBuilt,
                lastBuildDurationMs: lastBuildDurationMs,
                workspaceRevision: workspaceRevision,
                ecoreRevision: ecoreRevision,
                indexRevision: indexRevision,
                staleness: staleness,
                isStale: isStale
            )
        }
        return MemoryDiagnostics(
            status: state.rawValue,
            hasSnapshot: true,
            totalDocuments: snapshot.totalDocuments,
            vocabularySize: snapshot.vocabularySize,
            totalPostingsCount: snapshot.totalPostingsCount,
            estimatedMemoryBytes: snapshot.estimatedMemoryBytes,
            totalSnapshotsBuilt: totalSnapshotsBuilt,
            lastBuildDurationMs: lastBuildDurationMs,
            workspaceRevision: workspaceRevision,
            ecoreRevision: ecoreRevision,
            indexRevision: indexRevision,
            staleness: staleness,
            isStale: isStale
        )
    }
}
