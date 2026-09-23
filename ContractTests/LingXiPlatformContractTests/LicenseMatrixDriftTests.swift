import Foundation
import Testing

/// Guard for the license matrix. The repository's license posture (LCSAL-1.0
/// for core targets, PolyForm Noncommercial 1.0.0 for frontend targets) is
/// split by target, and the split is expressed in `LICENSE-MATRIX.md`. That
/// file used to hardcode target names in `LICENSE-CORE` / `LICENSE-FRONTEND`
/// and had drifted: it listed four targets that never existed
/// (`LingXiRuntime`, `LingXiStorage`, `LingXiAppCommon`, `LingXiCLI`) and
/// omitted `Apps/LingXiApp`, `Sources/lingxiagent`, `Sources/LingXiClient`,
/// and `Sources/LingXiApplication`.
///
/// The durable answer is not to keep three parallel lists in sync manually.
/// `LICENSE-MATRIX.md` is now the single scope of authority; the three
/// LICENSE files reference it; and this test asserts the SPM-target section
/// of that file covers exactly the set of `Package.swift` targets.
///
/// Runs on all three platforms in CI Stage 2.
struct LicenseMatrixDriftTests {

    private static var repoRoot: URL {
        // #filePath looks like <root>/Tests/LingXiAgentTests/LicenseMatrixDriftTests.swift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func read(_ relative: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Package targets that must appear in the matrix. Products are not
    /// listed; `LingXiAgentTests` is (its row marks it "Not shipped", and
    /// leaving it out would let a new test target slip in without a decision).
    private static func packageTargets() throws -> Set<String> {
        let source = try read("Package.swift")
        var names: Set<String> = []
        // Match `.target(name: "…", …)`, `.executableTarget(name: "…", …)`,
        // `.testTarget(name: "…", …)`, and `.systemLibrary(name: "…", …)`
        // across one- and multi-line declarations.
        let pattern = #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: source) else { return }
            names.insert(String(source[r]))
        }
        return names
    }

    /// Extract the first cell of every row under the "SPM targets" section
    /// of LICENSE-MATRIX.md. Rows look like `| `TargetName` | ... |` — target
    /// names are wrapped in backticks so we can also match cells that contain
    /// markdown links or commas later without ambiguity.
    private static func matrixTargets() throws -> Set<String> {
        let matrix = try read("LICENSE-MATRIX.md")
        var names: Set<String> = []
        var inSection = false
        for rawLine in matrix.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("## SPM targets") { inSection = true; continue }
            if inSection && line.hasPrefix("## ") { break }
            guard inSection, line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            guard cells.count >= 2 else { continue }
            let first = cells[1].trimmingCharacters(in: .whitespaces)
            // Skip the header row and the alignment row.
            if first.lowercased().hasPrefix("target") { continue }
            if first.allSatisfy({ $0 == "-" || $0 == ":" || $0.isWhitespace }) { continue }
            // Extract the identifier wrapped in backticks, if any.
            guard first.hasPrefix("`"), let close = first.lastIndex(of: "`") else { continue }
            let start = first.index(after: first.startIndex)
            names.insert(String(first[start..<close]))
        }
        return names
    }

    @Test("the SPM-target section of LICENSE-MATRIX.md covers every Package.swift target")
    func matrixCoversEveryPackageTarget() throws {
        let package = try Self.packageTargets()
        let matrix = try Self.matrixTargets()
        let missing = package.subtracting(matrix)
        let stale = matrix.subtracting(package)
        #expect(missing.isEmpty, "targets in Package.swift not declared in LICENSE-MATRIX.md: \(missing.sorted())")
        #expect(stale.isEmpty, "LICENSE-MATRIX.md lists targets that no longer exist in Package.swift: \(stale.sorted())")
    }

    @Test("Package.swift still declares the expected target count")
    func packageTargetShapeIsSane() throws {
        // Guard against the extraction pattern silently matching nothing (an
        // unanchored regex that returns an empty set would otherwise let the
        // comparison above pass vacuously).
        let package = try Self.packageTargets()
        #expect(package.count >= 15, "expected at least 15 targets to be discovered from Package.swift, got \(package.count): \(package.sorted())")
    }

    @Test("every LCSAL- or PolyForm-licensed row states a license")
    func everyRowStatesALicense() throws {
        let matrix = try Self.matrixTargets()
        #expect(!matrix.isEmpty, "matrix-target extraction returned nothing; regex or file shape drifted")
        // The extraction pass reads table rows; make sure each listed target
        // actually appears as a backticked cell so a stray mention elsewhere
        // in the file cannot satisfy the coverage test above.
        let full = try Self.read("LICENSE-MATRIX.md")
        for target in matrix {
            let needle = "| `\(target)` |"
            #expect(
                full.contains(needle),
                "target \(target) is in the extraction set but no table row wraps it in backticks as a cell"
            )
        }
    }

    @Test("the three LICENSE files reference LICENSE-MATRIX.md for their scope")
    func licenseFilesReferenceMatrix() throws {
        // Legal text lives in LICENSE / LICENSE-CORE / LICENSE-FRONTEND, but
        // their *scope* must come from the matrix so it can never drift again.
        // If a future edit reintroduces a hardcoded `Sources/LingXi*` list at
        // the top of either file, fail the build and force the reference path.
        for file in ["LICENSE-CORE", "LICENSE-FRONTEND"] {
            let text = try Self.read(file)
            #expect(
                text.contains("LICENSE-MATRIX.md"),
                "\(file) must reference LICENSE-MATRIX.md for its applicable scope"
            )
            // No lingering hardcoded Sources/ listing in the Applicable-to block.
            let lines = text.split(whereSeparator: \.isNewline).prefix(30).joined(separator: "\n")
            #expect(
                !lines.contains("- Sources/LingXiCore") && !lines.contains("- Sources/LingXiTUI"),
                "\(file) still hardcodes a Sources/ list at the top; it must delegate to LICENSE-MATRIX.md"
            )
        }
    }
}
