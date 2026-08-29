import Foundation

public struct PageCandidate: Sendable, Equatable {
    public let page: ContextPage
    public let score: Int
    public let symbolScore: Int
    public let textScore: Int
    public let authorityScore: Int

    public init(page: ContextPage, score: Int, symbolScore: Int = 0, textScore: Int = 0, authorityScore: Int = 0) {
        self.page = page
        self.score = score
        self.symbolScore = symbolScore
        self.textScore = textScore
        self.authorityScore = authorityScore
    }
}

/// 符号与文本命中在同一候选序列中排序，Pager 无需区分检索来源。
public struct ContextPageRankingPolicy: Sendable {
    public let maximumSymbolContribution: Int

    public init(maximumSymbolContribution: Int = 1_200) {
        self.maximumSymbolContribution = max(0, maximumSymbolContribution)
    }

    public func rank(pages: [ContextPage], query: ContextQuery, symbolScoresByPageID: [String: Int]) -> [PageCandidate] {
        let lexicalTokens = query.terms
        return pages.compactMap { page in
            let symbolScore = min(maximumSymbolContribution, symbolScoresByPageID[page.id, default: 0])
            let pathScore = pathScore(page, tokens: lexicalTokens)
            let headingScore = headingScore(page, tokens: lexicalTokens)
            let lexicalScore = lexicalScore(page, tokens: lexicalTokens)
            let textScore = pathScore + headingScore + lexicalScore
            let authorityScore = sourceAuthority(for: page.sourceType)
            let score = symbolScore + textScore + authorityScore
            return symbolScore == 0 && textScore == 0 ? nil : PageCandidate(page: page, score: score, symbolScore: symbolScore, textScore: textScore, authorityScore: authorityScore)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.page.path != $1.page.path { return $0.page.path < $1.page.path }
            if $0.page.startLine != $1.page.startLine { return $0.page.startLine < $1.page.startLine }
            return $0.page.endLine < $1.page.endLine
        }
    }

    private func pathScore(_ page: ContextPage, tokens: [String]) -> Int {
        let path = page.path.lowercased()
        let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return tokens.reduce(0) { score, token in
            if path == token || path.hasSuffix("/\(token)") { return score + 700 }
            if filename.contains(token) { return score + 600 }
            return score
        }
    }

    private func headingScore(_ page: ContextPage, tokens: [String]) -> Int {
        let heading = page.metadata.heading?.lowercased() ?? ""
        return tokens.reduce(0) { $0 + (heading.contains($1) ? 300 : 0) }
    }

    private func lexicalScore(_ page: ContextPage, tokens: [String]) -> Int {
        let content = page.content.lowercased()
        return tokens.reduce(0) { score, token in
            var occurrences = 0
            var range = content.startIndex..<content.endIndex
            while let match = content.range(of: token, range: range) {
                occurrences += 1
                range = match.upperBound..<content.endIndex
            }
            return score + occurrences
        }
    }

    private func sourceAuthority(for sourceType: ContextPageSourceType) -> Int {
        switch sourceType {
        case .sourceFile: 400
        case .test: 300
        case .configuration: 250
        case .projectMetadata: 150
        case .documentation: 0
        case .referenceDocumentation: -200
        case .researchArchive: -300
        }
    }
}
