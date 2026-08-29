import Foundation

/// 仅提取可由文本确定的 Swift 结构提示；它不是 compiler-resolved call graph。
public struct SwiftReferenceExtractor: Sendable, ReferenceExtractor {
    private static let importRegex = try! NSRegularExpression(pattern: #"^\s*(?:@testable\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var)\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"#)
    private static let conformanceRegex = try! NSRegularExpression(pattern: #"\b(?:class|struct|enum|protocol|actor)\s+[A-Za-z_][A-Za-z0-9_]*(?:<[^>]*>)?\s*:\s*(.+?)(?:\{|\s+where|$)"#)
    private static let extensionRegex = try! NSRegularExpression(pattern: #"\bextension\s+([A-Za-z_][A-Za-z0-9_.]*)"#)
    private static let parameterTypeRegex = try! NSRegularExpression(pattern: #":\s*([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)?)"#)
    private static let returnTypeRegex = try! NSRegularExpression(pattern: #"->\s*([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)?)"#)
    private static let memberCallRegex = try! NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    public init() {}

    public func extract(projectRoot: String, path: String, pages: [ContextPage], symbols: [Symbol]) -> [ProjectReference] {
        let lines = SwiftSymbolExtractor.lexicalLines(pages.map(\.content).joined())
        var references: [ProjectReference] = []
        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let pageID = pages.first { $0.startLine <= lineNumber && lineNumber <= $0.endLine }?.id ?? ""
            let source = symbols.filter { $0.line <= lineNumber }.max { $0.line < $1.line }?.id
            func add(_ target: String, _ kind: ReferenceKind, receiver: String? = nil) {
                guard !target.isEmpty, target != "Self" else { return }
                references.append(ProjectReference(projectRoot: projectRoot, projectID: pages.first?.projectID, sourceFileID: pages.first?.fileID, sourceSymbolID: source, sourcePageID: pageID, sourcePath: path, sourceLine: lineNumber, targetName: target, kind: kind, resolutionQuality: receiver == nil ? .unresolved : .receiverHint, receiverHint: receiver))
            }
            if line.contains("import "), let importName = capture(Self.importRegex, in: line) { add(importName, .import) }
            if line.contains(":"), let declaration = capture(Self.conformanceRegex, in: line) {
                let targets = declaration.split(separator: ",").map { typeName(String($0)) }.filter { !$0.isEmpty }
                for (index, target) in targets.enumerated() { add(target, line.contains("class ") && index == 0 ? .inheritance : .protocolConformance) }
            }
            if line.contains("extension "), let target = capture(Self.extensionRegex, in: line) { add(target, .extensionTarget) }
            if line.contains(":") { for target in captures(Self.parameterTypeRegex, in: line) { add(target, .typeReference) } }
            if line.contains("->") { for target in captures(Self.returnTypeRegex, in: line) { add(target, .typeReference) } }
            if line.contains("."), line.contains("(") { for match in capturesPair(Self.memberCallRegex, in: line) {
                let name = match.0.first?.isUppercase == true ? "\(match.0).\(match.1)" : match.1
                add(name, .functionReference, receiver: match.0)
            } }
        }
        return Array(Dictionary(references.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }
    }

    private func typeName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? "" }
    private func capture(_ regex: NSRegularExpression, in text: String) -> String? { captures(regex, in: text).first }
    private func captures(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }; return String(text[range]) }
    }
    private func capturesPair(_ regex: NSRegularExpression, in text: String) -> [(String, String)] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[first]), String(text[second]))
        }
    }
}
