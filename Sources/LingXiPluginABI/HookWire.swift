import Foundation

/// The hook payload as it crosses the plugin boundary. Deliberately a narrow subset of the kernel's
/// own context model: a plugin may read the request and append **text** entries, and it cannot
/// address the instruction channel at all. Anything richer would make the kernel's context type part
/// of the published ABI, and then no kernel change could ever be private (PLG-010).
public struct HookWireInvocation: Codable, Sendable {
    public struct WireEntry: Codable, Sendable {
        public let id: String
        public let segment: String
        public let role: String
        public let text: String

        public init(id: String, segment: String, role: String, text: String) {
            self.id = id
            self.segment = segment
            self.role = role
            self.text = text
        }
    }

    public init(node: String, sessionID: String, runID: String, model: String, entries: [WireEntry], toolNames: [String]) {
        self.node = node
        self.sessionID = sessionID
        self.runID = runID
        self.model = model
        self.entries = entries
        self.toolNames = toolNames
    }

    public let node: String
    public let sessionID: String
    public let runID: String
    public let model: String
    public let entries: [WireEntry]
    public let toolNames: [String]
}

public struct HookWireVerdict: Codable, Sendable {
    public struct WireInjection: Codable, Sendable {
        public let id: String
        public let text: String
        /// Only `history` and `derivedPage` are accepted; anything else is refused by the host bridge.
        public let segment: String

        public init(id: String, text: String, segment: String) {
            self.id = id
            self.text = text
            self.segment = segment
        }
    }

    public let verdict: String
    public let injections: [WireInjection]
    public let reason: String?

    public static func keep() -> HookWireVerdict { HookWireVerdict(verdict: "keep", injections: [], reason: nil) }

    public static func veto(reason: String) -> HookWireVerdict {
        HookWireVerdict(verdict: "veto", injections: [], reason: reason)
    }

    public static func failed(reason: String) -> HookWireVerdict {
        HookWireVerdict(verdict: "failed", injections: [], reason: reason)
    }

    public static func rewrite(_ injections: [WireInjection]) -> HookWireVerdict {
        HookWireVerdict(verdict: "rewrite", injections: injections, reason: nil)
    }
}

/// The identity and declarations a plugin returns from `describe`. Decoded with no defaults: a
/// missing field fails the load instead of guessing (PLG-009).
public struct PluginIdentity: Codable, Sendable, Equatable {
    public struct DeclaredHook: Codable, Sendable, Equatable {
        public let id: String
        public let node: String
        public let priority: Int
        public let canVeto: Bool

        public init(id: String, node: String, priority: Int, canVeto: Bool) {
            self.id = id
            self.node = node
            self.priority = priority
            self.canVeto = canVeto
        }
    }

    public let bundleID: String
    public let version: String
    public let hooks: [DeclaredHook]
    /// Required, like every other declaration: a plugin that offers models says so, and one that
    /// does not says that too.
    public let providers: [ProviderIdentity]
    /// Optional self-drawn settings capability. When present the manifest must declare the same
    /// capability string; the Core then offers a settings session even while the plugin is disabled.
    public let settings: SettingsDeclaration?

    public init(
        bundleID: String, version: String, hooks: [DeclaredHook], providers: [ProviderIdentity],
        settings: SettingsDeclaration? = nil
    ) {
        self.bundleID = bundleID
        self.version = version
        self.hooks = hooks
        self.providers = providers
        self.settings = settings
    }
}

public struct SettingsDeclaration: Codable, Sendable, Equatable {
    public let capability: String

    public init(capability: String = "settings.view.v1") {
        self.capability = capability
    }
}

public enum HookWire {
    public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        Array(try JSONEncoder().encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(bytes))
    }
}
