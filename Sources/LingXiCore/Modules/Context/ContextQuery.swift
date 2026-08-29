import Foundation

/// Pager 的 Provider 无关输入；只取当前任务与最近用户文本，不把完整 Session 无差别送入检索。
public struct ContextQuery: Sendable, Equatable {
    public let text: String
    public let terms: [String]
    public let symbolHints: [String]
    public let symbolHintGroups: [[String]]
    public let symbolHintExtractionMilliseconds: Double
    public let relationHints: [String]

    public init(currentTask: String, recentUserMessages: [String] = []) {
        let queryText = ([currentTask] + recentUserMessages.suffix(2)).joined(separator: "\n")
        text = queryText
        terms = Array(Set(queryText.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })).sorted()
        let clock = ContinuousClock()
        let started = clock.now
        let identifiers = queryText.split { character in
            !(character.isLetter || character.isNumber || character == "_" || character == "." || character == "(")
        }.map(String.init).compactMap(Self.symbolIdentifier)
        var groups: [[String]] = []
        for candidate in identifiers {
            let components = candidate.split(separator: ".").map(String.init)
            guard components.count > 1 else {
                groups.append([candidate])
                continue
            }
            var group = [candidate]
            for end in stride(from: components.count - 1, through: 1, by: -1) {
                group.append(components[0..<end].joined(separator: "."))
            }
            group.append(components[components.count - 1])
            groups.append(group)
        }
        symbolHintGroups = groups
        var seen = Set<String>()
        symbolHints = symbolHintGroups.flatMap { $0 }.filter { seen.insert($0).inserted }
        let duration = started.duration(to: clock.now).components
        symbolHintExtractionMilliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
        relationHints = ["关系", "关联", "依赖", "调用", "relation", "dependency", "depend"].filter { queryText.localizedCaseInsensitiveContains($0) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.terms == rhs.terms && lhs.symbolHints == rhs.symbolHints
    }

    private static func symbolIdentifier(_ token: String) -> String? {
        let isCall = token.hasSuffix("(")
        let candidate = isCall ? String(token.dropLast()) : token
        guard isCall || candidate.contains(where: { $0.isUppercase || $0 == "_" }) || candidate.contains("."),
              candidate.range(of: "^[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*$", options: .regularExpression) != nil
        else { return nil }
        return candidate
    }
}
