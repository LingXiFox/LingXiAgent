import Foundation

/// 任务成功判定标准
public struct SuccessCriterion: Sendable, Codable, Equatable, Hashable {
    public let criterionID: String
    public let description: String
    public let oracleKind: String
    public var isSatisfied: Bool

    public init(
        criterionID: String = UUID().uuidString,
        description: String,
        oracleKind: String = "generic",
        isSatisfied: Bool = false
    ) {
        self.criterionID = criterionID
        self.description = description
        self.oracleKind = oracleKind
        self.isSatisfied = isSatisfied
    }
}
