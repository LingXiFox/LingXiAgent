import Foundation
import LingXiProtocol

/// LSP 悬停信息回包。
public struct LSPHoverResult: Codable, Sendable, Equatable {
    public let contents: String
    public let range: LSPRange?

    public init(contents: String, range: LSPRange? = nil) {
        self.contents = contents
        self.range = range
    }

    enum CodingKeys: String, CodingKey {
        case contents
        case range
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.range = try container.decodeIfPresent(LSPRange.self, forKey: .range)

        // LSP 规范中 contents 可以是 String, MarkupContent 或 Array
        if let stringVal = try? container.decode(String.self, forKey: .contents) {
            self.contents = stringVal
        } else if let markup = try? container.decode([String: String].self, forKey: .contents), let val = markup["value"] {
            self.contents = val
        } else if let array = try? container.decode([[String: String]].self, forKey: .contents) {
            self.contents = array.compactMap { $0["value"] }.joined(separator: "\n\n")
        } else {
            self.contents = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contents, forKey: .contents)
        try container.encodeIfPresent(range, forKey: .range)
    }
}

/// LSP 代码补全建议项。
public struct LSPCompletionItem: Codable, Sendable, Equatable {
    public let label: String
    public let kind: Int?
    public let detail: String?
    public let documentation: String?
    public let insertText: String?

    public init(label: String, kind: Int? = nil, detail: String? = nil, documentation: String? = nil, insertText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
    }
}

/// LSP 补全列表容器。
public struct LSPCompletionList: Codable, Sendable {
    public let isIncomplete: Bool
    public let items: [LSPCompletionItem]

    public init(isIncomplete: Bool = false, items: [LSPCompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }
}
