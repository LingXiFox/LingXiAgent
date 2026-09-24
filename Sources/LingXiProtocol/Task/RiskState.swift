import Foundation

/// 任务执行安全与风险评估状态
public struct RiskState: Sendable, Codable, Equatable, Hashable {
    public let level: String // 'low' | 'medium' | 'high' | 'critical'
    public let flags: [String]

    public init(level: String = "low", flags: [String] = []) {
        self.level = level
        self.flags = flags
    }
}
