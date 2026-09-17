import Foundation

/// 检索分词协议
public protocol RetrievalTokenizer: Sendable {
    func tokenize(_ text: String) -> [String]
    func termFrequencies(_ text: String) -> [String: Int]
}

/// 基础空白与标点分词器（用于 Ablation Test 对照基准）
public struct SimpleWhitespaceTokenizer: RetrievalTokenizer {
    public init() {}

    public func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public func termFrequencies(_ text: String) -> [String: Int] {
        var tf: [String: Int] = [:]
        for t in tokenize(text) {
            tf[t, default: 0] += 1
        }
        return tf
    }
}

/// 代码感知与轻量确定性分词器 (CodeAwareTokenizer)
/// 专为源码、错误日志、路径及文档设计，支持 Swift 驼峰命名、下划线、路径和 Unicode/中文分词
public struct CodeAwareTokenizer: RetrievalTokenizer, Sendable {
    public init() {}

    /// 对输入文本进行代码感知的词元化解析
    public func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []

        // 1. 初筛：基于常见文本边界提取基础原始候选片段
        let rawSegments = extractSegments(from: text)

        for segment in rawSegments {
            let lower = segment.lowercased()

            // 1.1 保留原始整体小写 token（例如 context_recall, ecoreobjectstore, actor-isolated）
            tokens.append(lower)

            // 1.2 处理点号分割（例如 CoreError.toolArgumentInvalid -> CoreError, toolArgumentInvalid）
            if segment.contains(".") {
                let dotParts = segment.split(separator: ".").map(String.init)
                for part in dotParts where !part.isEmpty {
                    tokens.append(part.lowercased())
                    tokens.append(contentsOf: splitSubwords(part))
                }
            }

            // 1.3 处理斜杠路径分割（例如 Sources/LingXiCore/Modules/Context）
            if segment.contains("/") {
                let pathParts = segment.split(separator: "/").map(String.init)
                for part in pathParts where !part.isEmpty {
                    tokens.append(part.lowercased())
                    tokens.append(contentsOf: splitSubwords(part))
                }
            }

            // 1.4 处理连字符（例如 actor-isolated, EXC_BAD_ACCESS）
            if segment.contains("-") {
                let dashParts = segment.split(separator: "-").map(String.init)
                for part in dashParts where !part.isEmpty {
                    tokens.append(part.lowercased())
                    tokens.append(contentsOf: splitSubwords(part))
                }
            }

            // 1.5 处理 snake_case 下划线
            if segment.contains("_") {
                let snakeParts = segment.split(separator: "_").map(String.init)
                for part in snakeParts where !part.isEmpty {
                    tokens.append(part.lowercased())
                    tokens.append(contentsOf: splitSubwords(part))
                }
            }

            // 1.6 处理 CamelCase / PascalCase 驼峰切分
            tokens.append(contentsOf: splitSubwords(segment))

            // 1.7 处理 CJK / 中文字符
            tokens.append(contentsOf: extractCJKTokens(from: segment))
        }

        // 去除空字符串并按原顺序稳定去重（保留词频或布尔词元）
        var seen = Set<String>()
        var result: [String] = []
        for t in tokens {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !seen.contains(clean) {
                seen.insert(clean)
                result.append(clean)
            }
        }

        return result
    }

    /// 提取词频序列（用于计算 TF）
    public func termFrequencies(_ text: String) -> [String: Int] {
        guard !text.isEmpty else { return [:] }
        let rawSegments = extractSegments(from: text)
        var tf: [String: Int] = [:]

        for segment in rawSegments {
            var derived: [String] = [segment.lowercased()]

            if segment.contains(".") {
                for p in segment.split(separator: ".") {
                    derived.append(p.lowercased())
                    derived.append(contentsOf: splitSubwords(String(p)))
                }
            }
            if segment.contains("/") {
                for p in segment.split(separator: "/") {
                    derived.append(p.lowercased())
                    derived.append(contentsOf: splitSubwords(String(p)))
                }
            }
            if segment.contains("-") {
                for p in segment.split(separator: "-") {
                    derived.append(p.lowercased())
                    derived.append(contentsOf: splitSubwords(String(p)))
                }
            }
            if segment.contains("_") {
                for p in segment.split(separator: "_") {
                    derived.append(p.lowercased())
                    derived.append(contentsOf: splitSubwords(String(p)))
                }
            }

            derived.append(contentsOf: splitSubwords(segment))
            derived.append(contentsOf: extractCJKTokens(from: segment))

            for term in derived where !term.isEmpty {
                tf[term, default: 0] += 1
            }
        }

        return tf
    }

    // MARK: - Private Helpers

    /// 提取基础词段（由连续的字母、数字、下划线、短横线、点、斜杠组成，或者连续的 CJK 字符）
    private func extractSegments(from text: String) -> [String] {
        var segments: [String] = []
        var current = ""

        for char in text {
            if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." || char == "/" || isCJK(char) {
                current.append(char)
            } else {
                if !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }

        return segments
    }

    /// 驼峰与子词拆分（如 ECoreObjectStore -> ecore, object, store）
    private func splitSubwords(_ word: String) -> [String] {
        // 如果包含点号、斜杠、连字符或下划线，已在外层拆分，此处只处理纯字母数字段
        let clean = word.filter { $0.isLetter || $0.isNumber }
        guard clean.count >= 2 else {
            return clean.isEmpty ? [] : [clean.lowercased()]
        }

        var parts: [String] = []
        var currentPart = ""
        let chars = Array(clean)

        for i in 0..<chars.count {
            let ch = chars[i]
            if ch.isUppercase {
                let prevIsUpper = (i > 0) && chars[i - 1].isUppercase
                let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                let prevIsLower = (i > 0) && chars[i - 1].isLowercase

                if prevIsLower {
                    // lower -> UPPER (如 record|Projection)
                    if !currentPart.isEmpty {
                        parts.append(currentPart.lowercased())
                    }
                    currentPart = String(ch)
                } else if prevIsUpper && nextIsLower {
                    // UPPER -> UpperLower (如 ECore|Object 或 XML|Parser)
                    // 如果 currentPart 已经积累了缩写 (例如 "ECore" 遇到 'O' 之前是 "ECore")
                    if !currentPart.isEmpty {
                        parts.append(currentPart.lowercased())
                    }
                    currentPart = String(ch)
                } else {
                    currentPart.append(ch)
                }
            } else {
                currentPart.append(ch)
            }
        }

        if !currentPart.isEmpty {
            parts.append(currentPart.lowercased())
        }

        // 针对 ECore 这种单大写+驼峰的特殊容错：
        // 如果第一部分是 "e" 且第二部分是 "core"，合并一份 "ecore"
        var refined: [String] = []
        for p in parts {
            refined.append(p)
        }
        if parts.count >= 2 && parts[0] == "e" && parts[1] == "core" {
            refined.append("ecore")
        }

        return refined
    }

    /// 中文/CJK 字符单字与二元组（Bi-gram）提取
    private func extractCJKTokens(from text: String) -> [String] {
        let cjkChars = text.filter { isCJK($0) }
        guard !cjkChars.isEmpty else { return [] }

        var tokens: [String] = []
        let arr = Array(cjkChars)

        // 单字
        for ch in arr {
            tokens.append(String(ch))
        }

        // 二元组（Bi-gram）增强词组相关性
        if arr.count >= 2 {
            for i in 0..<(arr.count - 1) {
                let bi = String([arr[i], arr[i + 1]])
                tokens.append(bi)
            }
        }

        return tokens
    }

    private func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let val = scalar.value
        // CJK Unified Ideographs, Extension A, CJK Compatibility Ideographs
        return (val >= 0x4E00 && val <= 0x9FFF) ||
               (val >= 0x3400 && val <= 0x4DBF) ||
               (val >= 0xF900 && val <= 0xFAFF)
    }
}
