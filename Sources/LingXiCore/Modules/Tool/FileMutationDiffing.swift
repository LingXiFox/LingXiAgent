import Foundation
import LingXiProtocol

/// A tool that writes files and can say which ones before it runs.
///
/// `resource(for:)` already resolves paths, but it is shaped for permission prompts (one string,
/// and `apply_patch` leaves out a move's destination). Mutation capture needs every file the call
/// may create, change or remove.
protocol FileMutationTargetProviding {
    func mutationTargets(for arguments: String, profile: ExecutionProfile) throws -> [URL]
    var mutationWorkspace: URL { get }
}

extension FileMutationTargetProviding {
    /// Workspace-relative inside the workspace, `~/…` under home, absolute otherwise.
    func mutationDisplayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = mutationWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

/// Captures real before/after content around one mutation call and turns it into unified diffs.
///
/// Bounded by design: only the named targets are read (no workspace snapshot), files over
/// `maxFileBytes` or not valid UTF-8 are skipped, and each diff is capped at `maxDiffLines`.
struct FileMutationCapture: Sendable {
    static let maxFileBytes = 1_000_000
    static let maxDiffLines = 2_000

    let targets: [URL]
    let before: [URL: String?]

    /// Reads the current state of every target. A missing file is recorded as nil, which is what
    /// makes a later write show up as "created".
    static func begin(targets: [URL]) -> FileMutationCapture? {
        guard !targets.isEmpty else { return nil }
        var before: [URL: String?] = [:]
        for url in targets {
            switch read(url) {
            case .absent: before[url] = .some(nil)
            case .text(let text): before[url] = .some(text)
            case .unreadable: continue
            }
        }
        return FileMutationCapture(targets: targets.filter { before[$0] != nil }, before: before)
    }

    func finish(displayPath: (URL) -> String) -> [FileMutationDiff] {
        targets.compactMap { url in
            guard let prior = before[url] else { return nil }
            let after: String?
            switch Self.read(url) {
            case .absent: after = nil
            case .text(let text): after = text
            case .unreadable: return nil
            }
            guard prior != after else { return nil }
            return FileMutationDiffer.diff(path: displayPath(url), before: prior, after: after)
        }
    }

    private enum ReadResult { case absent, text(String), unreadable }

    private static func read(_ url: URL) -> ReadResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .absent }
        guard !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maxFileBytes,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }
}

enum FileMutationDiffer {
    /// Unified diff of `before` → `after`. Nil content means the file did not exist on that side.
    static func diff(path: String, before: String?, after: String?, context: Int = 3) -> FileMutationDiff {
        let old = lines(before)
        let new = lines(after)
        let kind: FileMutationDiff.Kind = before == nil ? .created : (after == nil ? .deleted : .modified)
        var output = ["--- \(before == nil ? "/dev/null" : "a/" + path)", "+++ \(after == nil ? "/dev/null" : "b/" + path)"]
        let edits = editScript(old, new)
        let additions = edits.filter { if case .insert = $0 { return true } else { return false } }.count
        let deletions = edits.filter { if case .delete = $0 { return true } else { return false } }.count
        output += hunks(edits, context: context)
        var truncated = false
        if output.count > FileMutationCapture.maxDiffLines {
            output = Array(output.prefix(FileMutationCapture.maxDiffLines))
            output.append("… diff truncated (\(additions) additions, \(deletions) deletions in total)")
            truncated = true
        }
        return FileMutationDiff(path: path, kind: kind, unifiedDiff: output.joined(separator: "\n"),
                                additions: additions, deletions: deletions, truncated: truncated)
    }

    enum Edit: Equatable {
        case keep(oldIndex: Int, newIndex: Int, String)
        case delete(oldIndex: Int, String)
        case insert(newIndex: Int, String)
    }

    static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// LCS edit script. Common prefix and suffix are peeled first, so the usual edit (a few lines
    /// in a long file) costs almost nothing; a pathological middle larger than the budget degrades
    /// to delete-all/insert-all, which is still a correct diff, just not a minimal one.
    static func editScript(_ old: [String], _ new: [String]) -> [Edit] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        var edits: [Edit] = (0..<prefix).map { .keep(oldIndex: $0, newIndex: $0, old[$0]) }
        let oldMid = Array(old[prefix..<(old.count - suffix)])
        let newMid = Array(new[prefix..<(new.count - suffix)])
        let n = oldMid.count, m = newMid.count
        if n * m > 4_000_000 {
            edits += oldMid.indices.map { .delete(oldIndex: prefix + $0, oldMid[$0]) }
            edits += newMid.indices.map { .insert(newIndex: prefix + $0, newMid[$0]) }
        } else if n > 0 || m > 0 {
            var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0, m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i][j] = oldMid[i] == newMid[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, oldMid[i] == newMid[j] {
                    edits.append(.keep(oldIndex: prefix + i, newIndex: prefix + j, oldMid[i])); i += 1; j += 1
                } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                    // Deletions first on a tie: the conventional order, red before green.
                    edits.append(.delete(oldIndex: prefix + i, oldMid[i])); i += 1
                } else {
                    edits.append(.insert(newIndex: prefix + j, newMid[j])); j += 1
                }
            }
        }
        let oldTail = old.count - suffix, newTail = new.count - suffix
        edits += (0..<suffix).map { .keep(oldIndex: oldTail + $0, newIndex: newTail + $0, old[oldTail + $0]) }
        return edits
    }

    static func hunks(_ edits: [Edit], context: Int) -> [String] {
        let changed = edits.indices.filter { if case .keep = edits[$0] { return false } else { return true } }
        guard !changed.isEmpty else { return [] }
        // Group changes whose context windows touch.
        var groups: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(edits.count - 1, index + context)
            if let last = groups.last, range.lowerBound <= last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                groups.append(range)
            }
        }
        var output: [String] = []
        for group in groups {
            let slice = edits[group]
            var oldStart: Int?, newStart: Int?
            var oldCount = 0, newCount = 0
            var body: [String] = []
            for edit in slice {
                switch edit {
                case let .keep(o, n, line):
                    oldStart = oldStart ?? o; newStart = newStart ?? n
                    oldCount += 1; newCount += 1; body.append(" " + line)
                case let .delete(o, line):
                    oldStart = oldStart ?? o; oldCount += 1; body.append("-" + line)
                case let .insert(n, line):
                    newStart = newStart ?? n; newCount += 1; body.append("+" + line)
                }
            }
            // Unified diff convention: a zero-length side is addressed at the line before it.
            let oldLabel = oldCount == 0 ? "\(max(0, (oldStart ?? Self.anchorOld(slice)) ))" : "\((oldStart ?? 0) + 1)"
            let newLabel = newCount == 0 ? "\(max(0, (newStart ?? Self.anchorNew(slice)) ))" : "\((newStart ?? 0) + 1)"
            output.append("@@ -\(oldLabel),\(oldCount) +\(newLabel),\(newCount) @@")
            output += body
        }
        return output
    }

    private static func anchorOld(_ slice: ArraySlice<Edit>) -> Int {
        for edit in slice { if case let .insert(n, _) = edit { return n } }
        return 0
    }

    private static func anchorNew(_ slice: ArraySlice<Edit>) -> Int {
        for edit in slice { if case let .delete(o, _) = edit { return o } }
        return 0
    }
}

/// Carries the diffs out of the `@Sendable` operation closure.
final class FileMutationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var diffs: [FileMutationDiff] = []
    func set(_ value: [FileMutationDiff]) { lock.lock(); diffs = value; lock.unlock() }
    var value: [FileMutationDiff] { lock.lock(); defer { lock.unlock() }; return diffs }
}
