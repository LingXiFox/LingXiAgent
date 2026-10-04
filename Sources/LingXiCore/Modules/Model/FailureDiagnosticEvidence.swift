import Foundation
import LingXiProtocol

/// Bounded evidence selected by diagnostic meaning, rather than an output prefix.
enum FailureDiagnosticEvidence {
    static func render(_ result: ToolResult, maxCharacters: Int) -> String {
        // A normalized failure can cross projection boundaries more than once.
        // Read its evidence field, rather than treating escaped JSON as one line.
        let encoded = result.content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let content = encoded?["failureEvidence"] as? String ?? result.content
        let streams = [result.diagnostics?.stderr ?? "", result.diagnostics?.stdout ?? "", content]
        let lines = streams.flatMap { $0.components(separatedBy: .newlines) }
        let signature = try? NSRegularExpression(pattern: #"(?:\b[\w.]+(?:Error|Exception)\b\s*:|\b(?:error|fatal error|panic)\s*:|Assertion failed|Segmentation fault)"#, options: .caseInsensitive)
        var signatures: [String] = [], tests: [String] = [], locations: [String] = []
        for (index, line) in lines.enumerated() {
            if signature?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                signatures.append(line)
                // Exception context frequently carries the expression that failed.
                if index > 0 { locations.append(contentsOf: lines[max(0, index - 2)..<index]) }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("FAIL:") || trimmed.hasPrefix("ERROR:") || trimmed.hasPrefix("FAILED ") || trimmed.contains("--- FAIL:") { tests.append(line) }
            if trimmed.hasPrefix("File \"") || trimmed.contains(".py:") || trimmed.contains(".swift:") || trimmed.contains(".rs:") || trimmed.contains(".js:") { locations.append(line) }
        }
        var seen = Set<String>(), selected: [String] = []
        var remaining = max(0, maxCharacters)
        // Reserve a tail even for diagnostics with unfamiliar exception syntax.
        let tailBudget = min(remaining / 4, 1000)
        for line in signatures + tests + locations {
            guard !line.isEmpty, seen.insert(line).inserted else { continue }
            let cost = line.count + 1
            guard cost <= remaining - tailBudget else { continue }
            selected.append(line); remaining -= cost
        }
        if let tail = streams.first(where: { !$0.isEmpty }) {
            selected.append("[output tail]\n" + String(tail.suffix(max(0, remaining - 15))))
        }
        return selected.joined(separator: "\n")
    }
}
