import Foundation

/// The single source of truth for the **product** version.
///
/// Everything that answers "which LingXiAgent is this" reads here: `lingxiagent
/// --version`, `CoreHost.coreVersion` (which gates extension admission), the ACP
/// agent identity, MCP `clientInfo`, outbound `User-Agent` tokens, and the macOS
/// bundle version. A git tag names the GitHub release; this constant names the
/// binary, and the two agreeing is enforced rather than remembered — see
/// `Scripts/version-consistency-check.sh` and `ProductVersionGateTests`.
///
/// Deliberately *not* here: `ProtocolVersion` (frontend wire contract),
/// `PluginIPC.currentVersion` (plugin protocol, lives in the SDK repository),
/// catalog `schemaVersion` (data contract), and `MCPSpecRevision` /
/// `ACPSpecRevision` (other people's specification dates). Those evolve on their
/// own axes and must not be coupled to a release tag.
public enum ProductVersion {
    /// Must equal the latest release tag without its leading `v`/`V`.
    public static let current = "1.2.0"

    /// Release channel shown next to the version string.
    public static let releaseName = "Stable"

    /// `major.minor`, for callers that only want the short form.
    public static var short: String {
        current.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Default outbound User-Agent marker for channels that are not an official
    /// subscription client. Host platform details stay the caller's business —
    /// `ClientFingerprint` adds them where they belong.
    public static var userAgent: String { "LingXiAgent/\(short)" }
}
