import Foundation

/// The nodes a lifecycle hook may attach to. The kernel owns this list: a plugin can only mount on
/// a node the kernel actually calls, which is what keeps "extension point" from meaning "whatever
/// the plugin feels like intercepting".
public enum HookNode: String, Sendable, Codable {
    /// After the session history is assembled, before validation and budget planning.
    case contextPrepare
    /// After the budget plan and its revalidation, immediately before the request is sent.
    case beforeModelRequest
}

/// What happens when a handler fails. The kernel derives this from the handler's own capability —
/// a handler that can deny is `security` and fails closed. A plugin cannot choose its policy: not
/// by declaring itself a passive observer to escape fail-closed, and not by claiming a veto it was
/// never granted (PLG-016).
public enum HookFaultPolicy: String, Sendable {
    case transform
    case security
}

public struct HookInvocation: Sendable {
    public let node: HookNode
    public let sessionID: SessionID
    public let runID: RunID
    public let model: ModelID
    public let entries: [ContextEntry]
    public let tools: [ToolDescriptor]

    public init(
        node: HookNode,
        sessionID: SessionID,
        runID: RunID,
        model: ModelID,
        entries: [ContextEntry],
        tools: [ToolDescriptor]
    ) {
        self.node = node
        self.sessionID = sessionID
        self.runID = runID
        self.model = model
        self.entries = entries
        self.tools = tools
    }
}

public enum HookVerdict: Sendable {
    case keep
    /// Replace the entries about to be sent. Injected text must carry a non-privileged segment and
    /// role: hook output is data, never an instruction (CTX-001).
    case rewrite(entries: [ContextEntry])
    /// Refuse to let this request through, with a reason the run reports verbatim.
    case veto(reason: String)
    /// The handler could not produce a verdict. The kernel applies the fault policy, not the caller.
    case failed(reason: String)
}

public protocol ContextHook: Sendable {
    /// Stable identity used for ordering and for diagnostics. Bundle-namespaced, never positional.
    var handlerID: String { get }
    var node: HookNode { get }
    var priority: Int { get }
    /// Whether this handler may deny. Read as a capability, not as a policy choice.
    var canVeto: Bool { get }
    func apply(_ invocation: HookInvocation) async -> HookVerdict
}

public enum HookOutcome: Sendable {
    case allowed(entries: [ContextEntry], diagnostics: [String])
    case denied(reason: String, handlerID: String)
}

/// Runs the mounted handlers for one node in a deterministic order and applies the kernel's fault
/// policy. Order is explicit by priority, and handlers of equal priority fall back to their id so
/// two runs of the same set produce the same sequence (PLG-006 forbids registration-order luck).
public actor HookPipeline {
    private var handlers: [ContextHook] = []

    public init(hooks: [ContextHook] = []) {
        handlers = ordered(hooks)
    }

    public func install(_ hook: any ContextHook) {
        handlers.removeAll { $0.handlerID == hook.handlerID }
        handlers = ordered(handlers + [hook])
    }

    /// Revocation: the handler stops participating in every later stage. A Run already inside the
    /// stage keeps the set it started with; nothing is re-read mid-stage.
    public func uninstall(handlerID: String) -> Bool {
        let before = handlers.count
        handlers.removeAll { $0.handlerID == handlerID }
        return handlers.count != before
    }

    public var mountedHandlerIDs: [String] { handlers.map(\.handlerID) }

    public func hooks(for node: HookNode) -> [ContextHook] {
        handlers.filter { $0.node == node }
    }

    public nonisolated static func policy(of hook: any ContextHook) -> HookFaultPolicy {
        hook.canVeto ? .security : .transform
    }

    func apply(
        _ node: HookNode,
        base: [ContextEntry],
        sessionID: SessionID,
        runID: RunID,
        model: ModelID,
        tools: [ToolDescriptor]
    ) async -> HookOutcome {
        var entries = base
        var diagnostics: [String] = []

        for hook in hooks(for: node) {
            let invocation = HookInvocation(
                node: node, sessionID: sessionID, runID: runID, model: model,
                entries: entries, tools: tools
            )
            switch await hook.apply(invocation) {
            case .keep:
                continue
            case .rewrite(let rewritten):
                entries = rewritten
            case .veto(let reason):
                return .denied(reason: reason, handlerID: hook.handlerID)
            case .failed(let reason):
                switch Self.policy(of: hook) {
                case .security:
                    // A security-class handler that cannot answer is a denial, never a pass-through.
                    return .denied(reason: "hook \(hook.handlerID) failed and its class denies on failure: \(reason)", handlerID: hook.handlerID)
                case .transform:
                    diagnostics.append("hook \(hook.handlerID) skipped: \(reason)")
                }
            }
        }
        return .allowed(entries: entries, diagnostics: diagnostics)
    }
}

/// Mounting order must not decide execution order: priority first, then the stable handler id.
private func ordered(_ hooks: [ContextHook]) -> [ContextHook] {
    hooks.sorted { left, right in
        if left.priority != right.priority { return left.priority > right.priority }
        return left.handlerID < right.handlerID
    }
}
