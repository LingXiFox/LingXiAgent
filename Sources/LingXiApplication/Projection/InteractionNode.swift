import Foundation
import LingXiProtocol

/// 人机协同（HITL）交互节点。
/// 统一统合 Permission / Question / Decision。
public struct InteractionNode: Sendable, Equatable {
    public let interactionID: InteractionID
    public let kind: InteractionKind
    public let causal: CausalContext
    public let createdAt: Date
    public var permissionRequest: PermissionRequest?
    public var questionRequest: QuestionRequest?
    public var decisionRequest: DecisionRequest?
    public var isResolved: Bool
    public var resolution: InteractionResolution?

    public init(
        interactionID: InteractionID,
        kind: InteractionKind,
        causal: CausalContext,
        createdAt: Date = Date(),
        permissionRequest: PermissionRequest? = nil,
        questionRequest: QuestionRequest? = nil,
        decisionRequest: DecisionRequest? = nil,
        isResolved: Bool = false,
        resolution: InteractionResolution? = nil
    ) {
        self.interactionID = interactionID
        self.kind = kind
        self.causal = causal
        self.createdAt = createdAt
        self.permissionRequest = permissionRequest
        self.questionRequest = questionRequest
        self.decisionRequest = decisionRequest
        self.isResolved = isResolved
        self.resolution = resolution
    }

    public init(from snapshot: InteractionSnapshot) {
        self.interactionID = snapshot.interactionID
        self.kind = snapshot.kind
        self.causal = snapshot.causal
        self.createdAt = snapshot.createdAt
        self.permissionRequest = snapshot.permissionRequest
        self.questionRequest = snapshot.questionRequest
        self.decisionRequest = snapshot.decisionRequest
        self.isResolved = false
        self.resolution = nil
    }
}
