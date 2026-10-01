import Foundation
import Testing
@testable import LingXiCore

/// §23 of the closure contract: a machine-checkable feature inventory.
///
/// The manifest exists because "is this feature actually closed?" was being answered from memory.
/// Each row states the layer-by-layer path a feature takes and cites the source lines that prove
/// it; `FeatureCoverageManifestTests` reads the file and checks the citations against the real
/// sources, so a row that stops being true fails the build instead of staying in a document.
///
/// Two things are deliberately not asserted. An empty `status` is required only of features that
/// claim closure — features still open say so, and the point of that is that they cannot be
/// mistaken for finished. And the classification decides whether a GUI surface is *owed*: an
/// internal-only capability needs no button, while an unsupported one must not have a fake one.
@Suite("Feature coverage manifest", .serialized)
struct FeatureCoverageManifestTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let manifestPath = "Docs/frontend-v2/feature-coverage.json"

    private struct Feature: Decodable {
        let feature: String
        let classification: String
        let core: String?
        let protocolNames: [String]?
        let client: String?
        let application: String?
        let guiSurface: String?
        let capability: String?
        let tests: [String]
        let status: [String]
        let evidence: [Evidence]

        enum CodingKeys: String, CodingKey {
            case feature, classification, core, client, application, capability, tests, status, evidence
            case protocolNames = "protocol"
            case guiSurface
        }
    }

    private struct Evidence: Decodable {
        let file: String
        let contains: String
    }

    private static func manifest() throws -> [Feature] {
        let url = root.appendingPathComponent(manifestPath)
        let data = try Data(contentsOf: url)
        struct Wrapper: Decodable { let features: [Feature] }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
        return decoded.features
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static let allowedClassifications = [
        "user-facing", "observability-facing", "internal-only", "unsupported", "deprecated",
    ]

    /// §23's seven defect classes. A row may name any of them while the work is open; naming one
    /// is what keeps it from being quietly forgotten, and an empty list is a claim, not a default.
    private static let allowedStatuses: Set<String> = [
        "GUI_DEAD_CONTROL", "CORE_USER_FEATURE_HIDDEN", "PROTOCOL_FAKE_SUCCESS",
        "TRANSPORT_MISSING", "CAPABILITY_FALSE_ADVERTISEMENT", "SETTINGS_CONFIG_DRIFT",
        "APPLICATION_STATE_ONLY_MUTATION",
    ]

    @Test("the manifest parses and classifies every feature")
    func manifestIsValid() throws {
        let features = try Self.manifest()
        #expect(features.count >= 10, "清单只覆盖 \(features.count) 项，明显不完整")
        let names = features.map(\.feature)
        #expect(Set(names).count == names.count, "有重复的 feature 名")
        for feature in features {
            #expect(Self.allowedClassifications.contains(feature.classification),
                    "\(feature.feature) 的分类「\(feature.classification)」不在许可集合里")
            for status in feature.status {
                #expect(Self.allowedStatuses.contains(status),
                        "\(feature.feature) 写了清单之外的状态 \(status)")
            }
        }
    }

    /// The whole value of the file: every cited line must exist. A row kept honest by nobody
    /// re-reading it is the failure mode this test removes.
    @Test("every cited piece of evidence is present in the sources")
    func evidenceHolds() throws {
        var cache: [String: String] = [:]
        func read(_ path: String) throws -> String {
            if let hit = cache[path] { return hit }
            let url = Self.root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("清单引用了不存在的文件：\(path)")
                return ""
            }
            let text = try Self.source(path)
            cache[path] = text
            return text
        }
        for feature in try Self.manifest() {
            #expect(!feature.evidence.isEmpty,
                    "\(feature.feature) 没有任何证据引用，等于没有检查")
            for item in feature.evidence {
                let text = try read(item.file)
                #expect(text.contains(item.contains),
                        "\(feature.feature)：\(item.file) 不再包含「\(item.contains)」，这一行已经不成立")
            }
        }
    }

    @Test("named tests exist")
    func testsAreNamed() throws {
        let corpus = try ["Tests/LingXiAgentTests", "ContractTests"].reduce(into: "") { partial, dir in
            let base = Self.root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return }
            for case let url as URL in walker where url.pathExtension == "swift" {
                partial += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        for feature in try Self.manifest() where feature.classification != "internal-only" {
            for test in feature.tests {
                #expect(corpus.contains("struct \(test)") || corpus.contains("class \(test)"),
                        "\(feature.feature) 声称由 \(test) 覆盖，但测试目录里没有这个类型")
            }
        }
    }

    /// Classification decides what the GUI owes. A user-facing capability hidden in Core is
    /// CORE_USER_FEATURE_HIDDEN; an internal one dressed up as a button is §22's dead control.
    @Test("classification matches whether a surface is owed")
    func classificationDrivesSurface() throws {
        for feature in try Self.manifest() {
            switch feature.classification {
            case "user-facing", "observability-facing":
                let hasSurface = feature.guiSurface != nil && feature.guiSurface != "none yet"
                if !hasSurface {
                    #expect(feature.status.contains("CORE_USER_FEATURE_HIDDEN"),
                            "\(feature.feature) 是 \(feature.classification) 却没有界面，也没登记为未完成")
                }
            case "internal-only", "unsupported", "deprecated":
                let advertised = feature.protocolNames != nil && feature.capability != nil
                if advertised {
                    Issue.record("\(feature.feature) 分类为 \(feature.classification)，却同时声明了协议面与能力广播")
                }
            default:
                Issue.record("未知分类 \(feature.classification)")
            }
        }
    }

    /// The outstanding list, printed rather than hidden. CI_GATE is decided from this, so an open
    /// row has to appear in the closure report instead of passing silently.
    @Test("open statuses are reported, not swallowed")
    func outstandingIsVisible() throws {
        let open = try Self.manifest()
            .filter { !$0.status.isEmpty }
            .map { "\($0.feature): \($0.status.sorted().joined(separator: ", "))" }
        print("FEATURE COVERAGE — outstanding:")
        for line in open { print("  \(line)") }
        print("FEATURE COVERAGE — closed: \(try Self.manifest().filter { $0.status.isEmpty }.count)")
    }
}
