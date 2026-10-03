import Foundation
import LingXiProtocol

/// One publication boundary for the active assembly and its resolved scheduling policy.
/// The controller and Host share this object; neither keeps a separate policy copy.
public final class ModelRuntimeContextState: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let assembly: ModelRuntimeAssembly?
        public let policy: EffectiveContextPolicy
        public let generation: UInt64
    }

    private let lock = NSLock()
    private var value: Snapshot

    public init(assembly: ModelRuntimeAssembly? = nil, policy: EffectiveContextPolicy) {
        precondition(assembly == nil || assembly?.contextProfile.contextWindowTokens == policy.modelWindow)
        value = Snapshot(assembly: assembly, policy: policy, generation: 1)
    }

    public func snapshot() -> Snapshot {
        lock.withLock { value }
    }

    @discardableResult
    func apply(assembly: ModelRuntimeAssembly?, policy: EffectiveContextPolicy) -> Bool {
        precondition(assembly == nil || assembly?.contextProfile.contextWindowTokens == policy.modelWindow)
        return lock.withLock {
            let changed = value.policy != policy || value.assembly?.endpoint != assembly?.endpoint
            // Configuration edits may replace a provider even when its context policy is unchanged.
            value = Snapshot(assembly: assembly, policy: policy,
                             generation: value.generation + (changed ? 1 : 0))
            return changed
        }
    }

    @discardableResult
    func updatePolicy(_ policy: EffectiveContextPolicy) -> Bool {
        lock.withLock {
            precondition(value.assembly == nil || value.assembly?.contextProfile.contextWindowTokens == policy.modelWindow,
                         "An active assembly and its policy must be updated together")
            guard value.policy != policy else { return false }
            value = Snapshot(assembly: value.assembly, policy: policy, generation: value.generation + 1)
            return true
        }
    }
}
