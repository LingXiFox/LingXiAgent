public struct SwiftSymbolExtractor: Sendable {
    public init() {}

    public func extract(projectRoot: String, path: String, pageID: String, source: String) -> [Symbol] {
        var symbols: [Symbol] = []
        var stack: [(qualifiedName: String, closingDepth: Int)] = []
        var depth = 0

        for (offset, line) in Self.lexicalLines(source).enumerated() {
            var start = line.startIndex
            while start < line.endIndex {
                while start < line.endIndex, line[start].isWhitespace { start = line.index(after: start) }
                guard start < line.endIndex, line[start] == "}" else { break }
                depth = max(0, depth - 1)
                start = line.index(after: start)
                stack.removeAll { $0.closingDepth > depth }
            }

            let body = String(line[start...])
            let openingBraces = body.reduce(into: 0) { count, character in count += character == "{" ? 1 : 0 }
            let closingBraces = body.reduce(into: 0) { count, character in count += character == "}" ? 1 : 0 }
            if let declaration = declaration(in: body) {
                let parent = stack.last?.qualifiedName
                let qualifiedName: String
                if declaration.kind == .extension {
                    qualifiedName = parent.map { "\($0).\(declaration.name)" } ?? declaration.name
                } else {
                    qualifiedName = parent.map { "\($0).\(declaration.name)" } ?? declaration.name
                }
                symbols.append(Symbol(
                    projectRoot: projectRoot,
                    name: declaration.name,
                    qualifiedName: qualifiedName,
                    kind: declaration.kind,
                    path: path,
                    pageID: pageID,
                    line: offset + 1
                ))
                if openingBraces > 0 {
                    stack.append((qualifiedName, depth + openingBraces))
                }
            }

            depth = max(0, depth + openingBraces - closingBraces)
            stack.removeAll { $0.closingDepth > depth }
        }
        return symbols
    }

    public func extract(projectRoot: String, path: String, pages: [ContextPage]) -> [Symbol] {
        let source = pages.map(\.content).joined()
        return extract(projectRoot: projectRoot, path: path, pageID: "", source: source).compactMap { symbol in
            guard let page = pages.first(where: { $0.startLine <= symbol.line && symbol.line <= $0.endLine }) else { return nil }
            return Symbol(
                projectRoot: symbol.projectRoot,
                name: symbol.name,
                qualifiedName: symbol.qualifiedName,
                kind: symbol.kind,
                path: symbol.path,
                pageID: page.id,
                line: symbol.line
            )
        }
    }

    private func declaration(in line: String) -> (kind: SymbolKind, name: String)? {
        var index = line.startIndex
        while index < line.endIndex {
            guard isIdentifierStart(line[index]) else {
                index = line.index(after: index)
                continue
            }
            let wordStart = index
            index = line.index(after: index)
            while index < line.endIndex, isIdentifierPart(line[index]) { index = line.index(after: index) }
            let word = String(line[wordStart..<index])
            guard let kind = SymbolKind(rawValue: word) else { continue }
            if kind == .class, nextWord(in: line, after: index) == "func" { continue }
            let name = name(after: index, for: kind, in: line)
            guard !name.isEmpty else { continue }
            return (kind, name)
        }
        return nil
    }

    private func name(after keyword: String.Index, for kind: SymbolKind, in line: String) -> String {
        if kind == SymbolKind.`init` { return "init" }
        var index = keyword
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        let start = index
        while index < line.endIndex, isIdentifierPart(line[index]) || line[index] == "." {
            index = line.index(after: index)
        }
        return String(line[start..<index])
    }

    private func nextWord(in line: String, after index: String.Index) -> String? {
        var index = index
        while index < line.endIndex, !isIdentifierStart(line[index]) { index = line.index(after: index) }
        guard index < line.endIndex else { return nil }
        let start = index
        while index < line.endIndex, isIdentifierPart(line[index]) { index = line.index(after: index) }
        return String(line[start..<index])
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    static func lexicalLines(_ source: String) -> [String] {
        var inBlockComment = false
        var inString = false
        var multilineString = false
        var escaped = false

        return source.components(separatedBy: .newlines).map { sourceLine in
            let characters = Array(sourceLine)
            var output: [Character] = []
            var index = 0
            while index < characters.count {
                let character = characters[index]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let isTripleQuote = character == "\"" && index + 2 < characters.count && characters[index + 1] == "\"" && characters[index + 2] == "\""

                if inBlockComment {
                    output.append(" ")
                    if character == "*", next == "/" {
                        output.append(" ")
                        index += 2
                        inBlockComment = false
                    } else {
                        index += 1
                    }
                    continue
                }
                if inString {
                    if multilineString, isTripleQuote {
                        output += [" ", " ", " "]
                        index += 3
                        inString = false
                        multilineString = false
                    } else {
                        output.append(" ")
                        if !multilineString {
                            if escaped { escaped = false }
                            else if character == "\\" { escaped = true }
                            else if character == "\"" { inString = false }
                        }
                        index += 1
                    }
                    continue
                }
                if character == "/", next == "/" {
                    output.append(contentsOf: repeatElement(" ", count: characters.count - index))
                    break
                }
                if character == "/", next == "*" {
                    output += [" ", " "]
                    index += 2
                    inBlockComment = true
                    continue
                }
                if isTripleQuote {
                    output += [" ", " ", " "]
                    index += 3
                    inString = true
                    multilineString = true
                    continue
                }
                if character == "\"" {
                    output.append(" ")
                    index += 1
                    inString = true
                    multilineString = false
                    escaped = false
                    continue
                }
                output.append(character)
                index += 1
            }
            if inString && !multilineString { inString = false }
            return String(output)
        }
    }
}

extension SwiftSymbolExtractor: SymbolExtractor {}
