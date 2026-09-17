import CryptoKit
import Foundation
import LingXiPlatform
import LingXiProtocol

/// 代码图谱构建与拓扑分析引擎 (CodebaseGraphEngine)。
/// 负责扫描代码库、提取 AST 结构与依赖边、持久化缓存并提供调用拓扑与架构分析。
public actor CodebaseGraphEngine {
    public static let shared = CodebaseGraphEngine()

    private var nodes: [String: GraphNode] = [:] // id -> Node
    private var edges: [String: GraphEdge] = [:] // id -> Edge
    private var edgesBySource: [String: [GraphEdge]] = [:]
    private var edgesByTarget: [String: [GraphEdge]] = [:]
    private var nodesByName: [String: [String]] = [:] // name -> [nodeId]
    private var fileModificationTimes: [String: Date] = [:]
    private var fileIdentifiers: [String: Set<String>] = [:]
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
        nodes.count
    }

    public var edgeCount: Int {
        edges.count
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
        let outCount = edgesBySource.values.reduce(0) { $0 + $1.count }
        let inCount = edgesByTarget.values.reduce(0) { $0 + $1.count }
        let nodeBytes = nodes.count * 256
        let edgeBytes = edges.count * 160 + (outCount + inCount) * 8
        return GraphMemoryDiagnostics(
            nodeCount: nodes.count,
            edgeCount: edges.count,
            outgoingEdgeReferenceCount: outCount,
            incomingEdgeReferenceCount: inCount,
            approximateHeapBytes: nodeBytes + edgeBytes
        )
    }

    public func clearGraphMemory() {
        nodes.removeAll(keepingCapacity: false)
        edges.removeAll(keepingCapacity: false)
        edgesBySource.removeAll(keepingCapacity: false)
        edgesByTarget.removeAll(keepingCapacity: false)
        nodesByName.removeAll(keepingCapacity: false)
        fileModificationTimes.removeAll(keepingCapacity: false)
        fileIdentifiers.removeAll(keepingCapacity: false)
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
            // Phase 7: Release AST token scratch set immediately after index build to prevent memory bloat
            fileIdentifiers.removeAll(keepingCapacity: false)
        }

        // Workspace 变更时强制清空旧工作区图谱，防止内存污染与泄漏
        if let current = self.workspaceRootURL, current.standardizedFileURL.path != workspaceURL.standardizedFileURL.path {
            clearGraphMemory()
        }
        self.workspaceRootURL = workspaceURL

        if forceReindex {
            nodes.removeAll()
            edges.removeAll()
            edgesBySource.removeAll()
            edgesByTarget.removeAll()
            nodesByName.removeAll()
            fileModificationTimes.removeAll()
            fileIdentifiers.removeAll()
        }

        // 尝试从持久化缓存载入
        if nodes.isEmpty && !forceReindex {
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

        // 重新构建跨文件调用边
        resolveCrossFileCallEdges()

        // 持久化到本地磁盘缓存
        saveToDiskCache(for: workspaceURL)

        return getArchitecture()
    }

    /// 获取整体架构分层概览与核心热点
    public func getArchitecture() -> ArchitectureOverview {
        let projectName = workspaceRootURL?.lastPathComponent ?? "Workspace"
        let allNodes = Array(nodes.values)
        let totalNodes = allNodes.count
        let totalEdges = edges.count
        let totalFiles = Set(allNodes.map(\.path)).count

        // 1. 分层识别 (api, core, infra, test)
        var layerMap: [String: (desc: String, files: Set<String>, nodes: Int)] = [
            "api": ("HTTP / CLI / TUI / Protocol 交互接入层", [], 0),
            "core": ("核心业务逻辑 / 状态规约 / Agent 执行引擎", [], 0),
            "infra": ("平台系统抽象 / 存储 / 进程 / 基础设施", [], 0),
            "test": ("测试套件 / 验证用例", [], 0)
        ]

        for node in allNodes {
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
        var fanInMap: [String: Int] = [:]
        var fanOutMap: [String: Int] = [:]
        for edge in edges.values where edge.kind == .calls || edge.kind == .implements || edge.kind == .inherits {
            fanInMap[edge.targetId, default: 0] += 1
            fanOutMap[edge.sourceId, default: 0] += 1
        }

        let hotspots = allNodes
            .filter { $0.kind == .function || $0.kind == .method || $0.kind == .class || $0.kind == .struct || $0.kind == .interface }
            .map { node in
                GraphHotspot(node: node, fanIn: fanInMap[node.id, default: 0], fanOut: fanOutMap[node.id, default: 0])
            }
            .filter { $0.fanIn > 0 }
            .sorted { $0.fanIn > $1.fanIn }
            .prefix(15)

        // 3. 模块级依赖拓扑
        var moduleNodes: [String: Set<String>] = [:]
        for node in allNodes {
            let mod = extractModuleName(from: node.path)
            moduleNodes[mod, default: []].insert(node.id)
        }

        var modules: [ModuleOverview] = []
        for (modName, nodeIds) in moduleNodes {
            var outboundDeps: Set<String> = []
            for id in nodeIds {
                if let outEdges = edgesBySource[id] {
                    for edge in outEdges where edge.kind == .calls || edge.kind == .imports {
                        if let targetNode = nodes[edge.targetId] {
                            let targetMod = extractModuleName(from: targetNode.path)
                            if targetMod != modName {
                                outboundDeps.insert(targetMod)
                            }
                        }
                    }
                }
            }
            modules.append(ModuleOverview(name: modName, nodeCount: nodeIds.count, outboundDependencies: Array(outboundDeps).sorted()))
        }
        modules.sort { $0.nodeCount > $1.nodeCount }

        return ArchitectureOverview(
            projectName: projectName,
            totalNodes: totalNodes,
            totalEdges: totalEdges,
            totalFiles: totalFiles,
            layers: layers,
            hotspots: Array(hotspots),
            modules: modules
        )
    }

    /// 拓扑调用链追踪 (trace_path)
    public func traceCallPath(symbolNameOrId: String, direction: TraceDirection, maxDepth: Int = 3) -> CallTraceReport? {
        guard let rootNode = findNode(by: symbolNameOrId) else { return nil }

        var steps: [TraceStep] = []
        var visited = Set<String>([rootNode.id])
        var queue: [(node: GraphNode, depth: Int)] = [(rootNode, 1)]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.depth > maxDepth { continue }

            let relatedEdges: [GraphEdge]
            switch direction {
            case .inbound:
                // 找谁调用了我 (targetId == current.node.id)
                relatedEdges = edgesByTarget[current.node.id] ?? []
            case .outbound:
                // 找我调用了谁 (sourceId == current.node.id)
                relatedEdges = edgesBySource[current.node.id] ?? []
            }

            for edge in relatedEdges where edge.kind == .calls {
                let nextNodeId = (direction == .inbound) ? edge.sourceId : edge.targetId
                guard let nextNode = nodes[nextNodeId] else { continue }

                let step = (direction == .inbound)
                    ? TraceStep(depth: current.depth, from: nextNode, to: current.node, line: edge.line, kind: edge.kind)
                    : TraceStep(depth: current.depth, from: current.node, to: nextNode, line: edge.line, kind: edge.kind)
                steps.append(step)

                if !visited.contains(nextNode.id) {
                    visited.insert(nextNode.id)
                    queue.append((nextNode, current.depth + 1))
                }
            }
        }

        return CallTraceReport(root: rootNode, direction: direction, totalDepth: maxDepth, steps: steps)
    }

    /// 基于名称或关键词检索图谱节点
    public func search(query: String, kind: GraphNodeKind? = nil, limit: Int = 30) -> [GraphNode] {
        let q = query.lowercased()
        var results = nodes.values.filter { node in
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

    private func findNode(by query: String) -> GraphNode? {
        if let exact = nodes[query] { return exact }
        if let nodeIds = nodesByName[query], let firstId = nodeIds.first { return nodes[firstId] }
        let matches = search(query: query, limit: 1)
        return matches.first
    }

    private func removeFileEntities(for fileURL: URL, root: URL) {
        let relPath = relativePath(for: fileURL, root: root)
        let removedNodeIds = Set(nodes.values.filter { $0.path == relPath }.map(\.id))
        for id in removedNodeIds {
            nodes.removeValue(forKey: id)
            if let edgesOut = edgesBySource.removeValue(forKey: id) {
                for e in edgesOut {
                    edges.removeValue(forKey: e.id)
                    edgesByTarget[e.targetId]?.removeAll(where: { $0.id == e.id })
                }
            }
            if let edgesIn = edgesByTarget.removeValue(forKey: id) {
                for e in edgesIn {
                    edges.removeValue(forKey: e.id)
                    edgesBySource[e.sourceId]?.removeAll(where: { $0.id == e.id })
                }
            }
        }
        // 清理 nodesByName
        for (name, ids) in nodesByName {
            let filtered = ids.filter { !removedNodeIds.contains($0) }
            if filtered.isEmpty {
                nodesByName.removeValue(forKey: name)
            } else {
                nodesByName[name] = filtered
            }
        }
        fileIdentifiers.removeValue(forKey: relPath)
    }

    private func parseFile(_ fileURL: URL, root: URL) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let relPath = relativePath(for: fileURL, root: root)
        let ext = fileURL.pathExtension.lowercased()
        let isTestFile = relPath.contains("Test") || relPath.contains(".test.") || relPath.contains("_test.")

        let fileNodeId = "file:\(relPath)"
        let fileNode = GraphNode(
            id: fileNodeId,
            kind: .file,
            name: fileURL.lastPathComponent,
            qualifiedName: relPath,
            path: relPath,
            startLine: 1,
            endLine: content.components(separatedBy: "\n").count,
            isExported: true,
            isTest: isTestFile
        )
        addNode(fileNode)

        let lines = content.components(separatedBy: "\n")
        var containerStack: [(id: String, depth: Int)] = []
        var currentBraceDepth = 0

        for (idx, rawLine) in lines.enumerated() {
            let lineNum = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let openBraces = line.filter { $0 == "{" }.count
            let closeBraces = line.filter { $0 == "}" }.count

            // 1. Imports
            if line.hasPrefix("import ") {
                let mod = line.replacingOccurrences(of: "import ", with: "")
                    .replacingOccurrences(of: ";", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let importEdge = GraphEdge(sourceId: fileNodeId, targetId: "module:\(mod)", kind: .imports, line: lineNum)
                addEdge(importEdge)
                currentBraceDepth += (openBraces - closeBraces)
                while let last = containerStack.last, currentBraceDepth < last.depth {
                    containerStack.removeLast()
                }
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
                addNode(node)
                let parentId = containerStack.last?.id ?? fileNodeId
                addEdge(GraphEdge(sourceId: parentId, targetId: entityId, kind: .defines, line: lineNum))

                if let inherit = decl.inherits {
                    for base in inherit.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        addEdge(GraphEdge(sourceId: entityId, targetId: "type:\(base)", kind: .inherits, line: lineNum))
                    }
                }
                currentBraceDepth += (openBraces - closeBraces)
                containerStack.append((id: entityId, depth: currentBraceDepth))
                continue
            }

            // 3. Function / Method
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
                addNode(node)

                let parentId = containerStack.last?.id ?? fileNodeId
                addEdge(GraphEdge(sourceId: parentId, targetId: entityId, kind: .defines, line: lineNum))
                currentBraceDepth += (openBraces - closeBraces)
                while let last = containerStack.last, currentBraceDepth < last.depth {
                    containerStack.removeLast()
                }
                continue
            }

            currentBraceDepth += (openBraces - closeBraces)
            while let last = containerStack.last, currentBraceDepth < last.depth {
                containerStack.removeLast()
            }
        }

        let words = content.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        fileIdentifiers[relPath] = Set(words)
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
        // func foo( or def foo( or function foo(
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

    private func resolveCrossFileCallEdges() {
        // 基于 AST 声明的符号名建立跨文件函数互调关联 (倒排哈希极速匹配)
        let callableNodes = nodes.values.filter { $0.kind == .function || $0.kind == .method }
        let callableByFile = Dictionary(grouping: callableNodes, by: \.path)

        for (filePath, callers) in callableByFile {
            guard let tokens = fileIdentifiers[filePath] else { continue }
            for token in tokens {
                guard let calleeIds = nodesByName[token] else { continue }
                for caller in callers where caller.name != token {
                    for calleeId in calleeIds where calleeId != caller.id {
                        let edge = GraphEdge(sourceId: caller.id, targetId: calleeId, kind: .calls, confidence: 0.85)
                        addEdge(edge)
                    }
                }
            }
        }
    }

    private func addNode(_ node: GraphNode) {
        nodes[node.id] = node
        nodesByName[node.name, default: []].append(node.id)
    }

    private func addEdge(_ edge: GraphEdge) {
        // Phase 7: deduplicate edge insertion to prevent exponential adjacency growth on reindex
        guard edges[edge.id] == nil else { return }
        edges[edge.id] = edge
        edgesBySource[edge.sourceId, default: []].append(edge)
        edgesByTarget[edge.targetId, default: []].append(edge)
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

    // MARK: - Disk Cache

    private struct GraphCachePayload: Codable {
        let manifest: [String: Double]
        let nodes: [GraphNode]
        let edges: [GraphEdge]
    }

    private func cacheFileURL(for workspaceURL: URL) -> URL {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lingxiagent/cache/graph", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let canonicalPath = workspaceURL.standardizedFileURL.path
        let hashData = SHA256.hash(data: Data(canonicalPath.utf8))
        let hashString = hashData.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("graph_\(hashString).json")
    }

    private func saveToDiskCache(for workspaceURL: URL) {
        let url = cacheFileURL(for: workspaceURL)
        var manifest: [String: Double] = [:]
        for (file, date) in fileModificationTimes {
            manifest[file] = date.timeIntervalSince1970
        }
        let payload = GraphCachePayload(manifest: manifest, nodes: Array(nodes.values), edges: Array(edges.values))
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url)
        }
    }

    private func loadFromDiskCache(for workspaceURL: URL) {
        let url = cacheFileURL(for: workspaceURL)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(GraphCachePayload.self, from: data) else {
            return
        }
        for (file, timestamp) in payload.manifest {
            fileModificationTimes[file] = Date(timeIntervalSince1970: timestamp)
        }
        for node in payload.nodes { addNode(node) }
        for edge in payload.edges { addEdge(edge) }
        if !payload.nodes.isEmpty { isInitialized = true }
    }
}

#if DEBUG
extension CodebaseGraphEngine {
    public func cacheFileURLForTesting(workspaceURL: URL) -> URL {
        cacheFileURL(for: workspaceURL)
    }

    public func addEdgeForTesting(_ edge: GraphEdge) {
        addEdge(edge)
    }

    public func addNodeForTesting(_ node: GraphNode) {
        addNode(node)
    }

    public func removeFileEntitiesForTesting(for fileURL: URL, root: URL) {
        removeFileEntities(for: fileURL, root: root)
    }
}
#endif
