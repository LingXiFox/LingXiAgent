import Foundation
import LingXiProtocol

/// 统一语义检索运行时 (RetrievalRuntime)
/// 负责管理 BM25 Index Snapshot 的异步生命周期、后台低优先级预热、原子无缝替换与只读检索服务
/// 铁律：
/// 1. 绝不阻塞 Agent Loop 或主线程，首次调用若索引在 building 立即返回 warming 状态
/// 2. 后台单次执行 Snapshot 构建，禁止常驻高 CPU 循环 Worker
/// 3. 新 Snapshot 构建成功后执行原子指针替换，若构建失败严格 Fail-Open 保持旧 Snapshot
public actor RetrievalRuntime {
    private(set) public var state: RetrievalRuntimeState = .uninitialized
    private(set) public var activeSnapshot: BM25IndexSnapshot?
    private var buildingTask: Task<Void, Never>?

    private let registry: UnifiedRetrievalRegistry
    private let config: BM25Config
    private let tokenizer: any RetrievalTokenizer

    public private(set) var lastBuildDurationMs: Double = 0.0
    public private(set) var lastBuildError: String? = nil
    public private(set) var totalSnapshotsBuilt: Int = 0

    public init(
        registry: UnifiedRetrievalRegistry,
        config: BM25Config = .standard,
        tokenizer: any RetrievalTokenizer = CodeAwareTokenizer()
    ) {
        self.registry = registry
        self.config = config
        self.tokenizer = tokenizer
    }

    /// 等待后台预热就绪（主要用于测试或显式同步场景）
    public func waitForReady(timeoutMs: Double = 5000) async -> Bool {
        let start = DispatchTime.now()
        while state == .building || state == .uninitialized {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            if elapsed > timeoutMs { return false }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return state == .ready
    }

    /// 触发单次后台异步低优先级预热 (Utility Priority)
    /// - Parameters:
    ///   - projectRoot: 工程根目录
    ///   - sessionID: 会话 ID（用于枚举 E-Core 派生切片）
    ///   - force: 是否强制重新构建
    public func triggerWarmup(
        projectRoot: URL,
        sessionID: SessionID? = nil,
        force: Bool = false
    ) {
        if !force && (state == .building || state == .ready) {
            return
        }

        self.state = .building
        self.lastBuildError = nil

        let currentRegistry = self.registry
        let currentConfig = self.config
        let currentTokenizer = self.tokenizer

        // 启动独立低优先级后台任务，单次构建，杜绝常驻循环消耗资源
        self.buildingTask = Task.detached(priority: .utility) { [weak self] in
            let startTime = DispatchTime.now()
            let chunks = await currentRegistry.enumerateAllChunks(projectRoot: projectRoot, sessionID: sessionID)
            let snapshot = BM25IndexSnapshot(chunks: chunks, config: currentConfig, tokenizer: currentTokenizer)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await self?.applySnapshot(snapshot, durationMs: elapsedMs)
        }
    }

    /// 原子替换为新快照 (Atomic Swap)
    public func applySnapshot(_ snapshot: BM25IndexSnapshot, durationMs: Double = 0.0) {
        self.activeSnapshot = snapshot
        self.state = .ready
        self.lastBuildDurationMs = durationMs
        self.lastBuildError = nil
        self.totalSnapshotsBuilt += 1
        self.buildingTask = nil
    }

    /// 处理构建失败：Fail-Open 保护，有旧快照继续使用旧快照
    public func handleBuildFailure(_ errorMessage: String) {
        self.lastBuildError = errorMessage
        self.buildingTask = nil
        if activeSnapshot != nil {
            // 保留旧 Snapshot 继续对外提供只读查询
            self.state = .ready
        } else {
            self.state = .failed
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
        // 1. 如果已有就绪快照，立即执行并发无锁搜索（零阻塞）
        if let snapshot = activeSnapshot {
            let results = snapshot.search(
                query: query,
                lexicalHints: lexicalHints,
                symbolHints: symbolHints,
                scope: scope,
                limit: limit
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

    /// 显式使当前快照失效
    public func invalidate() {
        self.buildingTask?.cancel()
        self.buildingTask = nil
        self.activeSnapshot = nil
        self.state = .uninitialized
    }
}
