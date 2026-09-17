import Foundation

/// 检索生产运行时轻量遥测 (RetrievalTelemetry)
/// 负责以极低开销、异步非阻塞、Fail-Open 方式收集结构化检索调用指标
/// 铁律：
/// 1. 绝不大段记录完整代码切片或敏感内容
/// 2. 固定容量环形缓冲区（默认 200 条），零内存无限制增长风险
/// 3. 为未来 ROI 分析（Search -> Candidate Returned -> Candidate Opened）提供权威数据支持
public actor RetrievalTelemetry {
    public static let shared = RetrievalTelemetry()

    public struct Event: Sendable, Codable {
        public let query: String
        public let hasHints: Bool
        public let lexicalHintCount: Int
        public let symbolHintCount: Int
        public let scope: String
        public let confidence: String
        public let topScore: Double
        public let resultCount: Int
        public let timestamp: Date
    }

    private var events: [Event] = []
    private let maxCapacity = 200

    public init() {}

    /// 记录一次检索调用事件
    public func record(
        query: String,
        hasHints: Bool,
        lexicalHintCount: Int,
        symbolHintCount: Int,
        scope: String,
        confidence: String,
        topScore: Double,
        resultCount: Int
    ) {
        let event = Event(
            query: query,
            hasHints: hasHints,
            lexicalHintCount: lexicalHintCount,
            symbolHintCount: symbolHintCount,
            scope: scope,
            confidence: confidence,
            topScore: topScore,
            resultCount: resultCount,
            timestamp: Date()
        )
        if events.count >= maxCapacity {
            events.removeFirst()
        }
        events.append(event)
    }

    /// 获取最近遥测事件列表
    public var recentEvents: [Event] {
        events
    }

    /// 获取遥测统计概览
    public var stats: [String: Double] {
        guard !events.isEmpty else { return [:] }
        let total = Double(events.count)
        let withHints = Double(events.filter(\.hasHints).count)
        let highConf = Double(events.filter { $0.confidence == "high_confidence" }.count)
        return [
            "total_searches": total,
            "hint_usage_ratio": withHints / total,
            "high_confidence_ratio": highConf / total
        ]
    }

    /// 清空遥测数据（供测试使用）
    public func clear() {
        events.removeAll()
    }
}
