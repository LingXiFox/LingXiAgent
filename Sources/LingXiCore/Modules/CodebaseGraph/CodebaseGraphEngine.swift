import Foundation
import LingXiPlatform
import LingXiProtocol

/// 代码图谱持久化缓存策略 (GraphCachePolicy)
public enum GraphCachePolicy: Sendable, Equatable {
    case disabled
    case temporary(URL)
    case persistent(URL)

    public var cacheDirectory: URL? {
        switch self {
        case .disabled:
            return nil
        case .temporary(let url), .persistent(let url):
            return url
        }
    }
}

/// 代码图谱持久化缓存硬预算 (GraphCacheBudget)
public struct GraphCacheBudget: Sendable, Equatable {
    public var maxTotalBytes: Int64
    public var maxWorkspaceEntries: Int
    public var maxEntryAgeSeconds: TimeInterval

    public init(
        maxTotalBytes: Int64 = 512 * 1024 * 1024, // 512 MB
        maxWorkspaceEntries: Int = 16,
        maxEntryAgeSeconds: TimeInterval = 14 * 86400 // 14 days
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxWorkspaceEntries = maxWorkspaceEntries
        self.maxEntryAgeSeconds = maxEntryAgeSeconds
    }
}

/// 代码图谱缓存诊断指标 (GraphCacheDiagnostics)
public struct GraphCacheDiagnostics: Sendable, Codable, Equatable {
    public let entryCount: Int
    public let totalBytes: Int64
    public let orphanCount: Int
    public let legacyCount: Int
    public let directoryPath: String

    public init(entryCount: Int, totalBytes: Int64, orphanCount: Int, legacyCount: Int, directoryPath: String) {
        self.entryCount = entryCount
        self.totalBytes = totalBytes
        self.orphanCount = orphanCount
        self.legacyCount = legacyCount
        self.directoryPath = directoryPath
    }
}

/// 代码图谱构建与拓扑分析引擎 (CodebaseGraphEngine)。
/// 负责扫描代码库、提取 AST 结构与依赖边、持久化紧凑缓存并提供调用拓扑与架构分析。
/// Round 2 Phase D:
/// - 符号 ID 区分 Container 与 Signature，彻底消除同名方法节点碰撞与覆盖；
/// - 紧凑 EdgeKey 替代 Set<String>，消除边去重堆内存放大；
/// - 增量索引检测并级联删除磁盘上已移除的文件；
/// - 持久化 Caller Invocation Summary，增量构建时完整保留与自愈跨文件调用边；
/// - 语法解析器剥离字符串与注释后统计 Brace 深度，嵌套调用仅归属最内层 Scope，支持单行函数体调用扫描。
public actor CodebaseGraphEngine {
    public static var shared: CodebaseGraphEngine = CodebaseGraphEngine()

    public static func configureShared(cachePolicy: GraphCachePolicy, cacheBudget: GraphCacheBudget = GraphCacheBudget()) {
        shared = CodebaseGraphEngine(cachePolicy: cachePolicy, cacheBudget: cacheBudget)
    }

    // MARK: - Compact Edge Key (Zero String Heap Allocation)
    public struct EdgeKey: Hashable, Sendable {
        public let source: NodeIndex
        public let target: NodeIndex
        public let kind: GraphEdgeKind
        public let line: Int32

        public init(source: NodeIndex, target: NodeIndex, kind: GraphEdgeKind, line: Int32) {
            self.source = source
            self.target = target
            self.kind = kind
            self.line = line
        }
    }

    // MARK: - Compact Storage Pools
    private var nodePool: [GraphNode] = []
    private var nodeIndexByID: [String: NodeIndex] = [:]
    private var nodesByName: [String: [NodeIndex]] = [:]

    private var edgePool: [CompactGraphEdge] = []
    private var edgeDeduplicationSet: Set<EdgeKey> = []

    private var outgoingEdgeIndices: [NodeIndex: [EdgeIndex]] = [:]
    private var incomingEdgeIndices: [NodeIndex: [EdgeIndex]] = [:]

    private var fileModificationTimes: [String: Date] = [:]

    // MARK: - Caller Invocation Summaries (Persistent per-file call intents)
    public struct CallerInvocationSummary: Codable, Sendable {
        public let callerNodeID: String
        public let callerLine: Int32
        public let filePath: String
        public let invokedNames: Set<String>

        public init(callerNodeID: String, callerLine: Int32, filePath: String, invokedNames: Set<String>) {
            self.callerNodeID = callerNodeID
            self.callerLine = callerLine
            self.filePath = filePath
            self.invokedNames = invokedNames
        }
    }

    private var fileInvocationSummaries: [String: [CallerInvocationSummary]] = [:]

    private var workspaceRootURL: URL?
    private var isIndexing: Bool = false
    private var isInitialized: Bool = false
    private var currentRevision: UInt64 = 0

    public let cachePolicy: GraphCachePolicy
    public let cacheBudget: GraphCacheBudget

    public init(
        cachePolicy: GraphCachePolicy = .persistent(CoreStorageLayout.current.graphCache),
        cacheBudget: GraphCacheBudget = GraphCacheBudget()
    ) {
        self.cachePolicy = cachePolicy
        self.cacheBudget = cacheBudget
    }

    public var isIndexingInProgress: Bool {
        isIndexing
    }

    public var isIndexed: Bool {
        isInitialized
    }

    public var nodeCount: Int {
        nodePool.count
    }

    public var edgeCount: Int {
        edgePool.count
    }

    public var fileCount: Int {
        fileModificationTimes.count
    }

    public struct GraphMemoryDiagnostics: Sendable, Equatable {
        public let nodeCount: Int
        public let edgeCount: Int
        public let outgoingEdgeReferenceCount: Int
        public let incomingEdgeReferenceCount: Int
        public let structuralLowerBoundBytes: Int

        // 兼容旧字段
        public var approximateHeapBytes: Int { structuralLowerBoundBytes }

        public init(
            nodeCount: Int,
            edgeCount: Int,
            outgoingEdgeReferenceCount: Int,
            incomingEdgeReferenceCount: Int,
            structuralLowerBoundBytes: Int
        ) {
            self.nodeCount = nodeCount
            self.edgeCount = edgeCount
            self.outgoingEdgeReferenceCount = outgoingEdgeReferenceCount
            self.incomingEdgeReferenceCount = incomingEdgeReferenceCount
            self.structuralLowerBoundBytes = structuralLowerBoundBytes
        }
    }

    public func memoryDiagnostics() -> GraphMemoryDiagnostics {
        let outCount = outgoingEdgeIndices.values.reduce(0) { $0 + $1.count }
        let inCount = incomingEdgeIndices.values.reduce(0) { $0 + $1.count }
        let nodeBytes = nodePool.count * 128
        let edgeBytes = edgePool.count * MemoryLayout<CompactGraphEdge>.stride + (outCount + inCount) * 4
        let edgeKeyBytes = edgeDeduplicationSet.count * MemoryLayout<EdgeKey>.stride
        return GraphMemoryDiagnostics(
            nodeCount: nodePool.count,
            edgeCount: edgePool.count,
            outgoingEdgeReferenceCount: outCount,
            incomingEdgeReferenceCount: inCount,
            structuralLowerBoundBytes: nodeBytes + edgeBytes + edgeKeyBytes
        )
    }

    public func clearGraphMemory() {
        nodePool.removeAll(keepingCapacity: false)
        nodeIndexByID.removeAll(keepingCapacity: false)
        nodesByName.removeAll(keepingCapacity: false)
        edgePool.removeAll(keepingCapacity: false)
        edgeDeduplicationSet.removeAll(keepingCapacity: false)
        outgoingEdgeIndices.removeAll(keepingCapacity: false)
        incomingEdgeIndices.removeAll(keepingCapacity: false)
        fileModificationTimes.removeAll(keepingCapacity: false)
        fileInvocationSummaries.removeAll(keepingCapacity: false)
        workspaceRootURL = nil
        isInitialized = false
    }

    // MARK: - Workspace Indexing

    public func indexWorkspace(workspaceURL: URL, forceReindex: Bool = false, revision: UInt64 = 0) async -> ArchitectureOverview {
        if revision > 0 {
            guard revision >= currentRevision else {
                return getArchitecture()
            }
            currentRevision = revision
        }

        isIndexing = true
        defer {
            isIndexing = false
            if !Task.isCancelled {
                isInitialized = true
            }
        }

        // Workspace 变更时强制清空旧工作区图谱，防止内存污染与泄漏
        if let current = self.workspaceRootURL, current.standardizedFileURL.path != workspaceURL.standardizedFileURL.path {
            clearGraphMemory()
        }
        self.workspaceRootURL = workspaceURL

        if forceReindex {
            clearGraphMemory()
            self.workspaceRootURL = workspaceURL
        }

        // 尝试从持久化缓存载入 V3
        if nodePool.isEmpty && !forceReindex {
            loadFromDiskCache(for: workspaceURL)
        }

        if Task.isCancelled { return getArchitecture() }

        let fileURLs = discoverSourceFiles(in: workspaceURL)
        let currentRelPaths = Set(fileURLs.map { relativePath(for: $0, root: workspaceURL) })

        // 1. 删除检测：从 Graph 中彻底级联移除在磁盘上已删除的文件
        let deletedRelPaths = Set(fileModificationTimes.keys).subtracting(currentRelPaths)
        for deletedPath in deletedRelPaths {
            removeFileEntities(byRelPath: deletedPath)
            fileModificationTimes.removeValue(forKey: deletedPath)
            fileInvocationSummaries.removeValue(forKey: deletedPath)
        }

        if Task.isCancelled { return getArchitecture() }

        // 2. 变更检测：筛选新增或被修改的文件
        var changedFiles: [URL] = []
        for file in fileURLs {
            let relPath = relativePath(for: file, root: workspaceURL)
            let currentMtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if let recordedMtime = fileModificationTimes[relPath], recordedMtime == currentMtime && !forceReindex {
                continue
            }
            changedFiles.append(file)
            fileModificationTimes[relPath] = currentMtime
        }

        // 3. 仅对变更或新增文件重新解析其节点与结构边
        for file in changedFiles {
            if Task.isCancelled { return getArchitecture() }
            let rel = relativePath(for: file, root: workspaceURL)
            removeFileEntities(byRelPath: rel)
            parseFile(file, root: workspaceURL)
        }

        if Task.isCancelled { return getArchitecture() }

        // 4. 重新构建跨文件精准调用边 (基于持久化的 fileInvocationSummaries 全量调用网拓扑重建)
        resolveCrossFileCallEdges()

        // 5. 持久化到本地磁盘缓存 V3
        saveToDiskCache(for: workspaceURL)

        return getArchitecture()
    }

    /// 获取整体架构分层概览与核心热点
    public func getArchitecture() -> ArchitectureOverview {
        let projectName = workspaceRootURL?.lastPathComponent ?? "Workspace"
        let totalNodes = nodePool.count
        let totalEdges = edgePool.count
        let totalFiles = Set(nodePool.compactMap { $0.path.isEmpty ? nil : $0.path }).count

        // 1. 分层识别 (api, core, infra, test)
        var layerMap: [String: (desc: String, files: Set<String>, nodes: Int)] = [
            "api": ("HTTP / CLI / TUI / Protocol 交互接入层", [], 0),
            "core": ("核心业务逻辑 / 状态规约 / Agent 执行引擎", [], 0),
            "infra": ("平台系统抽象 / 存储 / 进程 / 基础设施", [], 0),
            "test": ("测试套件 / 验证用例", [], 0)
        ]

        for node in nodePool {
            let p = node.path.lowercased()
            let layerKey: String
            if p.contains("test") {
                layerKey = "test"
            } else if p.contains("platform") || p.contains("storage") || p.contains("cache") || p.contains("system") {
                layerKey = "infra"
            } else if p.contains("tui") || p.contains("cli") || p.contains("protocol") || p.contains("api") || p.contains("route") {
                layerKey = "api"
            } else {
                layerKey = "core"
            }

            var entry = layerMap[layerKey]!
            entry.files.insert(node.path)
            entry.nodes += 1
            layerMap[layerKey] = entry
        }

        let layers = layerMap.map { k, v in
            ArchitectureLayer(name: k, description: v.desc, fileCount: v.files.count, nodeCount: v.nodes)
        }.sorted { $0.nodeCount > $1.nodeCount }

        // 2. 核心热点计算 (Top Fan-in 扇入枢纽节点)
        var fanInMap: [NodeIndex: Int] = [:]
        var fanOutMap: [NodeIndex: Int] = [:]
        for edge in edgePool where edge.kind == .calls || edge.kind == .implements || edge.kind == .inherits {
            fanInMap[edge.target, default: 0] += 1
            fanOutMap[edge.source, default: 0] += 1
        }

        var hotspots: [GraphHotspot] = []
        for (idx, node) in nodePool.enumerated() {
            let nodeIdx = NodeIndex(idx)
            let kind = node.kind
            if kind == .function || kind == .method || kind == .class || kind == .struct || kind == .interface {
                let fanIn = fanInMap[nodeIdx, default: 0]
                let fanOut = fanOutMap[nodeIdx, default: 0]
                if fanIn > 0 {
                    hotspots.append(GraphHotspot(node: node, fanIn: fanIn, fanOut: fanOut))
                }
            }
        }
        hotspots.sort { $0.fanIn > $1.fanIn }
        let topHotspots = Array(hotspots.prefix(15))

        // 3. 模块级依赖拓扑
        var moduleNodes: [String: Set<NodeIndex>] = [:]
        for (idx, node) in nodePool.enumerated() {
            let mod = extractModuleName(from: node.path)
            moduleNodes[mod, default: []].insert(NodeIndex(idx))
        }

        var modules: [ModuleOverview] = []
        for (modName, nodeIndices) in moduleNodes {
            var outboundDeps: Set<String> = []
            for nodeIdx in nodeIndices {
                if let outEdgeIndices = outgoingEdgeIndices[nodeIdx] {
                    for edgeIdx in outEdgeIndices {
                        let edge = edgePool[Int(edgeIdx)]
                        if edge.kind == .calls || edge.kind == .imports {
                            let targetNode = nodePool[Int(edge.target)]
                            let targetMod = extractModuleName(from: targetNode.path)
                            if targetMod != modName {
                                outboundDeps.insert(targetMod)
                            }
                        }
                    }
                }
            }
            modules.append(ModuleOverview(name: modName, nodeCount: nodeIndices.count, outboundDependencies: Array(outboundDeps).sorted()))
        }
        modules.sort { $0.nodeCount > $1.nodeCount }

        return ArchitectureOverview(
            projectName: projectName,
            totalNodes: totalNodes,
            totalEdges: totalEdges,
            totalFiles: totalFiles,
            layers: layers,
            hotspots: topHotspots,
            modules: modules
        )
    }

    /// 拓扑调用链追踪 (trace_path)
    public func traceCallPath(symbolNameOrId: String, direction: TraceDirection, maxDepth: Int = 3) -> CallTraceReport? {
        guard let rootNodeIdx = findNodeIndex(by: symbolNameOrId) else { return nil }
        let rootNode = nodePool[Int(rootNodeIdx)]

        var steps: [TraceStep] = []
        var visited: Set<NodeIndex> = [rootNodeIdx]
        var queue: [(idx: NodeIndex, depth: Int)] = [(rootNodeIdx, 0)]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.depth >= maxDepth { continue }

            let edgeIndices: [EdgeIndex]
            switch direction {
            case .outbound:
                edgeIndices = outgoingEdgeIndices[current.idx] ?? []
            case .inbound:
                edgeIndices = incomingEdgeIndices[current.idx] ?? []
            }

            for eIdx in edgeIndices {
                let edge = edgePool[Int(eIdx)]
                let nextIdx = (direction == .inbound) ? edge.source : edge.target
                let fromNode = nodePool[Int(edge.source)]
                let toNode = nodePool[Int(edge.target)]

                steps.append(TraceStep(
                    depth: current.depth + 1,
                    from: fromNode,
                    to: toNode,
                    line: edge.line > 0 ? Int(edge.line) : nil,
                    kind: edge.kind
                ))

                if !visited.contains(nextIdx) {
                    visited.insert(nextIdx)
                    queue.append((nextIdx, current.depth + 1))
                }
            }
        }

        return CallTraceReport(
            root: rootNode,
            direction: direction,
            totalDepth: steps.map { _ in maxDepth }.first ?? 0,
            steps: steps
        )
    }

    /// 搜索代码图谱实体 (search_graph)
    public func search(query: String, kind: GraphNodeKind? = nil, limit: Int = 20) -> [GraphNode] {
        let q = query.lowercased()
        var results: [GraphNode] = []

        for node in nodePool {
            if let targetKind = kind, node.kind != targetKind { continue }
            if node.name.lowercased().contains(q) || node.qualifiedName.lowercased().contains(q) || node.id.lowercased().contains(q) {
                results.append(node)
                if results.count >= limit { break }
            }
        }
        return results
    }


    private func findNodeIndex(by query: String) -> NodeIndex? {
        if let idx = nodeIndexByID[query] { return idx }
        if let indices = nodesByName[query], let first = indices.first { return first }
        if let match = search(query: query, limit: 1).first, let idx = nodeIndexByID[match.id] {
            return idx
        }
        return nil
    }

    // MARK: - Node & Edge Removal (Cascade Incremental Purge)

    private func removeFileEntities(for fileURL: URL, root: URL) {
        let relPath = relativePath(for: fileURL, root: root)
        removeFileEntities(byRelPath: relPath)
    }

    private func removeFileEntities(byRelPath relPath: String) {
        let removedIndices = Set(nodePool.indices.compactMap { idx -> NodeIndex? in
            (nodePool[idx].path == relPath) ? NodeIndex(idx) : nil
        })
        guard !removedIndices.isEmpty else {
            fileInvocationSummaries.removeValue(forKey: relPath)
            return
        }

        // 重新压缩构建 NodePool，保持索引紧凑且无悬垂边
        var newNodePool: [GraphNode] = []
        var oldToNewNodeMap: [NodeIndex: NodeIndex] = [:]
        for (idx, node) in nodePool.enumerated() {
            let oldIdx = NodeIndex(idx)
            if !removedIndices.contains(oldIdx) {
                let newIdx = NodeIndex(newNodePool.count)
                newNodePool.append(node)
                oldToNewNodeMap[oldIdx] = newIdx
            }
        }

        // 重建 nodeIndexByID 与 nodesByName
        var newNodeIndexByID: [String: NodeIndex] = [:]
        var newNodesByName: [String: [NodeIndex]] = [:]
        for (idx, node) in newNodePool.enumerated() {
            let nIdx = NodeIndex(idx)
            newNodeIndexByID[node.id] = nIdx
            newNodesByName[node.name, default: []].append(nIdx)
        }

        // 过滤有效边，映射其 source 与 target 到新的 NodeIndex
        var newEdgePool: [CompactGraphEdge] = []
        var newEdgeDeduplicationSet: Set<EdgeKey> = []
        var newOutgoing: [NodeIndex: [EdgeIndex]] = [:]
        var newIncoming: [NodeIndex: [EdgeIndex]] = [:]

        for edge in edgePool {
            guard let newSource = oldToNewNodeMap[edge.source],
                  let newTarget = oldToNewNodeMap[edge.target] else {
                continue // 属于被删除实体的边被彻底清除
            }
            let key = EdgeKey(source: newSource, target: newTarget, kind: edge.kind, line: edge.line)
            guard !newEdgeDeduplicationSet.contains(key) else { continue }
            newEdgeDeduplicationSet.insert(key)

            let edgeIdx = EdgeIndex(newEdgePool.count)
            let compactEdge = CompactGraphEdge(
                source: newSource,
                target: newTarget,
                kind: edge.kind,
                line: edge.line,
                confidence: edge.confidence
            )
            newEdgePool.append(compactEdge)
            newOutgoing[newSource, default: []].append(edgeIdx)
            newIncoming[newTarget, default: []].append(edgeIdx)
        }

        self.nodePool = newNodePool
        self.nodeIndexByID = newNodeIndexByID
        self.nodesByName = newNodesByName
        self.edgePool = newEdgePool
        self.edgeDeduplicationSet = newEdgeDeduplicationSet
        self.outgoingEdgeIndices = newOutgoing
        self.incomingEdgeIndices = newIncoming
        self.fileInvocationSummaries.removeValue(forKey: relPath)
    }

    private struct FunctionSpan: Sendable {
        let nodeID: String
        let name: String
        let filePath: String
        let startLine: Int
        var endLine: Int
        var invokedNames: Set<String>
    }

    private struct ActiveScope {
        let spanIndex: Int
        let braceDepth: Int
    }

    // MARK: - File Parsing & AST Extraction

    private func parseFile(_ fileURL: URL, root: URL) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let relPath = relativePath(for: fileURL, root: root)
        let ext = fileURL.pathExtension.lowercased()
        let isTestFile = relPath.contains("Test") || relPath.contains(".test.") || relPath.contains("_test.")

        let fileNodeId = "file:\(relPath)"
        let fileLines = content.components(separatedBy: "\n")
        let fileNode = GraphNode(
            id: fileNodeId,
            kind: .file,
            name: fileURL.lastPathComponent,
            qualifiedName: relPath,
            path: relPath,
            startLine: 1,
            endLine: fileLines.count,
            isExported: true,
            isTest: isTestFile
        )
        let fileNodeIdx = addNode(fileNode)

        var containerStack: [(id: String, idx: NodeIndex, name: String, depth: Int)] = []
        var activeScopes: [ActiveScope] = []
        var spans: [FunctionSpan] = []
        var currentBraceDepth = 0

        for (idx, rawLine) in fileLines.enumerated() {
            let lineNum = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 剥离注释与字符串后再统计大括号，杜绝字符字面量或注释中的大括号错乱 scope 深度
            let strippedLine = stripCommentsAndStrings(rawLine)
            let openBraces = strippedLine.filter { $0 == "{" }.count
            let closeBraces = strippedLine.filter { $0 == "}" }.count

            // 1. Imports
            if line.hasPrefix("import ") {
                let mod = line.replacingOccurrences(of: "import ", with: "")
                    .replacingOccurrences(of: ";", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let modId = "module:\(mod)"
                let modNode = GraphNode(id: modId, kind: .module, name: mod, qualifiedName: mod, path: "")
                let modIdx = addNode(modNode)
                addCompactEdge(CompactGraphEdge(source: fileNodeIdx, target: modIdx, kind: .imports, line: Int32(lineNum)))
                currentBraceDepth += (openBraces - closeBraces)
                closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
                continue
            }

            // 2. Class / Struct / Interface / Protocol / Enum / Actor
            if let decl = matchTypeDeclaration(line: line, ext: ext) {
                let containerPath: String
                if !containerStack.isEmpty {
                    containerPath = containerStack.map(\.name).joined(separator: ".") + "." + decl.name
                } else {
                    containerPath = decl.name
                }
                let entityId = "\(decl.kind.rawValue):\(relPath):\(containerPath)"
                let node = GraphNode(
                    id: entityId,
                    kind: decl.kind,
                    name: decl.name,
                    qualifiedName: "\(relPath).\(containerPath)",
                    path: relPath,
                    startLine: lineNum,
                    isExported: !line.contains("private"),
                    isTest: isTestFile
                )
                let entityIdx = addNode(node)
                let parentIdx = containerStack.last?.idx ?? fileNodeIdx
                addCompactEdge(CompactGraphEdge(source: parentIdx, target: entityIdx, kind: .defines, line: Int32(lineNum)))

                if let inherit = decl.inherits {
                    for base in inherit.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        let baseId = "type:\(base)"
                        let baseNode = GraphNode(id: baseId, kind: .interface, name: String(base), qualifiedName: String(base), path: "")
                        let baseIdx = addNode(baseNode)
                        addCompactEdge(CompactGraphEdge(source: entityIdx, target: baseIdx, kind: .inherits, line: Int32(lineNum)))
                    }
                }
                currentBraceDepth += (openBraces - closeBraces)
                containerStack.append((id: entityId, idx: entityIdx, name: decl.name, depth: currentBraceDepth))
                closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
                continue
            }

            // 3. Function / Method Declaration
            if let (funcName, signature) = matchFunctionDeclaration(line: line, ext: ext) {
                let isMethod = !containerStack.isEmpty
                let containerPath = containerStack.map(\.name).joined(separator: ".")
                let entityId: String
                let qualifiedName: String
                if isMethod {
                    entityId = "method:\(relPath):\(containerPath):\(funcName):\(signature):\(lineNum)"
                    qualifiedName = "\(relPath).\(containerPath).\(funcName)"
                } else {
                    entityId = "function:\(relPath):\(funcName):\(signature):\(lineNum)"
                    qualifiedName = "\(relPath).\(funcName)"
                }
                let node = GraphNode(
                    id: entityId,
                    kind: isMethod ? .method : .function,
                    name: funcName,
                    qualifiedName: qualifiedName,
                    path: relPath,
                    startLine: lineNum,
                    isExported: !line.contains("private"),
                    isTest: isTestFile || funcName.lowercased().hasPrefix("test")
                )
                let funcIdx = addNode(node)
                let parentIdx = containerStack.last?.idx ?? fileNodeIdx
                addCompactEdge(CompactGraphEdge(source: parentIdx, target: funcIdx, kind: .defines, line: Int32(lineNum)))

                currentBraceDepth += (openBraces - closeBraces)
                let spanIdx = spans.count
                var funcSpan = FunctionSpan(
                    nodeID: entityId,
                    name: funcName,
                    filePath: relPath,
                    startLine: lineNum,
                    endLine: lineNum,
                    invokedNames: []
                )

                // 修复单行函数（func a() { b() }）：扫描同一行大括号之后的代码行内调用
                if let openBraceIdx = line.firstIndex(of: "{") {
                    let afterBrace = String(line[line.index(after: openBraceIdx)...])
                    if !afterBrace.isEmpty {
                        let sameLineCalls = extractInvocations(from: afterBrace)
                        for call in sameLineCalls where call != funcName {
                            funcSpan.invokedNames.insert(call)
                        }
                    }
                }

                spans.append(funcSpan)
                activeScopes.append(ActiveScope(spanIndex: spanIdx, braceDepth: currentBraceDepth))
                closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
                continue
            }

            // 4. Caller-local Invocation Scanner
            // 修复嵌套作用域调用混淆：调用仅记录到最内层活跃 Scope，绝不污染外层 Scope
            if let innermostScope = activeScopes.last {
                let calls = extractInvocations(from: line)
                for call in calls {
                    spans[innermostScope.spanIndex].invokedNames.insert(call)
                }
            }

            currentBraceDepth += (openBraces - closeBraces)
            closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
        }

        // 闭合可能遗留的未闭合 scope
        for scope in activeScopes {
            spans[scope.spanIndex].endLine = fileLines.count
        }

        // 持久化该文件的调用摘要 (CallerInvocationSummary)
        var summaries: [CallerInvocationSummary] = []
        for span in spans {
            summaries.append(CallerInvocationSummary(
                callerNodeID: span.nodeID,
                callerLine: Int32(span.startLine),
                filePath: relPath,
                invokedNames: span.invokedNames
            ))
        }
        fileInvocationSummaries[relPath] = summaries
    }

    private func closeScopesIfNeeded(
        currentDepth: Int,
        lineNum: Int,
        activeScopes: inout [ActiveScope],
        spans: inout [FunctionSpan],
        containerStack: inout [(id: String, idx: NodeIndex, name: String, depth: Int)]
    ) {
        while let lastScope = activeScopes.last, currentDepth < lastScope.braceDepth {
            spans[lastScope.spanIndex].endLine = lineNum
            activeScopes.removeLast()
        }
        while let lastContainer = containerStack.last, currentDepth < lastContainer.depth {
            containerStack.removeLast()
        }
    }

    private func stripCommentsAndStrings(_ raw: String) -> String {
        var result = ""
        var inString = false
        var prev: Character? = nil
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                // 单行注释结束整行
                break
            }
            if c == "\"" && prev != "\\" {
                inString.toggle()
                result.append(" ")
            } else if inString {
                result.append(" ")
            } else {
                result.append(c)
            }
            prev = c
            i += 1
        }
        return result
    }

    private func extractInvocations(from line: String) -> [String] {
        var text = line
        if let commentRange = text.range(of: "//") {
            text = String(text[..<commentRange.lowerBound])
        }
        guard !text.isEmpty else { return [] }

        var results: [String] = []
        let characters = Array(text)
        var i = 0
        let n = characters.count

        while i < n {
            if characters[i] == "\"" {
                i += 1
                while i < n && characters[i] != "\"" {
                    if characters[i] == "\\" && i + 1 < n {
                        i += 2
                    } else {
                        i += 1
                    }
                }
                if i < n { i += 1 }
                continue
            }

            if characters[i].isLetter || characters[i] == "_" {
                let start = i
                while i < n && (characters[i].isLetter || characters[i].isNumber || characters[i] == "_") {
                    i += 1
                }
                let ident = String(characters[start..<i])

                var j = i
                while j < n && (characters[j] == " " || characters[j] == "\t") {
                    j += 1
                }
                if j < n && characters[j] == "(" {
                    if !isControlFlowOrTypeKeyword(ident) {
                        results.append(ident)
                    }
                }
                continue
            }
            i += 1
        }
        return results
    }

    private func isControlFlowOrTypeKeyword(_ word: String) -> Bool {
        switch word {
        case "if", "guard", "switch", "case", "for", "while", "repeat", "do", "catch",
             "func", "def", "fn", "function", "class", "struct", "enum", "protocol", "interface",
             "init", "subscript", "return", "throw", "throws", "rethrows", "async", "await",
             "import", "var", "let", "private", "public", "internal", "fileprivate", "open",
             "static", "final", "mutating", "nonmutating", "override", "where", "as", "is",
             "try", "nil", "null", "true", "false", "self", "Self", "super":
            return true
        default:
            return false
        }
    }

    private struct TypeDeclMatch {
        let kind: GraphNodeKind
        let name: String
        let inherits: String?
    }

    private func matchTypeDeclaration(line: String, ext: String) -> TypeDeclMatch? {
        let keywords = ["class ", "struct ", "enum ", "actor ", "protocol ", "interface "]
        for kw in keywords {
            if let range = line.range(of: kw) {
                let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let parts = after.components(separatedBy: CharacterSet(charactersIn: " :{<"))
                guard let name = parts.first, !name.isEmpty, !name.hasPrefix("//") else { continue }

                let kind: GraphNodeKind
                switch kw {
                case "class ": kind = .class
                case "struct ", "enum ", "actor ": kind = .struct
                case "protocol ", "interface ": kind = .interface
                default: kind = .class
                }

                var inherits: String? = nil
                if let colonRange = after.range(of: ":") {
                    let inheritanceStr = String(after[colonRange.upperBound...]).components(separatedBy: "{").first
                    inherits = inheritanceStr?.trimmingCharacters(in: .whitespaces)
                }

                return TypeDeclMatch(kind: kind, name: name, inherits: inherits)
            }
        }
        return nil
    }

    private func matchFunctionDeclaration(line: String, ext: String) -> (name: String, signature: String)? {
        let prefixes = ["func ", "def ", "fn ", "function "]
        for p in prefixes {
            if let range = line.range(of: p) {
                let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let parenOpen = after.firstIndex(of: "(") {
                    let name = String(after[..<parenOpen]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !name.contains(" ") && !name.hasPrefix("//") {
                        let remaining = after[parenOpen...]
                        let signature: String
                        if let parenClose = remaining.firstIndex(of: ")") {
                            let paramsContent = remaining[remaining.index(after: parenOpen)..<parenClose]
                            signature = formatParameterSignature(name: name, params: String(paramsContent))
                        } else {
                            signature = "\(name)()"
                        }
                        return (name: name, signature: signature)
                    }
                }
            }
        }
        return nil
    }

    private func formatParameterSignature(name: String, params: String) -> String {
        let trimmed = params.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "\(name)()" }
        let parts = trimmed.split(separator: ",")
        var labels: [String] = []
        for part in parts {
            let pTrimmed = part.trimmingCharacters(in: .whitespaces)
            let tokens = pTrimmed.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
            if let firstToken = tokens.first {
                labels.append(String(firstToken))
            }
        }
        if labels.isEmpty {
            return "\(name)()"
        }
        return "\(name)(\(labels.map { "\($0):" }.joined()))"
    }

    // MARK: - Cross-File Call Graph Reconstruction (Full Resolution from Invocations)

    /// 基于全量持久化的 Caller Invocation Summaries 精确重建跨文件调用边，
    /// 确保在增量构建、Callee 修改或删除时，未修改 Caller 的调用边绝不丢失！
    private func resolveCrossFileCallEdges() {
        // 1. 从图谱中清空所有现有的 .calls 边（保留 .defines, .imports, .inherits 等结构边）
        var nonCallEdges: [CompactGraphEdge] = []
        var newEdgeDeduplicationSet: Set<EdgeKey> = []
        var newOutgoing: [NodeIndex: [EdgeIndex]] = [:]
        var newIncoming: [NodeIndex: [EdgeIndex]] = [:]

        for edge in edgePool where edge.kind != .calls {
            let edgeIdx = EdgeIndex(nonCallEdges.count)
            nonCallEdges.append(edge)
            let key = EdgeKey(source: edge.source, target: edge.target, kind: edge.kind, line: edge.line)
            newEdgeDeduplicationSet.insert(key)
            newOutgoing[edge.source, default: []].append(edgeIdx)
            newIncoming[edge.target, default: []].append(edgeIdx)
        }

        self.edgePool = nonCallEdges
        self.edgeDeduplicationSet = newEdgeDeduplicationSet
        self.outgoingEdgeIndices = newOutgoing
        self.incomingEdgeIndices = newIncoming

        // 2. 遍历所有文件持久保存的 CallerInvocationSummary，重新解析建立 .calls 边
        for (_, summaries) in fileInvocationSummaries {
            for summary in summaries {
                guard let callerIdx = nodeIndexByID[summary.callerNodeID] else { continue }
                let callerNode = nodePool[Int(callerIdx)]

                for invokedName in summary.invokedNames where invokedName != callerNode.name {
                    guard let calleeIndices = nodesByName[invokedName] else { continue }

                    for calleeIdx in calleeIndices where calleeIdx != callerIdx {
                        let calleeNode = nodePool[Int(calleeIdx)]

                        // 质量置信度计算：同文件优先，单候选更高，多同名候选谨慎降权
                        let confidence: Float
                        if callerNode.path == calleeNode.path {
                            confidence = 0.85
                        } else if calleeIndices.count == 1 {
                            confidence = 0.80
                        } else {
                            confidence = 0.50
                        }

                        let edge = CompactGraphEdge(
                            source: callerIdx,
                            target: calleeIdx,
                            kind: .calls,
                            line: summary.callerLine,
                            confidence: confidence
                        )
                        addCompactEdge(edge)
                    }
                }
            }
        }
    }

    @discardableResult
    private func addNode(_ node: GraphNode) -> NodeIndex {
        if let existingIdx = nodeIndexByID[node.id] {
            nodePool[Int(existingIdx)] = node
            return existingIdx
        }
        let newIdx = NodeIndex(nodePool.count)
        nodePool.append(node)
        nodeIndexByID[node.id] = newIdx
        nodesByName[node.name, default: []].append(newIdx)
        return newIdx
    }

    @discardableResult
    private func addCompactEdge(_ edge: CompactGraphEdge) -> EdgeIndex? {
        let key = EdgeKey(source: edge.source, target: edge.target, kind: edge.kind, line: edge.line)
        guard !edgeDeduplicationSet.contains(key) else { return nil }

        edgeDeduplicationSet.insert(key)
        let edgeIdx = EdgeIndex(edgePool.count)
        edgePool.append(edge)
        outgoingEdgeIndices[edge.source, default: []].append(edgeIdx)
        incomingEdgeIndices[edge.target, default: []].append(edgeIdx)
        return edgeIdx
    }

    private func discoverSourceFiles(in directory: URL) -> [URL] {
        let validExtensions: Set<String> = [
            "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "cpp", "h", "hpp"
        ]
        var sourceFiles: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let last = fileURL.lastPathComponent
            if last == ".build" || last == "node_modules" || last == ".git" || last == "dist" || last == ".dev-sandbox" {
                enumerator.skipDescendants()
                continue
            }
            let p = fileURL.path
            if p.contains(".build/") || p.contains("node_modules/") || p.contains(".git/") || p.contains("dist/") {
                continue
            }
            if validExtensions.contains(fileURL.pathExtension.lowercased()) {
                sourceFiles.append(fileURL)
            }
        }
        return sourceFiles
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let r = root.standardizedFileURL.path
        let f = fileURL.standardizedFileURL.path
        if f.hasPrefix(r) {
            var rel = String(f.dropFirst(r.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return fileURL.lastPathComponent
    }

    private func extractModuleName(from path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count >= 2 && components[0] == "Sources" {
            return components[1]
        }
        if components.count >= 2 && components[0] == "Tests" {
            return components[1]
        }
        return components.first ?? "Core"
    }

    // MARK: - Disk Cache V4 (Sidecar Metadata Architecture)

    private struct GraphCachePayloadV3: Codable {
        static let currentVersion = 3
        let version: Int
        let workspaceCanonicalPath: String?
        let lastAccessTimestamp: Double?
        let manifest: [String: Double]
        let nodes: [GraphNode]
        let edges: [CompactGraphEdge]
        let fileInvocations: [String: [CallerInvocationSummary]]
    }

    private struct GraphCacheSidecarMeta: Codable {
        static let currentVersion = 4
        let version: Int
        let workspaceCanonicalPath: String?
        var lastAccessTimestamp: Double
        let nodeCount: Int
        let edgeCount: Int
        let bodyByteCount: Int64
    }

    private func cacheFileURL(for workspaceURL: URL) -> URL? {
        guard let cacheDir = cachePolicy.cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let canonicalPath = workspaceURL.standardizedFileURL.path
        let hashString = LingXiPlatform.crypto.sha256Hex(canonicalPath)
        return cacheDir.appendingPathComponent("graph_\(hashString).json")
    }

    private func sidecarFileURL(for workspaceURL: URL) -> URL? {
        guard let cacheDir = cachePolicy.cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let canonicalPath = workspaceURL.standardizedFileURL.path
        let hashString = LingXiPlatform.crypto.sha256Hex(canonicalPath)
        return cacheDir.appendingPathComponent("graph_\(hashString).meta.json")
    }

    private func saveToDiskCache(for workspaceURL: URL) {
        guard let url = cacheFileURL(for: workspaceURL) else { return }
        var manifest: [String: Double] = [:]
        for (file, date) in fileModificationTimes {
            manifest[file] = date.timeIntervalSince1970
        }
        let canonical = workspaceURL.standardizedFileURL.path
        let now = Date().timeIntervalSince1970
        let payload = GraphCachePayloadV3(
            version: GraphCachePayloadV3.currentVersion,
            workspaceCanonicalPath: canonical,
            lastAccessTimestamp: now,
            manifest: manifest,
            nodes: nodePool,
            edges: edgePool,
            fileInvocations: fileInvocationSummaries
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)

        // 写入轻量 Sidecar Metadata，供 prune 和 diagnostics 零反序列化瞬间查询
        let sidecar = GraphCacheSidecarMeta(
            version: GraphCacheSidecarMeta.currentVersion,
            workspaceCanonicalPath: canonical,
            lastAccessTimestamp: now,
            nodeCount: nodePool.count,
            edgeCount: edgePool.count,
            bodyByteCount: Int64(data.count)
        )
        if let sidecarData = try? JSONEncoder().encode(sidecar), let metaURL = sidecarFileURL(for: workspaceURL) {
            try? sidecarData.write(to: metaURL, options: .atomic)
        }

        pruneDiskCache()
    }

    private func loadFromDiskCache(for workspaceURL: URL) {
        guard let url = cacheFileURL(for: workspaceURL) else { return }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(GraphCachePayloadV3.self, from: data),
              payload.version == GraphCachePayloadV3.currentVersion else {
            // Version mismatch or corrupt cache: trigger fresh indexing
            return
        }
        for (file, timestamp) in payload.manifest {
            fileModificationTimes[file] = Date(timeIntervalSince1970: timestamp)
        }
        self.fileInvocationSummaries = payload.fileInvocations
        for node in payload.nodes { addNode(node) }
        for edge in payload.edges { addCompactEdge(edge) }
        if !payload.nodes.isEmpty { isInitialized = true }

        // Load hit: 更新 sidecar 元数据的最后访问时间 (touch lastAccess)
        if let metaURL = sidecarFileURL(for: workspaceURL),
           let metaData = try? Data(contentsOf: metaURL),
           var meta = try? JSONDecoder().decode(GraphCacheSidecarMeta.self, from: metaData) {
            meta.lastAccessTimestamp = Date().timeIntervalSince1970
            if let updated = try? JSONEncoder().encode(meta) {
                try? updated.write(to: metaURL, options: .atomic)
            }
        }
    }

    /// 执行基于 TTL、LRU、孤儿检测与磁盘预算的高性能修剪（零解码 Graph Body）
    public func pruneDiskCache(budget: GraphCacheBudget? = nil) {
        guard let cacheDir = cachePolicy.cacheDirectory,
              FileManager.default.fileExists(atPath: cacheDir.path) else { return }
        let effectiveBudget = budget ?? self.cacheBudget
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }

        struct Entry {
            let baseName: String
            let bodyURL: URL
            let metaURL: URL
            let meta: GraphCacheSidecarMeta
        }

        var validEntries: [Entry] = []
        var recognizedBodyFiles = Set<String>()

        for file in files where file.lastPathComponent.hasPrefix("graph_") && file.lastPathComponent.hasSuffix(".meta.json") {
            let filename = file.lastPathComponent
            // 提取 baseName: "graph_HASH"
            let baseName = String(filename.dropLast(".meta.json".count))
            let bodyURL = cacheDir.appendingPathComponent("\(baseName).json")
            recognizedBodyFiles.insert("\(baseName).json")

            guard let metaData = try? Data(contentsOf: file),
                  let meta = try? JSONDecoder().decode(GraphCacheSidecarMeta.self, from: metaData),
                  meta.version == GraphCacheSidecarMeta.currentVersion else {
                // 损坏或版本不匹配，清理
                try? fileManager.removeItem(at: file)
                try? fileManager.removeItem(at: bodyURL)
                continue
            }

            // 孤儿检测：如果工作区在磁盘上已不存在，自动回收
            if let canonical = meta.workspaceCanonicalPath, !canonical.isEmpty {
                if !fileManager.fileExists(atPath: canonical) {
                    try? fileManager.removeItem(at: file)
                    try? fileManager.removeItem(at: bodyURL)
                    continue
                }
            }

            let accessDate = Date(timeIntervalSince1970: meta.lastAccessTimestamp)
            // TTL 检测：超过最大保留天数自动回收
            if Date().timeIntervalSince(accessDate) > effectiveBudget.maxEntryAgeSeconds {
                try? fileManager.removeItem(at: file)
                try? fileManager.removeItem(at: bodyURL)
                continue
            }

            validEntries.append(Entry(baseName: baseName, bodyURL: bodyURL, metaURL: file, meta: meta))
        }

        // 清理没有对应 .meta.json 的遗留/孤立 json 缓存
        for file in files where file.lastPathComponent.hasPrefix("graph_") && file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".meta.json") {
            if !recognizedBodyFiles.contains(file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }

        // 按最后访问时间升序排列（最久未访问的在最前面）
        validEntries.sort { $0.meta.lastAccessTimestamp < $1.meta.lastAccessTimestamp }

        // 1. 条目数上限回收
        while validEntries.count > effectiveBudget.maxWorkspaceEntries && !validEntries.isEmpty {
            let victim = validEntries.removeFirst()
            try? fileManager.removeItem(at: victim.metaURL)
            try? fileManager.removeItem(at: victim.bodyURL)
        }

        // 2. 总容量上限回收 (LRU) - 零磁盘 IO，直接读取 Sidecar 中的 bodyByteCount
        var totalBytes = validEntries.reduce(0) { $0 + $1.meta.bodyByteCount }
        while totalBytes > effectiveBudget.maxTotalBytes && !validEntries.isEmpty {
            let victim = validEntries.removeFirst()
            try? fileManager.removeItem(at: victim.metaURL)
            try? fileManager.removeItem(at: victim.bodyURL)
            totalBytes -= victim.meta.bodyByteCount
        }
    }

    /// 获取当前持久化缓存诊断信息（零解码 Graph Body，瞬间返回）
    public func cacheDiagnostics() -> GraphCacheDiagnostics {
        guard let cacheDir = cachePolicy.cacheDirectory,
              FileManager.default.fileExists(atPath: cacheDir.path) else {
            return GraphCacheDiagnostics(entryCount: 0, totalBytes: 0, orphanCount: 0, legacyCount: 0, directoryPath: cachePolicy.cacheDirectory?.path ?? "disabled")
        }
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        var totalBytes: Int64 = 0
        var orphans = 0
        var legacy = 0

        for file in files where file.lastPathComponent.hasPrefix("graph_") && file.lastPathComponent.hasSuffix(".meta.json") {
            guard let metaData = try? Data(contentsOf: file),
                  let meta = try? JSONDecoder().decode(GraphCacheSidecarMeta.self, from: metaData),
                  meta.version == GraphCacheSidecarMeta.currentVersion else {
                legacy += 1
                continue
            }
            count += 1
            totalBytes += meta.bodyByteCount
            if let canonical = meta.workspaceCanonicalPath, !canonical.isEmpty, !fileManager.fileExists(atPath: canonical) {
                orphans += 1
            }
        }
        return GraphCacheDiagnostics(entryCount: count, totalBytes: totalBytes, orphanCount: orphans, legacyCount: legacy, directoryPath: cacheDir.path)
    }

    /// 清除遗留历史膨胀缓存（供系统启动、用户命令或诊断调用）
    public static func purgeLegacyCacheDir(targetDir: URL? = nil) {
        let dir = targetDir ?? CoreStorageLayout.current.graphCache
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir.path),
              let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            // 清理无 sidecar 或非当前版本的遗留文件
            if !file.lastPathComponent.hasSuffix(".meta.json") {
                let sidecar = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".meta.json")
                if !fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

#if DEBUG
extension CodebaseGraphEngine {
    public func cacheFileURLForTesting(workspaceURL: URL) -> URL {
        if let url = cacheFileURL(for: workspaceURL) {
            return url
        }
        let canonicalPath = workspaceURL.standardizedFileURL.path
        let hashString = LingXiPlatform.crypto.sha256Hex(canonicalPath)
        return FileManager.default.temporaryDirectory.appendingPathComponent("graph_\(hashString).json")
    }

    public func addEdgeForTesting(_ edge: GraphEdge) {
        let sIdx = nodeIndexByID[edge.sourceId] ?? addNode(
            GraphNode(id: edge.sourceId, kind: .function, name: edge.sourceId, qualifiedName: edge.sourceId, path: "")
        )
        let tIdx = nodeIndexByID[edge.targetId] ?? addNode(
            GraphNode(id: edge.targetId, kind: .function, name: edge.targetId, qualifiedName: edge.targetId, path: "")
        )
        addCompactEdge(CompactGraphEdge(
            source: sIdx,
            target: tIdx,
            kind: edge.kind,
            line: Int32(edge.line ?? 0),
            confidence: Float(edge.confidence)
        ))
    }

    public func addNodeForTesting(_ node: GraphNode) {
        addNode(node)
    }

    public func removeFileEntitiesForTesting(for fileURL: URL, root: URL) {
        removeFileEntities(for: fileURL, root: root)
    }

    public func removeFileEntitiesByRelPathForTesting(relPath: String) {
        removeFileEntities(byRelPath: relPath)
    }

    public func getInvocationSummariesForTesting() -> [String: [CallerInvocationSummary]] {
        fileInvocationSummaries
    }
}
#endif
