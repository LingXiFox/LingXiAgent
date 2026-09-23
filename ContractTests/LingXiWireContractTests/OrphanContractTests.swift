import Foundation
import Testing
import LingXiProtocol

/// Guards against dead/orphan types lingering in `LingXiProtocol`.
/// Every declared public struct/enum/class/protocol must have at least one producer or
/// consumer across Sources/, unless explicitly cataloged in the reservation allow-list.
struct OrphanContractTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LingXiWireContractTests
            .deletingLastPathComponent() // ContractTests
            .deletingLastPathComponent() // Repo root
    }

    /// Intentional reservations for upcoming milestones (e.g. V1.2 Goal, V1.3 Router, ACP & OAuth).
    private static let intentionalReservations: Set<String> = [
        "ProtocolFeature", // Used dynamically in feature negotiation
        "ACPInitializeParams", // ACP external client handshake wire contract
        "ClientInstanceID", // Client identity reservation
        "OAuthAuthorizationRequest", // OAuth external provider authorization wire contract
        "OAuthConnectionState" // OAuth external provider state wire contract
    ]

    private static func discoverPublicTypesInProtocol() throws -> Set<String> {
        let protocolDir = repoRoot.appendingPathComponent("Sources/LingXiProtocol")
        var typeNames = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: protocolDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return typeNames }

        let pattern = #"public\s+(?:struct|enum|class|protocol|typealias)\s+([A-Za-z0-9_]+)"#
        let regex = try NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = regex.matches(in: content, range: range)
            for m in matches {
                if let r = Range(m.range(at: 1), in: content) {
                    typeNames.insert(String(content[r]))
                }
            }
        }
        return typeNames
    }

    private static func scanUsageAcrossSources(for typeName: String) throws -> Int {
        let sourcesDir = repoRoot.appendingPathComponent("Sources")
        var count = 0

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return count }

        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: typeName) + #"\b"#
        let regex = try NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            count += regex.numberOfMatches(in: content, range: range)
            if count > 2 { // > 1 means used outside its declaration
                break
            }
        }
        return count
    }

    @Test("LingXiProtocol has no orphan types without producers or consumers")
    func noOrphanTypesInProtocol() throws {
        let publicTypes = try Self.discoverPublicTypesInProtocol()
        #expect(publicTypes.count >= 20, "Expected at least 20 public types in LingXiProtocol")

        var orphans: [String] = []
        for typeName in publicTypes {
            if Self.intentionalReservations.contains(typeName) { continue }
            let usage = try Self.scanUsageAcrossSources(for: typeName)
            if usage <= 1 { // Only the definition itself was found
                orphans.append(typeName)
            }
        }

        #expect(orphans.isEmpty, "Found orphan public types in LingXiProtocol without consumers: \(orphans.sorted())")
    }
}
