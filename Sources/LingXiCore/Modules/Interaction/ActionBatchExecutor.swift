import Foundation
import LingXiProtocol
import LingXiPlatform

public struct InteractionExecutionProgress: Sendable {
    public let stepIndex: Int
    public let totalSteps: Int
    public let currentAction: InteractionAction

    public init(stepIndex: Int, totalSteps: Int, currentAction: InteractionAction) {
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.currentAction = currentAction
    }
}

/// 交互批处理动作调度内核 (ActionBatchExecutor)。
/// 负责在给定的物理/虚拟环境中严格顺序执行交互流水线。
/// 核心特性：
/// 1. 严格时序执行 (Sequential Pipeline)
/// 2. 失败立即熔断 (Stop-on-failure)
/// 3. 取消毫秒级响应 (Task Cancellation)
/// 4. 元素陈旧拦截 (Stale Reference Check)
/// 5. 前置能力校验 (Capability Preflight)
/// 6. 强输入中立化保证 (Input Neutralization in defer)
public struct ActionBatchExecutor: Sendable {

    public init() {}

    /// 在桌面环境中执行 ActionBatch
    /// 在桌面环境中执行 ActionBatch
    public func execute(
        batch: ActionBatch,
        environment: DesktopEnvironment,
        currentObservation: Observation,
        riskEvaluator: (any InteractionRiskEvaluating)? = nil,
        progressHandler: (@Sendable (InteractionExecutionProgress) -> Void)? = nil
    ) async throws -> ActionBatchResult {
        var batchResult: ActionBatchResult?
        var thrownError: Error?

        do {
            batchResult = try await executePipeline(
                batch: batch,
                environment: environment,
                currentObservation: currentObservation,
                riskEvaluator: riskEvaluator,
                progressHandler: progressHandler
            )
        } catch {
            thrownError = error
        }

        // 强保证：输入中立化（释放按键与修饰键）必须在函数返回前完成
        await environment.input?.neutralize()

        if let thrownError {
            throw thrownError
        }
        return batchResult!
    }

    private func executePipeline(
        batch: ActionBatch,
        environment: DesktopEnvironment,
        currentObservation: Observation,
        riskEvaluator: (any InteractionRiskEvaluating)?,
        progressHandler: (@Sendable (InteractionExecutionProgress) -> Void)?
    ) async throws -> ActionBatchResult {
        // 1. Capability Preflight 校验
        let snapshot = await environment.preflightSnapshot()

        // 2. Stale Ref 预检与动作依赖检查
        for action in batch.actions {
            if let ref = extractTargetElementRef(from: action) {
                guard ref.version == currentObservation.version else {
                    throw InteractionError.staleReference(
                        .versionMismatch(
                            expectedVersion: ref.version,
                            currentVersion: currentObservation.version,
                            ref: ref
                        )
                    )
                }
                guard ref.scopeID.isEmpty || ref.scopeID == currentObservation.sessionID.rawValue else {
                    throw InteractionError.staleReference(
                        .scopeMismatch(
                            expectedScope: ref.scopeID,
                            currentScope: currentObservation.sessionID.rawValue
                        )
                    )
                }
                guard currentObservation.elements[ref] != nil else {
                    throw InteractionError.staleReference(.elementDisappeared(ref: ref))
                }
            }

            // 检查对应能力是否支持
            switch action {
            case .desktop, .browser(.primitive(.click)), .browser(.primitive(.type)), .browser(.primitive(.hover)), .browser(.primitive(.keyPress)), .browser(.primitive(.drag)):
                if case let .unsupported(reason) = snapshot.input {
                    throw InteractionError.capability(
                        .featureUnsupported(feature: "InputInjection", reason: reason)
                    )
                }
            default:
                break
            }
        }

        // 3. 风险前置评估
        if let riskEvaluator {
            let risk = await riskEvaluator.evaluateRisk(
                actions: batch.actions,
                observation: currentObservation,
                origin: nil,
                intentHint: batch.intentHint
            )
            if case let .critical(reason) = risk {
                throw InteractionError.permission(.highRiskActionForbidden(reason: reason))
            }
        }

        // 4. 顺序执行动作流水线
        var completedCount = 0

        for (index, action) in batch.actions.enumerated() {
            // 取消检测
            if Task.isCancelled {
                throw InteractionError.cancellation(.userCancelled)
            }

            progressHandler?(InteractionExecutionProgress(
                stepIndex: index,
                totalSteps: batch.actions.count,
                currentAction: action
            ))

            do {
                try await executeSingleAction(
                    action,
                    environment: environment,
                    observation: currentObservation
                )
                completedCount += 1
            } catch {
                if batch.stopOnFailure {
                    return ActionBatchResult(
                        batchID: batch.id,
                        completedStepCount: completedCount,
                        succeeded: false,
                        failureReason: "\(error)",
                        finalObservationID: currentObservation.id
                    )
                }
            }
        }

        return ActionBatchResult(
            batchID: batch.id,
            completedStepCount: completedCount,
            succeeded: completedCount == batch.actions.count,
            failureReason: nil,
            finalObservationID: currentObservation.id
        )
    }

    private func executeSingleAction(
        _ action: InteractionAction,
        environment: DesktopEnvironment,
        observation: Observation
    ) async throws {
        switch action {
        case let .browser(browserAction):
            switch browserAction {
            case let .primitive(primitive):
                try await executePrimitive(primitive, environment: environment, observation: observation)
            case let .navigate(url):
                throw InteractionError.capability(
                    .featureUnsupported(
                        feature: "BrowserNavigation",
                        reason: "ActionBatchExecutor requires an explicit browser session context to execute navigate(\(url)). Direct execution without browser context is unsupported."
                    )
                )
            case .reload:
                throw InteractionError.capability(
                    .featureUnsupported(
                        feature: "BrowserNavigation",
                        reason: "ActionBatchExecutor requires an explicit browser session context to execute reload(). Direct execution without browser context is unsupported."
                    )
                )
            case .goBack:
                throw InteractionError.capability(
                    .featureUnsupported(
                        feature: "BrowserNavigation",
                        reason: "ActionBatchExecutor requires an explicit browser session context to execute goBack(). Direct execution without browser context is unsupported."
                    )
                )
            case let .waitForURL(pattern, _):
                throw InteractionError.capability(
                    .featureUnsupported(
                        feature: "BrowserNavigation",
                        reason: "ActionBatchExecutor requires an explicit browser session context to execute waitForURL(\(pattern)). Direct execution without browser context is unsupported."
                    )
                )
            }

        case let .desktop(desktopAction):
            switch desktopAction {
            case let .primitive(primitive):
                try await executePrimitive(primitive, environment: environment, observation: observation)
            case let .activateWindow(windowID):
                guard let windowBackend = environment.windows else {
                    throw InteractionError.capability(.featureUnsupported(feature: "WindowManagement", reason: "No WindowBackend attached"))
                }
                try await windowBackend.focusWindow(id: windowID)
            case let .moveWindow(windowID, bounds):
                guard let windowBackend = environment.windows else {
                    throw InteractionError.capability(.featureUnsupported(feature: "WindowManagement", reason: "No WindowBackend attached"))
                }
                try await windowBackend.setWindowBounds(id: windowID, bounds: bounds)
            case let .launchApp(identifier):
                guard let appBackend = environment.applications else {
                    throw InteractionError.capability(.featureUnsupported(feature: "ApplicationManagement", reason: "No ApplicationBackend attached"))
                }
                _ = try await appBackend.launchApplication(identifier: identifier)
            case let .terminateApp(identifier):
                guard let appBackend = environment.applications else {
                    throw InteractionError.capability(.featureUnsupported(feature: "ApplicationManagement", reason: "No ApplicationBackend attached"))
                }
                try await appBackend.terminateApplication(identifier: identifier)
            }
        }
    }

    private func executePrimitive(
        _ primitive: CommonInteractionPrimitive,
        environment: DesktopEnvironment,
        observation: Observation
    ) async throws {
        switch primitive {
        case let .click(target, button, count):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "PointerInput", reason: "No InputBackend attached"))
            }
            let point = try resolveTargetPoint(target, observation: observation)
            try await input.injectPointer(event: PointerInputEvent(position: point, kind: .move))
            try await input.injectPointer(event: PointerInputEvent(position: point, kind: .click(button: button, count: count)))

        case let .hover(target):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "PointerInput", reason: "No InputBackend attached"))
            }
            let point = try resolveTargetPoint(target, observation: observation)
            try await input.injectPointer(event: PointerInputEvent(position: point, kind: .move))

        case let .type(text, target):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "KeyboardInput", reason: "No InputBackend attached"))
            }
            if let target {
                let point = try resolveTargetPoint(target, observation: observation)
                try await input.injectPointer(event: PointerInputEvent(position: point, kind: .move))
                try await input.injectPointer(event: PointerInputEvent(position: point, kind: .click(button: .left, count: 1)))
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms Click-to-Focus 焦点激活保护
            }
            try await input.injectKeyboard(event: KeyboardInputEvent(kind: .text(text)))

        case let .keyPress(key, modifiers):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "KeyboardInput", reason: "No InputBackend attached"))
            }
            if !modifiers.isEmpty {
                try await input.injectKeyboard(event: KeyboardInputEvent(kind: .modifiersChanged(modifiers)))
            }
            try await input.injectKeyboard(event: KeyboardInputEvent(kind: .keyPress(key: key)))
            if !modifiers.isEmpty {
                try await input.injectKeyboard(event: KeyboardInputEvent(kind: .modifiersChanged([])))
            }

        case let .scroll(target, deltaX, deltaY):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "PointerInput", reason: "No InputBackend attached"))
            }
            let point: LogicalPoint
            if let target {
                point = try resolveTargetPoint(target, observation: observation)
            } else {
                point = LogicalPoint(x: 0, y: 0)
            }
            try await input.injectPointer(event: PointerInputEvent(position: point, kind: .scroll(deltaX: deltaX, deltaY: deltaY)))

        case let .drag(from, to):
            guard let input = environment.input else {
                throw InteractionError.capability(.featureUnsupported(feature: "PointerInput", reason: "No InputBackend attached"))
            }
            let startPoint = try resolveTargetPoint(from, observation: observation)
            let endPoint = try resolveTargetPoint(to, observation: observation)
            try await input.injectPointer(event: PointerInputEvent(position: startPoint, kind: .move))
            try await input.injectPointer(event: PointerInputEvent(position: startPoint, kind: .down(button: .left)))
            try await input.injectPointer(event: PointerInputEvent(position: endPoint, kind: .move))
            try await input.injectPointer(event: PointerInputEvent(position: endPoint, kind: .up(button: .left)))

        case let .wait(condition):
            switch condition {
            case let .duration(ms):
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            case let .stable(timeoutMs):
                // 默认微等待达到稳定状态
                try await Task.sleep(nanoseconds: min(UInt64(timeoutMs), 50) * 1_000_000)
            case .elementVisible, .elementGone:
                break
            }
        }
    }

    private func resolveTargetPoint(
        _ target: ActionTarget,
        observation: Observation
    ) throws -> LogicalPoint {
        switch target {
        case let .coordinate(targetPos):
            return try CoordinateTransform.toLogicalPoint(from: targetPos, displayMetrics: observation.displayMetrics)
        case let .element(ref):
            guard let node = observation.elements[ref] else {
                throw InteractionError.staleReference(.elementDisappeared(ref: ref))
            }
            guard let bounds = node.bounds else {
                throw InteractionError.actionExecution(.elementNotInteractable(ref: ref, reason: "Node bounds missing"))
            }
            let origin = try CoordinateTransform.toLogicalPoint(from: bounds.origin, displayMetrics: observation.displayMetrics)
            return LogicalPoint(x: origin.x + bounds.width / 2.0, y: origin.y + bounds.height / 2.0)
        }
    }

    private func extractTargetElementRef(from action: InteractionAction) -> ElementRef? {
        switch action {
        case let .browser(browserAction):
            switch browserAction {
            case let .primitive(primitive):
                return extractTargetElementRef(from: primitive)
            default:
                return nil
            }
        case let .desktop(desktopAction):
            switch desktopAction {
            case let .primitive(primitive):
                return extractTargetElementRef(from: primitive)
            default:
                return nil
            }
        }
    }

    private func extractTargetElementRef(from primitive: CommonInteractionPrimitive) -> ElementRef? {
        switch primitive {
        case let .click(target, _, _), let .hover(target):
            if case let .element(ref) = target { return ref }
            return nil
        case let .type(_, target):
            if let target, case let .element(ref) = target { return ref }
            return nil
        case let .scroll(target, _, _):
            if let target, case let .element(ref) = target { return ref }
            return nil
        case let .drag(from, _):
            if case let .element(ref) = from { return ref }
            return nil
        case let .wait(condition):
            if case let .elementVisible(ref, _) = condition { return ref }
            if case let .elementGone(ref, _) = condition { return ref }
            return nil
        case .keyPress:
            return nil
        }
    }
}
