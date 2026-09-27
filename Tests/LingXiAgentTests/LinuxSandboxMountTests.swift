import Foundation
import Testing
@testable import LingXiPlatform

#if os(Linux)
@Suite("Linux Sandbox Mount Set")
struct LinuxSandboxMountTests {

    /// `--ro-bind <src> <dest>` is a consecutive triple; a plain membership test would also pass
    /// when the same string appears as an unrelated argument.
    private func bindsProgramDirectory(_ arguments: [String], _ path: String) -> Bool {
        guard arguments.count >= 3 else { return false }
        for index in 0...(arguments.count - 3)
        where arguments[index] == "--ro-bind" && arguments[index + 1] == path && arguments[index + 2] == path {
            return true
        }
        return false
    }

    @Test func programOutsideTheMountedSetIsBoundReadOnlyIntoTheNamespace() {
        // A tool binary outside the mounted prefixes does not exist inside the namespace at all:
        // bwrap answers the failed `execvp` with exit 1 and empty stdout, which is also ripgrep's
        // "no matches" code, so a broken sandbox used to be reported as an empty search result.
        // User-local prefixes (~/local/usr/bin) and /opt-style installs hit this on any machine
        // that does not keep rg in /usr/bin.
        let arguments = LinuxSandboxAdapter.wrapArguments(
            workspace: URL(fileURLWithPath: "/work/ws", isDirectory: true),
            filesystem: .workspaceReadWrite,
            readOnlyPaths: [],
            denyNetwork: true,
            executable: "/home/user/local/usr/bin/rg"
        )
        #expect(bindsProgramDirectory(arguments, "/home/user/local/usr/bin"))
    }

    @Test func programAlreadyInsideAMountedPrefixIsNotRemounted() {
        let arguments = LinuxSandboxAdapter.wrapArguments(
            workspace: URL(fileURLWithPath: "/work/ws", isDirectory: true),
            filesystem: .workspaceReadWrite,
            readOnlyPaths: [],
            denyNetwork: true,
            executable: "/usr/bin/rg"
        )
        #expect(!bindsProgramDirectory(arguments, "/usr/bin"))
    }

    @Test func programMountComesAfterTheTmpfsThatWouldOtherwiseHideIt() {
        // `--tmpfs /tmp` replaces all of /tmp, so a tool living under it has to be bound after it;
        // the reverse order leaves the namespace without the program again.
        let arguments = LinuxSandboxAdapter.wrapArguments(
            workspace: URL(fileURLWithPath: "/work/ws", isDirectory: true),
            filesystem: .workspaceReadWrite,
            readOnlyPaths: [],
            denyNetwork: true,
            executable: "/tmp/extracted-tool/bin/rg"
        )
        guard let tmpfs = arguments.firstIndex(of: "--tmpfs"),
              let program = arguments.firstIndex(of: "/tmp/extracted-tool/bin") else {
            Issue.record("expected both a /tmp tmpfs and a program bind: \(arguments)")
            return
        }
        #expect(tmpfs < program)
    }
}
#endif
