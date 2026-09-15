import Foundation

// MARK: - Risk Evaluation Model

public enum InteractionRiskCategory: Sendable, Codable, Equatable {
    /// 低风险动作（如页面只读滚动、文本选择、同域内页面跳转等），根据策略通常可自动执行
    case low

    /// 中风险动作（普通文本输入、普通按钮点击、表单非关键提交等）
    case medium

    /// 高危/临界动作（涉及资金、转账、账号删除、权限变更、敏感文件上传等），必须触发人工强审批
    case critical(reason: String)
}

/// 独立的交互动作风险裁决器协议。运行在 Core 信任边界内，模型不可篡改。
public protocol InteractionRiskEvaluating: Sendable {
    func evaluateRisk(
        actions: [InteractionAction],
        observation: Observation?,
        origin: String?,
        intentHint: String?
    ) async -> InteractionRiskCategory
}

// MARK: - Capability Availability

public enum CapabilityAvailability: Sendable, Codable, Equatable {
    case available
    case requiresAuthorization(subsystem: String)
    case partial(details: String)
    case temporarilyUnavailable(reason: String)
    case unsupported(reason: String)
}

public struct HostCapabilitySnapshot: Sendable, Codable, Equatable {
    public let capture: CapabilityAvailability
    public let accessibility: CapabilityAvailability
    public let input: CapabilityAvailability
    public let windowManagement: CapabilityAvailability
    public let applicationManagement: CapabilityAvailability
    public let clipboard: CapabilityAvailability
    public let probeTimestamp: Date

    public init(
        capture: CapabilityAvailability,
        accessibility: CapabilityAvailability,
        input: CapabilityAvailability,
        windowManagement: CapabilityAvailability,
        applicationManagement: CapabilityAvailability,
        clipboard: CapabilityAvailability,
        probeTimestamp: Date = Date()
    ) {
        self.capture = capture
        self.accessibility = accessibility
        self.input = input
        self.windowManagement = windowManagement
        self.applicationManagement = applicationManagement
        self.clipboard = clipboard
        self.probeTimestamp = probeTimestamp
    }
}

// MARK: - 10 大分类严密错误体系

public enum CapabilityError: Error, Sendable, Codable, Equatable {
    case featureUnsupported(feature: String, reason: String)
    case environmentHeadless
    case daemonUnavailable(daemon: String)
}

public enum SystemAuthorizationError: Error, Sendable, Codable, Equatable {
    case denied(subsystem: String, guidance: String)
    case restricted(subsystem: String)
}

public enum InteractionPermissionError: Error, Sendable, Codable, Equatable {
    case rejectedByUser(reason: String?)
    case domainNotWhitelisted(domain: String)
    case highRiskActionForbidden(reason: String)
}

public enum StaleReferenceError: Error, Sendable, Codable, Equatable {
    case versionMismatch(expectedVersion: Int64, currentVersion: Int64, ref: ElementRef)
    case scopeMismatch(expectedScope: String, currentScope: String)
    case elementDisappeared(ref: ElementRef)
}

public enum ActionExecutionError: Error, Sendable, Codable, Equatable {
    case elementNotInteractable(ref: ElementRef, reason: String)
    case targetOutOfBounds(point: LogicalPoint)
    case inputInjectionFailed(reason: String)
}

public enum InteractionTimeoutError: Error, Sendable, Codable, Equatable {
    case conditionNotMet(condition: CommonWaitCondition, elapsedMs: Int)
    case pageLoadTimeout(url: String, elapsedMs: Int)
}

public enum InteractionCancellationError: Error, Sendable, Codable, Equatable {
    case userCancelled
    case taskSuperseded
}

public enum HostProcessError: Error, Sendable, Codable, Equatable {
    case sidecarCrashed(exitCode: Int32, signal: Int32?)
    case launchFailed(path: String, underlyingError: String)
    case connectionLost
}

public enum InteractionProtocolError: Error, Sendable, Codable, Equatable {
    case handshakeFailed(expected: String, got: String)
    case invalidFramePayload
    case unrecognizedAction
}

public enum CoordinateTransformError: Error, Sendable, Codable, Equatable {
    case invalidScaleFactor(Double)
    case missingWindowContext
    case unsupportedSpace(String)
    case coordinateOutOfBounds(x: Double, y: Double)
}

/// 统一交互领域根错误
public enum InteractionError: Error, Sendable, Codable, Equatable {
    case capability(CapabilityError)
    case systemAuthorization(SystemAuthorizationError)
    case permission(InteractionPermissionError)
    case staleReference(StaleReferenceError)
    case actionExecution(ActionExecutionError)
    case timeout(InteractionTimeoutError)
    case cancellation(InteractionCancellationError)
    case hostProcess(HostProcessError)
    case protocolViolation(InteractionProtocolError)
    case coordinateTransform(CoordinateTransformError)
}
