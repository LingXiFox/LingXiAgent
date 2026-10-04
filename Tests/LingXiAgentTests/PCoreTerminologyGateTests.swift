import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// Guards the canonical P/E architecture across executable code, schema, and documentation.
struct PCoreTerminologyGateTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Retired tier identifiers cannot return in code, interfaces, or architecture documents")
    func canonicalTerminologyOnly() throws {
        let pattern = try NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])l[1-3](?![0-9])|L[1-3](?=[A-Z])"#)
        var offenders: [String] = []
        for directory in ["Sources", "Apps", "Docs", "Server/agent-site/public"] {
            let root = Self.repoRoot.appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
            for case let file as URL in walker where file.lastPathComponent != "package-lock.json" && !file.pathComponents.contains("node_modules") && ["swift", "json", "js", "md", "html", "drawio", "tex"].contains(file.pathExtension) {
                let source = try String(contentsOf: file, encoding: .utf8)
                    .replacingOccurrences(of: #"data:[^;\s]+;base64,[A-Za-z0-9+/=]+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\bd=[\"\'][^\"\']+[\"\']"#, with: "", options: .regularExpression)
                for line in source.split(separator: "\n") {
                    let text = String(line)
                    if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        offenders.append("\(file.lastPathComponent): \(text.prefix(160))")
                    }
                }
            }
        }
        let readme = try String(contentsOf: Self.repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(pattern.firstMatch(in: readme, range: NSRange(readme.startIndex..., in: readme)) == nil)
        #expect(offenders.isEmpty, "Use P/E state or the actual index/cache responsibility: \(offenders)")
    }

    @Test("P-Core keeps exactly the three frozen regions")
    func pCorePartitionIsFrozen() {
        #expect(PCoreRegion.allCases == [.stablePrefix, .growingContext, .eCoreIndex])
        // 每个 ContextSource 都必须能归入某个区域：归不进去就等于长出第四种常驻内容。
        for source in [ContextSource.system, .userMessage, .assistantMessage, .toolCall, .toolResult, .observation, .projectPage, .derivedPage] {
            switch source.pCoreRegion {
            case .stablePrefix, .growingContext, .eCoreIndex: break
            }
        }
        #expect(ContextSource.system.pCoreRegion == .stablePrefix)
        #expect(ContextSource.userMessage.pCoreRegion == .growingContext)
        #expect(ContextSource.toolResult.pCoreRegion == .growingContext)
        #expect(ContextSource.derivedPage.pCoreRegion == .eCoreIndex)
        #expect(ContextSource.projectPage.pCoreRegion == .eCoreIndex)
    }

    @Test("The authoritative policy wire keys describe only P-Core and E-Core budgets")
    func canonicalBudgetWireKeys() throws {
        let policy = EffectiveContextPolicy(pCoreTarget: 100, pCoreSoftLimit: 110, pCoreHardLimit: 120,
            eCoreStorageBudget: 300, eCoreRecallBudget: 200)
        let data = try JSONEncoder().encode(policy)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["addressableBudget", "modelWindow", "economicThreshold", "reserve",
            "pCoreTarget", "pCoreSoftLimit", "pCoreHardLimit", "eCoreStorageBudget", "eCoreRecallBudget",
            "eCorePressureThreshold", "eCoreEnabled"])
        #expect(try JSONDecoder().decode(EffectiveContextPolicy.self, from: data) == policy)
    }

    /// 契约第七节：Branch Prediction 不进 eviction 公式。E-Core Heat 同理（第六节）。
    @Test("Eviction signals contain neither prediction nor heat inputs")
    func evictionSignalsCarryNoPredictionOrHeatInput() {
        let fields = ContextRetentionSignals(
            taskAffinity: 0.5,
            dependencyWeight: 0.5,
            deltaTurn: 1,
            relevance: 0.5,
            accessCount: 1,
            activeFileAffinity: 0.5,
            explicitReuse: 0.5,
            reconstructability: 0.5,
            tokenCost: 100
        )
        let names = Set(Swift.Mirror(reflecting: fields).children.compactMap { $0.label })
        #expect(names == [
            "taskAffinity", "dependencyWeight", "deltaTurn", "relevance", "accessCount",
            "activeFileAffinity", "explicitReuse", "reconstructability", "tokenCost",
        ], "第八个价值特征 + tokenCost 之外不得再接任何信号源：\(names.sorted())")

        let featureNames = Set(Swift.Mirror(reflecting: ContextValueScorer.estimate(signals: fields, pCoreTarget: 1_000).features).children.compactMap { $0.label })
        #expect(featureNames.isSubset(of: [
            "taskAffinity", "dependencyWeight", "recency", "relevance", "frequency",
            "activeFileAffinity", "explicitReuse", "irreplaceability", "normalizedTokenCost",
        ]))
    }
}
