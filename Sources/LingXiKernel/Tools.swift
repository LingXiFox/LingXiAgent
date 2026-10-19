public enum ToolEffect: String, Sendable, Codable {
    case readOnly
    case mutating
    case unknown
}

public struct ToolDescriptor: Hashable, Sendable {
    public let id: String
    public let name: String
    public let schemaJSON: String
    public let effect: ToolEffect

    public init(id: String, name: String, schemaJSON: String, effect: ToolEffect) {
        self.id = id
        self.name = name
        self.schemaJSON = schemaJSON
        self.effect = effect
    }
}

public struct ToolCall: Hashable, Sendable, Codable {
    public let callID: ToolCallID
    public let toolName: String
    public let argumentsJSON: String

    public init(callID: ToolCallID, toolName: String, argumentsJSON: String) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolOutcome: Sendable, Codable {
    public let callID: ToolCallID
    public let content: String
    public let isError: Bool
    public let effect: ToolEffect

    public init(callID: ToolCallID, content: String, isError: Bool, effect: ToolEffect) {
        self.callID = callID
        self.content = content
        self.isError = isError
        self.effect = effect
    }
}

public protocol ToolExecutor: Sendable {
    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome
}

public enum ToolRegistryError: Error, Equatable {
    case duplicateToolName(String)
    case schemaChangedWithoutEpochAdvance(String)
}

/// Tool manifest is append-only inside an epoch: removing or reordering entries busts the
/// stable prefix, so a schema change must move the epoch forward deliberately (CTX-002).
public actor ToolRegistry {
    public private(set) var epoch: Int
    private var byName: [String: ToolDescriptor] = [:]
    private var registeredInEpoch: [String: Int] = [:]
    private var orderedNames: [String] = []

    public init(epoch: Int = 1) {
        self.epoch = epoch
    }

    public func register(_ descriptor: ToolDescriptor) throws {
        guard let existing = byName[descriptor.name] else {
            byName[descriptor.name] = descriptor
            registeredInEpoch[descriptor.name] = epoch
            orderedNames.append(descriptor.name)
            return
        }
        guard existing != descriptor else { return }
        guard registeredInEpoch[descriptor.name] != epoch else {
            throw ToolRegistryError.schemaChangedWithoutEpochAdvance(descriptor.name)
        }
        byName[descriptor.name] = descriptor
        registeredInEpoch[descriptor.name] = epoch
    }

    public func advanceEpoch() {
        epoch += 1
    }

    public func descriptor(forName name: String) -> ToolDescriptor? {
        byName[name]
    }

    public func manifest() -> [ToolDescriptor] {
        orderedNames.compactMap { byName[$0] }
    }
}

public enum ToolBatchError: Error, Equatable {
    case duplicateCallID(ToolCallID)
}

public struct ToolBatchRunner {
    public static func settle(
        calls: [ToolCall],
        registry: ToolRegistry,
        executor: any ToolExecutor,
        allowParallel: Bool
    ) async throws -> [ToolOutcome] {
        var seen: Set<ToolCallID> = []
        for call in calls {
            guard seen.insert(call.callID).inserted else {
                throw ToolBatchError.duplicateCallID(call.callID)
            }
        }

        if !allowParallel {
            var outcomes: [ToolOutcome] = []
            outcomes.reserveCapacity(calls.count)
            for call in calls {
                outcomes.append(await run(call, registry: registry, executor: executor))
            }
            return outcomes
        }

        return await withTaskGroup(of: (Int, ToolOutcome).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, await run(call, registry: registry, executor: executor)) }
            }
            var settled: [ToolOutcome?] = Array(repeating: nil, count: calls.count)
            for await (index, outcome) in group {
                settled[index] = outcome
            }
            return settled.compactMap { $0 }
        }
    }

    private static func run(_ call: ToolCall, registry: ToolRegistry, executor: any ToolExecutor) async -> ToolOutcome {
        guard let descriptor = await registry.descriptor(forName: call.toolName) else {
            return ToolOutcome(
                callID: call.callID,
                content: "tool '\(call.toolName)' is not registered",
                isError: true,
                effect: .unknown
            )
        }
        do {
            return try await executor.execute(call, descriptor: descriptor)
        } catch {
            // A throw tells us nothing about whether the side effect landed, so the effect is
            // unknown rather than the descriptor's declared one (LOOP-008).
            return ToolOutcome(callID: call.callID, content: "\(error)", isError: true, effect: .unknown)
        }
    }
}
