import Foundation

// Front-end contract for the language services Core really runs. Only the
// state an existing LSP client reports is carried here: nothing is inferred
// from configuration and nothing is claimed for a service that is not running.

/// Runtime state of one language service. Mirrors the states Core's LSP client
/// already distinguishes.
public enum LanguageServiceState: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case starting
    case ready
    case degraded
    case stopped
}

/// One language service as Core reports it, per language.
public struct LanguageServiceStatus: Codable, Sendable, Equatable, Identifiable {
    public let language: String
    public let state: LanguageServiceState

    public var id: String { language }

    public init(language: String, state: LanguageServiceState) {
        self.language = language
        self.state = state
    }
}
