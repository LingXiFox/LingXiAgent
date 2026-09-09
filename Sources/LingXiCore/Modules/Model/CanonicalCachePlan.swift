import Foundation
import LingXiProtocol

/// 跨 Provider、跨 Model、跨 Protocol 的统一缓存结构计划。
/// 在任何 Provider wire encoding 之前建立，各 Provider Adapter 只能将该 Plan 序列化为对应协议，
/// 严禁 Adapter 自行决定哪些内容是 Stable 还是 Volatile。
public struct CanonicalCachePlan: Sendable, Equatable {
    public struct EpochIdentity: Sendable, Equatable {
        public let epoch: Int
        public let reason: String

        public init(epoch: Int, reason: String = "initial") {
            self.epoch = epoch
            self.reason = reason
        }
    }

    public struct ImmutableBase: Sendable, Equatable {
        public let systemPrompt: String?
        public let developerPrompt: String?
        public let coreTools: [ToolDefinition]
        public let stablePolicy: String?

        public init(
            systemPrompt: String? = nil,
            developerPrompt: String? = nil,
            coreTools: [ToolDefinition] = [],
            stablePolicy: String? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.developerPrompt = developerPrompt
            self.coreTools = coreTools
            self.stablePolicy = stablePolicy
        }
    }

    public struct AppendOnlyContext: Sendable, Equatable {
        public let dynamicTools: [ToolDefinition]
        public let messages: [ModelMessage]
        public let skillActivations: [String]

        public init(
            dynamicTools: [ToolDefinition] = [],
            messages: [ModelMessage] = [],
            skillActivations: [String] = []
        ) {
            self.dynamicTools = dynamicTools
            self.messages = messages
            self.skillActivations = skillActivations
        }
    }

    public struct VolatileTail: Sendable, Equatable {
        public let currentTurnState: String?
        public let ephemeralNotes: String?

        public init(currentTurnState: String? = nil, ephemeralNotes: String? = nil) {
            self.currentTurnState = currentTurnState
            self.ephemeralNotes = ephemeralNotes
        }
    }

    public let epochIdentity: EpochIdentity
    public let immutableBase: ImmutableBase
    public let appendOnlyContext: AppendOnlyContext
    public let volatileTail: VolatileTail
    public let structuralHealth: ClientStructuralCacheHealth
    public let capabilities: ProviderCacheCapabilities?

    public init(
        epochIdentity: EpochIdentity,
        immutableBase: ImmutableBase,
        appendOnlyContext: AppendOnlyContext,
        volatileTail: VolatileTail = VolatileTail(),
        structuralHealth: ClientStructuralCacheHealth,
        capabilities: ProviderCacheCapabilities? = nil
    ) {
        self.epochIdentity = epochIdentity
        self.immutableBase = immutableBase
        self.appendOnlyContext = appendOnlyContext
        self.volatileTail = volatileTail
        self.structuralHealth = structuralHealth
        self.capabilities = capabilities
    }
}
