import Foundation

/// Pager 的 Provider 无关输入；只取当前任务与最近用户文本，不把完整 Session 无差别送入检索。
public struct ContextQuery: Sendable, Equatable {
    public let text: String
    public let terms: [String]

    public init(currentTask: String, recentUserMessages: [String] = []) {
        text = ([currentTask] + recentUserMessages.suffix(2)).joined(separator: "\n")
        terms = Array(Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })).sorted()
    }
}
