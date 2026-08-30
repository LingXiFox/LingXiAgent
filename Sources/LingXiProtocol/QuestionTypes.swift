public struct QuestionID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Core 请求客户端回答的问题。选项下标在 Reply 中从零开始。
public struct QuestionRequest: Sendable, Equatable, Codable {
    public let questionID: QuestionID
    public let question: String
    public let options: [String]
    public let allowsMultiple: Bool
    public let allowsFreeText: Bool
    public let originSessionID: SessionID?
    public let originRunID: AgentRunID?
    public let rootSessionID: SessionID?
    public let parentSessionID: SessionID?

    public init(
        questionID: QuestionID,
        question: String,
        options: [String] = [],
        allowsMultiple: Bool = false,
        allowsFreeText: Bool = true,
        originSessionID: SessionID? = nil,
        originRunID: AgentRunID? = nil,
        rootSessionID: SessionID? = nil,
        parentSessionID: SessionID? = nil
    ) {
        self.questionID = questionID
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
        self.originSessionID = originSessionID
        self.originRunID = originRunID
        self.rootSessionID = rootSessionID
        self.parentSessionID = parentSessionID
    }
}

/// 客户端对 QuestionRequest 的答复。取消时其余字段必须为空。
public struct QuestionReply: Sendable, Equatable, Codable {
    public let questionID: QuestionID
    public let selectedOptionIndices: [Int]
    public let text: String?
    public let cancelled: Bool

    public init(
        questionID: QuestionID,
        selectedOptionIndices: [Int] = [],
        text: String? = nil,
        cancelled: Bool = false
    ) {
        self.questionID = questionID
        self.selectedOptionIndices = selectedOptionIndices
        self.text = text
        self.cancelled = cancelled
    }
}
