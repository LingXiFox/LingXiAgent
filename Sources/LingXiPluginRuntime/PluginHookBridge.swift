import Foundation
import LingXiKernel
import LingXiPluginABI

/// Presents one declared plugin hook as a kernel `ContextHook`. Everything that can go wrong over
/// there - a dead host, a missed deadline, unreadable JSON - becomes `.failed`, and the kernel's
/// policy decides what that means. The bridge never invents a verdict.
public struct PluginHookBridge: ContextHook {
    public let handlerID: String
    public let node: HookNode
    public let priority: Int
    public let canVeto: Bool

    private let capabilityID: String
    private let session: PluginSession
    private let timeout: Duration

    public init(bundleID: String, declaration: DeclaredCapability, session: PluginSession, timeout: Duration = .seconds(5)) {
        handlerID = "\(bundleID).\(declaration.id)"
        node = declaration.node == "beforeModelRequest" ? .beforeModelRequest : .contextPrepare
        priority = declaration.priority
        canVeto = declaration.canVeto
        capabilityID = "hook.\(declaration.id)"
        self.session = session
        self.timeout = timeout
    }

    public func apply(_ invocation: HookInvocation) async -> HookVerdict {
        let wire = HookWireInvocation(
            node: invocation.node.rawValue,
            sessionID: invocation.sessionID.rawValue,
            runID: invocation.runID.rawValue,
            model: invocation.model.rawValue,
            entries: invocation.entries.map { entry in
                HookWireInvocation.WireEntry(
                    id: entry.id.rawValue,
                    segment: entry.segment.rawValue,
                    role: entry.role.rawValue,
                    text: Self.text(of: entry)
                )
            },
            toolNames: invocation.tools.map(\.name)
        )
        do {
            let payload = try JSONValue.encode(wire)
            let reply = try await session.invoke(capability: capabilityID, payload: payload)
            let verdict = try reply.decode(HookWireVerdict.self)
            return Self.map(verdict, onto: invocation.entries)
        } catch {
            // Deadline, crash, protocol failure: all indistinguishable to the kernel, and all
            // reported as a failed handler so the security class can deny on it.
            return .failed(reason: "\(capabilityID) unavailable: \(error)")
        }
    }

    private static func map(_ verdict: HookWireVerdict, onto entries: [ContextEntry]) -> HookVerdict {
        switch verdict.verdict {
        case "keep":
            return .keep
        case "veto":
            return .veto(reason: verdict.reason ?? "the plugin denied the request without a reason")
        case "failed":
            return .failed(reason: verdict.reason ?? "the plugin reported a failure")
        case "rewrite":
            var rewritten = entries
            for injection in verdict.injections {
                // Injection is data. A plugin cannot address the instruction channel, and an
                // unknown segment is a protocol violation rather than something to interpret.
                guard injection.segment == ContextSegment.history.rawValue
                    || injection.segment == ContextSegment.derivedPage.rawValue
                else {
                    return .failed(reason: "injection \(injection.id) targets the privileged segment \(injection.segment)")
                }
                guard !rewritten.contains(where: { $0.id == EntryID(injection.id) }) else {
                    return .failed(reason: "injection \(injection.id) collides with an existing entry id")
                }
                rewritten.append(ContextEntry(
                    id: EntryID(injection.id),
                    segment: ContextSegment(rawValue: injection.segment) ?? .derivedPage,
                    role: .user,
                    payload: .text(injection.text)
                ))
            }
            return .rewrite(entries: rewritten)
        default:
            return .failed(reason: "unknown verdict \(verdict.verdict)")
        }
    }

    private static func text(of entry: ContextEntry) -> String {
        switch entry.payload {
        case .text(let text): return text
        case .assistantMessage(let text, _): return text
        case .toolCall(let calls): return calls.map { "\($0.callID.rawValue):\($0.toolName)" }.joined(separator: ",")
        case .toolResult(let outcomes): return outcomes.map(\.content).joined(separator: " | ")
        }
    }
}
