import Foundation
import LingXiProtocol
import LingXiClient

// MARK: - Frontend intent -> ApplicationAction
//
// Single place where a remote frontend's serializable intent becomes a store action.
// `FrontendCommand` is the closed, browser-safe subset of `ApplicationAction`; the
// store-internal (`_`-prefixed) and host-lifecycle (`connect` / `disconnect`) cases are
// not reachable from here by construction.

public extension ApplicationAction {
    static func from(_ command: FrontendCommand) -> ApplicationAction {
        switch command {
        case let .createSession(title, mode):
            .createSession(title: title, mode: mode)
        case let .switchSession(sessionID):
            .switchSession(sessionID)
        case let .renameSession(sessionID, newTitle):
            .renameSession(sessionID, newTitle: newTitle)
        case let .deleteSession(sessionID):
            .deleteSession(sessionID)
        case .listSessions:
            .listSessions
        case let .submitPrompt(text):
            .submitPrompt(text)
        case .stopCurrentRun:
            .stopCurrentRun
        case let .cancelRun(runID, reason):
            .cancelRun(runID, reason: reason)
        case let .setMode(mode):
            .setMode(mode)
        case let .setPermissionConfiguration(configuration):
            .setPermissionConfiguration(configuration)
        case let .setReasoningEffort(effort):
            .setReasoningEffort(effort)
        case let .respondInteraction(interactionID, resolution):
            .respondInteraction(interactionID: interactionID, resolution: resolution)
        case let .grantPermission(interactionID, decision):
            .grantPermission(interactionID: interactionID, decision: decision)
        case let .replyQuestion(interactionID, reply):
            .replyQuestion(interactionID: interactionID, reply: reply)
        case let .submitDecision(interactionID, decision):
            .submitDecision(interactionID: interactionID, decision: decision)
        case let .selectModel(modelID):
            .selectModel(modelID)
        case .listProviders:
            .listProviders
        case .listModels:
            .listModels
        case let .compactContext(sessionID):
            .compactContext(sessionID)
        case .refreshExtensions:
            .refreshExtensions
        case .refreshDiagnostics:
            .refreshDiagnostics
        case let .executeCommand(rawInput):
            .executeCommand(rawInput: rawInput)
        case .reconnect:
            .reconnect
        }
    }
}

// MARK: - FrontendWire

/// Shared JSON envelope for remote frontends (WebUI over `lingxiagent serve`).
/// Same contract the SwiftUI GUI and the TUI consume in-process, serialized as
/// snapshot + delta frames.
public enum FrontendWire {
    /// Wire contract revision. Bumped only on breaking changes to the frame shapes.
    public static let protocolVersion = "2.0"

    /// Canonical encoder for these frames. Both ends must use it.
    ///
    /// Dates stay on Swift's default strategy, i.e. JSON numbers of seconds since 1970
    /// (`1758873600.123`). That matches every other Codable wire type in this repo and,
    /// unlike `.iso8601`, it round-trips sub-second precision exactly.
    public static func makeEncoder(prettyPrint: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrint ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return encoder
    }

    /// Canonical decoder matching `makeEncoder`.
    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

// MARK: - Frames

/// Full state frame, including the whole timeline. Sent on first attach and whenever the
/// client is told to `requiresSnapshot`.
public struct FrontendSnapshotFrame: Sendable, Codable, Equatable {
    public let revision: UInt64
    public let state: ApplicationState
    public let commands: [ApplicationCommandDTO]
    public let protocolVersion: String

    public init(
        revision: UInt64,
        state: ApplicationState,
        commands: [ApplicationCommandDTO],
        protocolVersion: String = FrontendWire.protocolVersion
    ) {
        self.revision = revision
        self.state = state
        self.commands = commands
        self.protocolVersion = protocolVersion
    }
}

/// Incremental frame. Carries the changed domains, the changed timeline nodes themselves,
/// and a *trimmed* copy of the state.
public struct FrontendDeltaFrame: Sendable, Codable, Equatable {
    public let revision: UInt64
    public let changes: ApplicationChangeSet
    /// Resolved payloads for `changes.nodeChanges`, looked up in the active timeline.
    public let changedNodes: [TimelineNode]
    /// TRIMMED state: every transcript-scale container in `activeSessionState`
    /// (`timelineNodes`, `committedNodes`, `activeCell`, `thinkingNodes`, `toolNodes`)
    /// is emptied, because those bytes are delivered through `changedNodes` instead.
    /// Everything else (session catalog, runtime, providers, extensions, turns, HITL)
    /// stays intact so a delta alone can still render the non-transcript chrome.
    public let state: ApplicationState
    /// True when the client must discard its timeline and request a fresh snapshot:
    /// structural transcript change, a `.reset` node change, or an unresolvable node id.
    public let requiresSnapshot: Bool
    public let protocolVersion: String

    public init(
        revision: UInt64,
        changes: ApplicationChangeSet,
        changedNodes: [TimelineNode],
        state: ApplicationState,
        requiresSnapshot: Bool,
        protocolVersion: String = FrontendWire.protocolVersion
    ) {
        self.revision = revision
        self.changes = changes
        self.changedNodes = changedNodes
        self.state = state
        self.requiresSnapshot = requiresSnapshot
        self.protocolVersion = protocolVersion
    }
}

public extension FrontendWire {
    /// Build a full snapshot frame from an in-process `ApplicationUpdate`.
    static func snapshot(from update: ApplicationUpdate, commands: [ApplicationCommand]) -> FrontendSnapshotFrame {
        FrontendSnapshotFrame(
            revision: update.revision,
            state: update.state,
            commands: commands.asDTOs
        )
    }

    /// Build a delta frame from an in-process `ApplicationUpdate`.
    static func delta(from update: ApplicationUpdate) -> FrontendDeltaFrame {
        let timeline = update.state.activeSessionState?.timelineNodes ?? []
        var changedNodes: [TimelineNode] = []
        changedNodes.reserveCapacity(update.changes.nodeChanges.count)
        var missingNodes = false

        for change in update.changes.nodeChanges {
            if change.kind == .reset {
                missingNodes = true
                continue
            }
            if let node = timeline.first(where: { $0.id == change.nodeID }) {
                changedNodes.append(node)
            } else {
                missingNodes = true
            }
        }

        // `appendNode` upserts by id and only ever pushes a genuinely new id onto the tail, and
        // every removal arrives as an explicit `.remove` op, so a structural change is still
        // describable by a delta. Forcing a full snapshot there made a remote frontend refetch and
        // repaint the whole transcript for every streamed node (~35% of frames in a live run).
        // A snapshot is required only when the delta cannot describe the outcome at all.
        let requiresSnapshot = missingNodes
            || update.changes.nodeChanges.contains { $0.kind == .reset }

        return FrontendDeltaFrame(
            revision: update.revision,
            changes: update.changes,
            changedNodes: changedNodes,
            state: trimmed(update.state),
            requiresSnapshot: requiresSnapshot
        )
    }

    /// Strip transcript-scale containers out of a state copy destined for a delta frame.
    static func trimmed(_ state: ApplicationState) -> ApplicationState {
        var trimmedState = state
        guard var session = trimmedState.activeSessionState else { return trimmedState }
        session.timelineNodes = []
        session.committedNodes = []
        session.activeCell = nil
        session.thinkingNodes = [:]
        session.toolNodes = [:]
        // The timeline index is a derived cache that is never encoded: rebuild it here so the
        // trimmed copy is self-consistent instead of pointing at emptied storage.
        session.rebuildTimelineIndex()
        trimmedState.activeSessionState = session
        return trimmedState
    }
}
