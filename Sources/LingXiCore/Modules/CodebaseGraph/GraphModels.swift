import Foundation

/// 代码图谱中的节点类别
public enum GraphNodeKind: String, Codable, Sendable, CaseIterable {
    case file
    case module
    case `class`
    case `struct`
    case interface // protocol in Swift, interface in TS/Go/Java
    case function
    case method
    case variable
    case route
    case `extension`
}

/// 代码图谱节点 (GraphNode)
public struct GraphNode: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let kind: GraphNodeKind
    public let name: String
    public let qualifiedName: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let isExported: Bool
    public let isTest: Bool
    public let docstring: String?

    public init(
        id: String,
        kind: GraphNodeKind,
        name: String,
        qualifiedName: String,
        path: String,
        startLine: Int = 1,
        endLine: Int = 1,
        isExported: Bool = true,
        isTest: Bool = false,
        docstring: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.qualifiedName = qualifiedName
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.isExported = isExported
        self.isTest = isTest
        self.docstring = docstring
    }
}

/// 代码图谱中的边关系类别
public enum GraphEdgeKind: String, Codable, Sendable, CaseIterable {
    case calls          // 函数/方法调用
    case defines        // 模块/文件/类 定义子实体
    case imports        // 文件引入外部模块
    case implements     // 遵循接口/协议
    case inherits       // 继承基类
    case containsFile   // 模块/目录包含文件
}

/// 代码图谱有向边 (GraphEdge)
public struct GraphEdge: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let sourceId: String
    public let targetId: String
    public let kind: GraphEdgeKind
    public let line: Int?
    public let confidence: Double

    public init(
        sourceId: String,
        targetId: String,
        kind: GraphEdgeKind,
        line: Int? = nil,
        confidence: Double = 1.0
    ) {
        self.id = "\(sourceId)->\(kind.rawValue)->\(targetId):\(line ?? 0)"
        self.sourceId = sourceId
        self.targetId = targetId
        self.kind = kind
        self.line = line
        self.confidence = confidence
    }
}

public typealias NodeIndex = Int32
public typealias EdgeIndex = Int32

/// 紧凑边结构：使用 Int32 索引指向节点池，仅占用 16 字节，内存降低 90%
public struct CompactGraphEdge: Codable, Sendable, Equatable {
    public let source: NodeIndex
    public let target: NodeIndex
    public let kind: GraphEdgeKind
    public let line: Int32
    public let confidence: Float

    public init(
        source: NodeIndex,
        target: NodeIndex,
        kind: GraphEdgeKind,
        line: Int32 = 0,
        confidence: Float = 1.0
    ) {
        self.source = source
        self.target = target
        self.kind = kind
        self.line = line
        self.confidence = confidence
    }
}

/// 调用链追踪方向
public enum TraceDirection: String, Codable, Sendable {
    case inbound  // 追查谁调用了该节点 (反向扇入)
    case outbound // 追查该节点调用了谁 (正向扇出)
}

/// 调用追踪单项结果
public struct TraceStep: Codable, Sendable, Equatable {
    public let depth: Int
    public let from: GraphNode
    public let to: GraphNode
    public let line: Int?
    public let kind: GraphEdgeKind

    public init(depth: Int, from: GraphNode, to: GraphNode, line: Int? = nil, kind: GraphEdgeKind = .calls) {
        self.depth = depth
        self.from = from
        self.to = to
        self.line = line
        self.kind = kind
    }
}

/// 调用拓扑追踪总体结果
public struct CallTraceReport: Codable, Sendable, Equatable {
    public let root: GraphNode
    public let direction: TraceDirection
    public let totalDepth: Int
    public let steps: [TraceStep]

    public init(root: GraphNode, direction: TraceDirection, totalDepth: Int, steps: [TraceStep]) {
        self.root = root
        self.direction = direction
        self.totalDepth = totalDepth
        self.steps = steps
    }
}

/// 架构分层定义
public struct ArchitectureLayer: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let fileCount: Int
    public let nodeCount: Int

    public init(name: String, description: String, fileCount: Int, nodeCount: Int) {
        self.name = name
        self.description = description
        self.fileCount = fileCount
        self.nodeCount = nodeCount
    }
}

/// 架构核心热点（高扇入关键枢纽节点）
public struct GraphHotspot: Codable, Sendable, Equatable {
    public let node: GraphNode
    public let fanIn: Int
    public let fanOut: Int

    public init(node: GraphNode, fanIn: Int, fanOut: Int) {
        self.node = node
        self.fanIn = fanIn
        self.fanOut = fanOut
    }
}

/// 模块概览
public struct ModuleOverview: Codable, Sendable, Equatable {
    public let name: String
    public let nodeCount: Int
    public let outboundDependencies: [String]

    public init(name: String, nodeCount: Int, outboundDependencies: [String]) {
        self.name = name
        self.nodeCount = nodeCount
        self.outboundDependencies = outboundDependencies
    }
}

/// 代码库整体架构概览 (ArchitectureOverview)
public struct ArchitectureOverview: Codable, Sendable, Equatable {
    public let projectName: String
    public let totalNodes: Int
    public let totalEdges: Int
    public let totalFiles: Int
    public let layers: [ArchitectureLayer]
    public let hotspots: [GraphHotspot]
    public let modules: [ModuleOverview]

    public init(
        projectName: String,
        totalNodes: Int,
        totalEdges: Int,
        totalFiles: Int,
        layers: [ArchitectureLayer],
        hotspots: [GraphHotspot],
        modules: [ModuleOverview]
    ) {
        self.projectName = projectName
        self.totalNodes = totalNodes
        self.totalEdges = totalEdges
        self.totalFiles = totalFiles
        self.layers = layers
        self.hotspots = hotspots
        self.modules = modules
    }
}
