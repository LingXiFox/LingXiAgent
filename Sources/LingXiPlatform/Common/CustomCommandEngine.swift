import Foundation
import LingXiProtocol

public enum CustomCommandExecutionType: String, Codable, Sendable {
    case prompt
    case script
}

/// 解析后的自定义 Markdown 命令结构。
public struct ParsedCustomCommand: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let category: String
    public let argumentsHint: String
    public let type: CustomCommandExecutionType
    public let template: String
    public let sourcePath: String
    public let isProjectScope: Bool

    public init(
        name: String,
        description: String,
        category: String = "Custom",
        argumentsHint: String = "",
        type: CustomCommandExecutionType = .prompt,
        template: String,
        sourcePath: String,
        isProjectScope: Bool
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.argumentsHint = argumentsHint
        self.type = type
        self.template = template
        self.sourcePath = sourcePath
        self.isProjectScope = isProjectScope
    }
}

/// 自定义命令 Markdown 解析器与模板展开引擎。
public enum CustomCommandEngine {

    /// 解析 Markdown 文件中的 Frontmatter 与模板正文
    public static func parse(fileURL: URL, isProjectScope: Bool) -> ParsedCustomCommand? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let commandName = fileURL.deletingPathExtension().lastPathComponent

        var description = "Custom command /\(commandName)"
        var category = "Custom"
        var argumentsHint = ""
        var type: CustomCommandExecutionType = .prompt
        var body = content

        // 解析 YAML Frontmatter (--- ... ---)
        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: .newlines)
            var frontmatterLines: [String] = []
            var inFrontmatter = false
            var bodyStartIndex = 0

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" {
                    if !inFrontmatter {
                        inFrontmatter = true
                    } else {
                        inFrontmatter = false
                        bodyStartIndex = index + 1
                        break
                    }
                } else if inFrontmatter {
                    frontmatterLines.append(line)
                }
            }

            for line in frontmatterLines {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
                switch key {
                case "description", "desc":
                    description = value
                case "category":
                    category = value
                case "arguments", "args", "arguments-hint":
                    argumentsHint = value
                case "type":
                    if let parsedType = CustomCommandExecutionType(rawValue: value.lowercased()) {
                        type = parsedType
                    }
                default:
                    break
                }
            }

            if bodyStartIndex < lines.count {
                body = lines[bodyStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                body = ""
            }
        }

        return ParsedCustomCommand(
            name: commandName,
            description: description,
            category: category,
            argumentsHint: argumentsHint,
            type: type,
            template: body,
            sourcePath: fileURL.path,
            isProjectScope: isProjectScope
        )
    }

    /// 执行变量安全插值：$ARGUMENTS, $@, $1..$9, $WORKSPACE, $DATE, $TIME
    public static func interpolate(
        template: String,
        arguments: [String],
        workspaceRoot: String
    ) -> String {
        var result = template
        let allArgs = arguments.joined(separator: " ")

        // 替换全量参数
        result = result.replacingOccurrences(of: "$ARGUMENTS", with: allArgs)
        result = result.replacingOccurrences(of: "$@", with: allArgs)

        // 替换位置参数 $1 ~ $9
        for i in 1...9 {
            let placeholder = "$\(i)"
            let val = (i <= arguments.count) ? arguments[i - 1] : ""
            result = result.replacingOccurrences(of: placeholder, with: val)
        }

        // 替换工作区路径
        result = result.replacingOccurrences(of: "$WORKSPACE", with: workspaceRoot)

        // 替换环境时间
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "$DATE", with: dateFormatter.string(from: Date()))
        dateFormatter.dateFormat = "HH:mm:ss"
        result = result.replacingOccurrences(of: "$TIME", with: dateFormatter.string(from: Date()))

        return result
    }
}
