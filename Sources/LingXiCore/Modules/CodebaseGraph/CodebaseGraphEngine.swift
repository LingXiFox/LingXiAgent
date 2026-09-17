import Foundation
import LingXiPlatform
import LingXiProtocol

/// 代码图谱构建与拓扑分析引擎 (CodebaseGraphEngine)。
/// 负责扫描代码库、提取 AST 结构与依赖边、持久化紧凑缓存并提供调用拓扑与架构分析。
/// Phase 8: Compact Indexing (NodePool + CompactGraphEdge) + Caller-Local Invocation Extraction
public actor CodebaseGraphEngine {
    public static let shared = CodebaseGraphEngine()

    // MARK: - Compact Storage Pools
    private var nodePool: [GraphNode] = []
    private var nodeIndexByID: [String: NodeIndex] = [:]
    private var nodesByName: [String: [NodeIndex]] = [:]

    private var edgePool: [CompactGraphEdge] = []
    private var edgeDeduplicationSet: Set<String> = [] // "\(source)->\(kind)->\(target):\(line)"

    private var outgoingEdgeIndices: [NodeIndex: [EdgeIndex]] = [:]
    private var incomingEdgeIndices: [NodeIndex: [EdgeIndex]] = [:]

    private var fileModificationTimes: [String: Date] = [:]
    private var fileFunctionSpans: [String: [FunctionSpan]] = [:]

    private var workspaceRootURL: URL?
    private var isIndexing: Bool = false
    private var isInitialized: Bool = false

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
        public let approximateHeapBytes: Int

        public init(
            nodeCount: Int,
            edgeCount: Int,
            outgoingEdgeReferenceCount: Int,
            incomingEdgeReferenceCount: Int,
            approximateHeapBytes: Int
        ) {
            self.nodeCount = nodeCount
            self.edgeCount = edgeCount
            self.outgoingEdgeReferenceCount = outgoingEdgeReferenceCount
            self.incomingEdgeReferenceCount = incomingEdgeReferenceCount
            self.approximateHeapBytes = approximateHeapBytes
        }
    }

    public func memoryDiagnostics() -> GraphMemoryDiagnostics {
        let outCount = outgoingEdgeIndices.values.reduce(0) { $0 + $1.count }
        let inCount = incomingEdgeIndices.values.reduce(0) { $0 + $1.count }
        let nodeBytes = nodePool.count * 128
        let edgeBytes = edgePool.count * MemoryLayout<CompactGraphEdge>.stride + (outCount + inCount) * 4
        return GraphMemoryDiagnostics(
            nodeCount: nodePool.count,
            edgeCount: edgePool.count,
            outgoingEdgeReferenceCount: outCount,
            incomingEdgeReferenceCount: inCount,
            approximateHeapBytes: nodeBytes + edgeBytes
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
        fileFunctionSpans.removeAll(keepingCapacity: false)
        workspaceRootURL = nil
        isInitialized = false
    }

    public init() {}

    /// 索引或增量更新工作区代码图谱
    public func indexWorkspace(workspaceURL: URL, forceReindex: Bool = false) async -> ArchitectureOverview {
        isIndexing = true
        defer {
            isIndexing = false
            isInitialized = true
            // Phase 8: Release temporary parser scratch spans immediately after index build to prevent memory bloat
            fileFunctionSpans.removeAll(keepingCapacity: false)
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

        // 尝试从持久化缓存载入 V2
        if nodePool.isEmpty && !forceReindex {
            loadFromDiskCache(for: workspaceURL)
        }

        let fileURLs = discoverSourceFiles(in: workspaceURL)
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

        // 仅对变更或新增文件重新解析
        for file in changedFiles {
            removeFileEntities(for: file, root: workspaceURL)
            parseFile(file, root: workspaceURL)
        }

        // 重新构建跨文件精准调用边 (Caller-local invocation matching)
        resolveCrossFileCallEdges()

        // 持久化到本地磁盘缓存 V2
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
        var visited = Set<NodeIndex>([rootNodeIdx])
        var queue: [(nodeIdx: NodeIndex, depth: Int)] = [(rootNodeIdx, 1)]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.depth > maxDepth { continue }

            let relatedEdgeIndices: [EdgeIndex]
            switch direction {
            case .inbound:
                // 找谁调用了我 (target == current.nodeIdx)
                relatedEdgeIndices = incomingEdgeIndices[current.nodeIdx] ?? []
            case .outbound:
                // 找我调用了谁 (source == current.nodeIdx)
                relatedEdgeIndices = outgoingEdgeIndices[current.nodeIdx] ?? []
            }

            for edgeIdx in relatedEdgeIndices {
                let edge = edgePool[Int(edgeIdx)]
                guard edge.kind == .calls else { continue }
                let nextNodeIdx = (direction == .inbound) ? edge.source : edge.target
                guard Int(nextNodeIdx) < nodePool.count else { continue }
                let nextNode = nodePool[Int(nextNodeIdx)]
                let currentNode = nodePool[Int(current.nodeIdx)]

                let step = (direction == .inbound)
                    ? TraceStep(depth: current.depth, from: nextNode, to: currentNode, line: Int(edge.line), kind: edge.kind)
                    : TraceStep(depth: current.depth, from: currentNode, to: nextNode, line: Int(edge.line), kind: edge.kind)
                steps.append(step)

                if !visited.contains(nextNodeIdx) {
                    visited.insert(nextNodeIdx)
                    queue.append((nextNodeIdx, current.depth + 1))
                }
            }
        }

        return CallTraceReport(root: rootNode, direction: direction, totalDepth: maxDepth, steps: steps)
    }

    /// 基于名称或关键词检索图谱节点
    public func search(query: String, kind: GraphNodeKind? = nil, limit: Int = 30) -> [GraphNode] {
        let q = query.lowercased()
        var results = nodePool.filter { node in
            if let kind, node.kind != kind { return false }
            return node.name.lowercased().contains(q) || node.qualifiedName.lowercased().contains(q)
        }
        results.sort {
            if $0.name.lowercased() == q { return true }
            if $1.name.lowercased() == q { return false }
            return $0.name.count < $1.name.count
        }
        return Array(results.prefix(limit))
    }

    // MARK: - Private Parser & Graph Construction

    private func findNodeIndex(by query: String) -> NodeIndex? {
        if let exact = nodeIndexByID[query] { return exact }
        if let indices = nodesByName[query], let first = indices.first { return first }
        if let match = search(query: query, limit: 1).first, let idx = nodeIndexByID[match.id] {
            return idx
        }
        return nil
    }

    private func removeFileEntities(for fileURL: URL, root: URL) {
        let relPath = relativePath(for: fileURL, root: root)
        let removedIndices = Set(nodePool.indices.compactMap { idx -> NodeIndex? in
            (nodePool[idx].path == relPath) ? NodeIndex(idx) : nil
        })
        guard !removedIndices.isEmpty else {
            fileFunctionSpans.removeValue(forKey: relPath)
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
        var newEdgeDeduplicationSet: Set<String> = []
        var newOutgoing: [NodeIndex: [EdgeIndex]] = [:]
        var newIncoming: [NodeIndex: [EdgeIndex]] = [:]

        for edge in edgePool {
            guard let newSource = oldToNewNodeMap[edge.source],
                  let newTarget = oldToNewNodeMap[edge.target] else {
                continue // 属于被删除实体的边被彻底清除
            }
            let key = "\(newSource)->\(edge.kind.rawValue)->\(newTarget):\(edge.line)"
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
        self.fileFunctionSpans.removeValue(forKey: relPath)
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

        var containerStack: [(id: String, idx: NodeIndex, depth: Int)] = []
        var activeScopes: [ActiveScope] = []
        var spans: [FunctionSpan] = []
        var currentBraceDepth = 0

        for (idx, rawLine) in fileLines.enumerated() {
            let lineNum = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let openBraces = line.filter { $0 == "{" }.count
            let closeBraces = line.filter { $0 == "}" }.count

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

            // 2. Class / Struct / Interface / Protocol / Enum
            if let decl = matchTypeDeclaration(line: line, ext: ext) {
                let entityId = "\(decl.kind.rawValue):\(relPath):\(decl.name)"
                let node = GraphNode(
                    id: entityId,
                    kind: decl.kind,
                    name: decl.name,
                    qualifiedName: "\(relPath).\(decl.name)",
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
                containerStack.append((id: entityId, idx: entityIdx, depth: currentBraceDepth))
                closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
                continue
            }

            // 3. Function / Method Declaration
            if let funcName = matchFunctionDeclaration(line: line, ext: ext) {
                let isMethod = !containerStack.isEmpty
                let entityId = "\(isMethod ? "method" : "function"):\(relPath):\(funcName)"
                let node = GraphNode(
                    id: entityId,
                    kind: isMethod ? .method : .function,
                    name: funcName,
                    qualifiedName: "\(relPath).\(funcName)",
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
                spans.append(FunctionSpan(
                    nodeID: entityId,
                    name: funcName,
                    filePath: relPath,
                    startLine: lineNum,
                    endLine: lineNum,
                    invokedNames: []
                ))
                activeScopes.append(ActiveScope(spanIndex: spanIdx, braceDepth: currentBraceDepth))
                closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
                continue
            }

            // 4. Caller-local Invocation Scanner (Phase 8)
            if !activeScopes.isEmpty {
                let calls = extractInvocations(from: line)
                for call in calls {
                    for scope in activeScopes {
                        spans[scope.spanIndex].invokedNames.insert(call)
                    }
                }
            }

            currentBraceDepth += (openBraces - closeBraces)
            closeScopesIfNeeded(currentDepth: currentBraceDepth, lineNum: lineNum, activeScopes: &activeScopes, spans: &spans, containerStack: &containerStack)
        }

        // 闭合可能遗留的未闭合 scope
        for scope in activeScopes {
            spans[scope.spanIndex].endLine = fileLines.count
        }

        fileFunctionSpans[relPath] = spans
    }

    private func closeScopesIfNeeded(
        currentDepth: Int,
        lineNum: Int,
        activeScopes: inout [ActiveScope],
        spans: inout [FunctionSpan],
        containerStack: inout [(id: String, idx: NodeIndex, depth: Int)]
    ) {
        while let lastScope = activeScopes.last, currentDepth < lastScope.braceDepth {
            spans[lastScope.spanIndex].endLine = lineNum
            activeScopes.removeLast()
        }
        while let lastContainer = containerStack.last, currentDepth < lastContainer.depth {
            containerStack.removeLast()
        }
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

    private func matchFunctionDeclaration(line: String, ext: String) -> String? {
        let prefixes = ["func ", "def ", "fn ", "function "]
        for p in prefixes {
            if let range = line.range(of: p) {
                let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let paren = after.firstIndex(of: "(") {
                    let name = String(after[..<paren]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !name.contains(" ") && !name.hasPrefix("//") {
                        return name
                    }
                }
            }
        }
        return nil
    }

    /// Phase 8: 基于 Caller-local Invocation 精确建立跨文件调用边，彻底消除笛卡尔积边
    private func resolveCrossFileCallEdges() {
        for (_, spans) in fileFunctionSpans {
            for span in spans {
                guard let callerIdx = nodeIndexByID[span.nodeID] else { continue }
                for invokedName in span.invokedNames where invokedName != span.name {
                    guard let calleeIndices = nodesByName[invokedName] else { continue }
                    for calleeIdx in calleeIndices where calleeIdx != callerIdx {
                        let edge = CompactGraphEdge(
                            source: callerIdx,
                            target: calleeIdx,
                            kind: .calls,
                            line: Int32(span.startLine),
                            confidence: 0.90
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
        let key = "\(edge.source)->\(edge.kind.rawValue)->\(edge.target):\(edge.line)"
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

    // MARK: - Disk Cache V2

    private struct GraphCachePayloadV2: Codable {
        static let currentVersion = 2
        let version: Int
        let manifest: [String: Double]
        let nodes: [GraphNode]
        let edges: [CompactGraphEdge]
    }

    private func cacheFileURL(for workspaceURL: URL) -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lingxiagent/cache/graph", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let canonicalPath = workspaceURL.standardizedFileURL.path
        let hashString = LingXiPlatform.crypto.sha256Hex(canonicalPath)
        return cacheDir.appendingPathComponent("graph_\(hashString).json")
    }

    private func saveToDiskCache(for workspaceURL: URL) {
        let url = cacheFileURL(for: workspaceURL)
        var manifest: [String: Double] = [:]
        for (file, date) in fileModificationTimes {
            manifest[file] = date.timeIntervalSince1970
        }
        let payload = GraphCachePayloadV2(
            version: GraphCachePayloadV2.currentVersion,
            manifest: manifest,
            nodes: nodePool,
            edges: edgePool
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url)
        }
    }

    private func loadFromDiskCache(for workspaceURL: URL) {
        let url = cacheFileURL(for: workspaceURL)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(GraphCachePayloadV2.self, from: data),
              payload.version == GraphCachePayloadV2.currentVersion else {
            // Version mismatch or corrupt cache: trigger fresh indexing
            return
        }
        for (file, timestamp) in payload.manifest {
            fileModificationTimes[file] = Date(timeIntervalSince1970: timestamp)
        }
        for node in payload.nodes { addNode(node) }
        for edge in payload.edges { addCompactEdge(edge) }
        if !payload.nodes.isEmpty { isInitialized = true }
    }
}

#if DEBUG
extension CodebaseGraphEngine {
    public func cacheFileURLForTesting(workspaceURL: URL) -> URL {
        cacheFileURL(for: workspaceURL)
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
}
#endif
