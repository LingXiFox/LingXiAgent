import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// 契约第十节：L1/L2/L3 不再具有架构语义，并且不得再创造新的 L 类型。
/// 这个门禁是源码级的，因为它要防的不是某一次改错，而是后来人顺手再长出一层。
struct PCoreTerminologyGateTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 契约第十一节的兼容周期允许的例外：它们只是旧配置键的解码垫片，不参与任何生命周期。
    private static let allowedLegacyNames: Set<String> = [
        "ContextCacheL1Configuration",
        "ContextCacheL2Configuration",
        "ContextCacheL3Configuration",
    ]

    private static let declarationPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:@[A-Za-z0-9_]+(?:\([^\)]*\))?\s*)*(?:public|internal|private|fileprivate|open)?\s*(?:final\s+|indirect\s+|static\s+)*(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z0-9_]+)"#
    )

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.allObjects.compactMap { candidate in
            guard let url = candidate as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("No new L1/L2/L3 architecture types exist outside the sanctioned legacy config shims")
    func legacyLayerTypesStayRetired() throws {
        var offenders: [String] = []
        for subdirectory in ["Sources", "Apps"] {
            for file in Self.swiftFiles(under: Self.repoRoot.appendingPathComponent(subdirectory)) {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let range = NSRange(source.startIndex..., in: source)
                for match in Self.declarationPattern.matches(in: source, range: range) {
                    guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                    let name = String(source[nameRange])
                    guard name.contains("L1") || name.contains("L2") || name.contains("L3") else { continue }
                    if Self.allowedLegacyNames.contains(name) { continue }
                    offenders.append("\(file.lastPathComponent): \(name)")
                }
            }
        }
        #expect(offenders.isEmpty, "L1/L2/L3 类型已退出架构语义，新增项必须按真实职责命名：\(offenders)")
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

    @Test("The authoritative budget fields are P/E named and the L aliases are pure compatibility reads")
    func budgetPolicyAliasesPointAtPENames() {
        let policy = EffectiveContextPolicy(
            pCoreTarget: 100,
            pCoreSoftLimit: 110,
            pCoreHardLimit: 120,
            eCoreStorageBudget: 300,
            eCoreRecallBudget: 200
        )
        #expect(policy.l1Target == policy.pCoreTarget)
        #expect(policy.l1SoftLimit == policy.pCoreSoftLimit)
        #expect(policy.l1HardLimit == policy.pCoreHardLimit)
        #expect(policy.l2Max == policy.eCoreRecallBudget)
        #expect(policy.l3Capacity == policy.eCoreStorageBudget)
        #expect(policy.l3Enabled == policy.eCoreEnabled)
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
