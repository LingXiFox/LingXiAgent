import Foundation

/// External protocol specifications that LingXiAgent interoperates with.
///
/// Note: These are external vendor/standard specification revision identifiers
/// (e.g. Model Context Protocol, Agent Client Protocol), NOT LingXi frontend/core
/// contract versions. Internal protocol versions are tracked strictly via
/// `ProtocolVersion.current`.
public enum MCPSpecRevision {
    /// Modern MCP specification revision date identifier.
    public static let modern = "2024-11-05"
}

public enum ACPSpecRevision {
    /// Modern ACP specification revision date identifier.
    public static let modern = "2024-11-05"
}
