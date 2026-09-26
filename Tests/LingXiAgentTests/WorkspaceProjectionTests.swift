import Foundation
import Testing
import LingXiProtocol

/// The Git / workspace facts a frontend is allowed to show, pinned at the wire level.
///
/// Two properties matter more than any value here: a nil must stay distinguishable from a
/// zero (an unmeasured repo is not a clean one), and nothing in this contract may hand back
/// an invented worktree.
@Suite("WorkspaceProjectionTests")
struct WorkspaceProjectionTests {

    /// Repo root derived from this file's own location, so the scan does not depend on the
    /// working directory SwiftPM happened to launch the test binary from.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/LingXiAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    @Test("WorkspaceSummary keeps every git field across a state round-trip")
    func summaryRoundTrip() throws {
        let summary = WorkspaceSummary(
            rootPath: "/work/tree",
            isGitRepository: true,
            codebaseNodes: 12,
            codebaseEdges: 34,
            indexingState: "ready",
            gitBranch: "release/1.1",
            worktreeRoot: "/work/tree",
            isLinkedWorktree: true,
            changedFileCount: 7,
            isDirty: true
        )
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(WorkspaceSummary.self, from: data) == summary)
    }

    @Test("An unmeasured repo reports nil, which is not the same claim as clean")
    func nilIsNotZero() throws {
        let unknown = WorkspaceSummary(rootPath: "/x", isGitRepository: false)
        let decoded = try JSONDecoder().decode(WorkspaceSummary.self,
                                              from: try JSONEncoder().encode(unknown))
        #expect(decoded.gitBranch == nil)
        #expect(decoded.changedFileCount == nil)
        #expect(decoded.isDirty == nil)
        #expect(decoded.isLinkedWorktree == false)

        let clean = WorkspaceSummary(rootPath: "/x", isGitRepository: true,
                                     changedFileCount: 0, isDirty: false)
        #expect(try JSONDecoder().decode(WorkspaceSummary.self, from: JSONEncoder().encode(clean)) == clean)
    }

    @Test("Diff counts ride with the diff text they describe, and stay absent when not counted")
    func diffCountsRoundTrip() throws {
        let counted = WorkspaceDiffSummary(diff: "@@ -1 +1 @@", addedLines: 1, deletedLines: 1, changedFiles: 1)
        #expect(try JSONDecoder().decode(WorkspaceDiffSummary.self,
                                         from: JSONEncoder().encode(counted)) == counted)
        let uncounted = WorkspaceDiffSummary(diff: "")
        #expect(uncounted.addedLines == nil && uncounted.deletedLines == nil && uncounted.changedFiles == nil)
    }

    @Test("The worktree contract reports itself unavailable instead of inventing a branch and a path")
    func worktreeStubsFailLoudly() throws {
        let path = Self.repoRoot.appendingPathComponent("Sources/LingXiProtocol/ProtocolService.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!source.contains("/tmp/\\(envelope.payload.name)"),
                "a default implementation is fabricating a worktree path again")
        #expect(source.contains("lingxiWorktreeUnsupportedMessage"),
                "the worktree defaults must declare the capability unavailable")
    }
}
