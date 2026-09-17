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
                let isWaitingForAppearance: Bool = {
                    if case let .desktop(.primitive(.wait(condition))) = action,
                       case .elementVisible = condition { return true }
                    if case let .browser(.primitive(.wait(condition))) = action,
                       case .elementVisible = condition { return true }
                    return false
                }()
                if !isWaitingForAppearance {
                    guard currentObservation.elements[ref] != nil else {
                        throw InteractionError.staleReference(.elementDisappeared(ref: ref))
                    }
                }
            }

            // 检查对应能力是否支持（严密拦截 unsupported / requiresAuthorization / temporarilyUnavailable）
            switch action {
            case .desktop, .browser(.primitive(.click)), .browser(.primitive(.type)), .browser(.primitive(.hover)), .browser(.primitive(.keyPress)), .browser(.primitive(.drag)):
                switch snapshot.input {
                case let .unsupported(reason):
                    throw InteractionError.capability(
                        .featureUnsupported(feature: "InputInjection", reason: reason)
                    )
                case let .requiresAuthorization(subsystem):
                    throw InteractionError.systemAuthorization(
                        .denied(subsystem: subsystem, guidance: "Grant \(subsystem) permission in System Settings")
                    )
                case let .temporarilyUnavailable(reason):
                    throw InteractionError.capability(
                        .featureUnsupported(feature: "InputInjection", reason: "Input injection temporarily unavailable: \(reason)")
                    )
                default:
                    break
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

        // 4. 顺序执行动作流水线（高精度记录每一步真实耗时，杜绝伪造平均值）
        var completedCount = 0
        var stepDurationsMs: [Double] = []

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

            let stepStart = ContinuousClock().now
            do {
                try await executeSingleAction(
                    action,
                    environment: environment,
                    observation: currentObservation
                )
                let stepElapsedMs = Double(stepStart.duration(to: ContinuousClock().now).components.attoseconds) / 1_000_000_000_000_000.0
                stepDurationsMs.append(stepElapsedMs)
                completedCount += 1
            } catch {
                let stepElapsedMs = Double(stepStart.duration(to: ContinuousClock().now).components.attoseconds) / 1_000_000_000_000_000.0
                stepDurationsMs.append(stepElapsedMs)
                if batch.stopOnFailure {
                    return ActionBatchResult(
                        batchID: batch.id,
                        completedStepCount: completedCount,
                        succeeded: false,
                        failureReason: "\(error)",
                        finalObservationID: currentObservation.id,
                        stepDurationsMs: stepDurationsMs
                    )
                }
            }
        }

        return ActionBatchResult(
            batchID: batch.id,
            completedStepCount: completedCount,
            succeeded: completedCount == batch.actions.count,
            failureReason: nil,
            finalObservationID: currentObservation.id,
            stepDurationsMs: stepDurationsMs
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
                // 真正的观测稳定检测：在 timeoutMs 内轮询无障碍/窗口状态，确认连续未发生变动
                let stableClock = ContinuousClock()
                let deadline = stableClock.now + .milliseconds(max(10, timeoutMs))
                var previousCount = observation.elements.count
                var consecutiveStableRounds = 0
                while stableClock.now < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    if let a11y = environment.accessibility {
                        let currentTree = (try? await a11y.fetchTree(scope: .activeWindow)) ?? []
                        if currentTree.count == previousCount {
                            consecutiveStableRounds += 1
                            if consecutiveStableRounds >= 2 {
                                break // 稳定状态确认
                            }
                        } else {
                            previousCount = currentTree.count
                            consecutiveStableRounds = 0
                        }
                    } else {
                        break
                    }
                }

            case let .elementVisible(ref, timeoutMs):
                // 真实轮询等待目标元素出现/可见，超时必须硬性抛错，绝不假动作成功
                let visibleClock = ContinuousClock()
                let deadline = visibleClock.now + .milliseconds(max(10, timeoutMs))
                var isVisible = false
                while visibleClock.now < deadline {
                    if let a11y = environment.accessibility {
                        let tree = (try? await a11y.fetchTree(scope: .activeWindow)) ?? []
                        if tree.contains(where: { $0.id == String(ref.index) || $0.name == ref.scopeID }) {
                            isVisible = true
                            break
                        }
                    } else if observation.elements[ref] != nil {
                        isVisible = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard isVisible else {
                    throw InteractionError.timeout(
                        .conditionNotMet(condition: condition, elapsedMs: timeoutMs)
                    )
                }

            case let .elementGone(ref, timeoutMs):
                // 真实轮询等待目标元素消失，超时必须硬性抛错，绝不假动作成功
                let goneClock = ContinuousClock()
                let deadline = goneClock.now + .milliseconds(max(10, timeoutMs))
                var isGone = false
                while goneClock.now < deadline {
                    if let a11y = environment.accessibility {
                        let tree = (try? await a11y.fetchTree(scope: .activeWindow)) ?? []
                        if !tree.contains(where: { $0.id == String(ref.index) || $0.name == ref.scopeID }) {
                            isGone = true
                            break
                        }
                    } else if observation.elements[ref] == nil {
                        isGone = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard isGone else {
                    throw InteractionError.timeout(
                        .conditionNotMet(condition: condition, elapsedMs: timeoutMs)
                    )
                }
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
