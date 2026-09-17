import Foundation

// MARK: - Identifiers & Scopes

public struct ObservationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct EnvironmentSessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ElementRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let sessionID: EnvironmentSessionID
    public let scopeID: String
    public let version: Int64
    public let index: Int

    public init(sessionID: EnvironmentSessionID, scopeID: String, version: Int64, index: Int) {
        self.sessionID = sessionID
        self.scopeID = scopeID
        self.version = version
        self.index = index
    }

    public var description: String { "ref_\(index)@v\(version)" }
}

// MARK: - Geometry & Display Metrics

public enum CoordinateSpace: Sendable, Codable, Equatable {
    case physicalPixel(displayID: String)
    case logicalPoint(displayID: String)
    case normalized(displayID: String)
    case windowLocal(windowID: String)
    case browserViewport(tabID: String)
}

public struct LogicalPoint: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TargetPosition: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let space: CoordinateSpace

    public init(x: Double, y: Double, space: CoordinateSpace) {
        self.x = x
        self.y = y
        self.space = space
    }
}

public struct CoordinateRect: Sendable, Codable, Equatable {
    public let origin: TargetPosition
    public let width: Double
    public let height: Double

    public init(origin: TargetPosition, width: Double, height: Double) {
        self.origin = origin
        self.width = width
        self.height = height
    }
}

public struct NormalizedRect: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DisplayMetrics: Sendable, Codable, Equatable {
    public let displayID: String
    public let scaleFactor: Double
    public let bounds: CoordinateRect

    public init(displayID: String, scaleFactor: Double, bounds: CoordinateRect) {
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.bounds = bounds
    }
}

// MARK: - Accessibility Node Snapshot

public struct AccessibilityNodeSnapshot: Sendable, Codable, Equatable {
    public let id: String
    public let role: String
    public let name: String?
    public let value: String?
    public let isInteractable: Bool
    public let bounds: CoordinateRect?
    public let attributes: [String: String]

    public init(
        id: String,
        role: String,
        name: String? = nil,
        value: String? = nil,
        isInteractable: Bool = true,
        bounds: CoordinateRect? = nil,
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.value = value
        self.isInteractable = isInteractable
        self.bounds = bounds
        self.attributes = attributes
    }
}

// MARK: - Observation

public enum ObservationSource: Sendable, Codable, Equatable {
    case browser(tabID: String, url: String, title: String)
    case desktop(displayID: String, activeWindowID: String?)
}

public struct Observation: Sendable, Codable, Equatable {
    public let id: ObservationID
    public let sessionID: EnvironmentSessionID
    public let version: Int64
    public let observedAt: Date
    public let source: ObservationSource
    public let elements: [ElementRef: AccessibilityNodeSnapshot]
    public let screenshotBlobRef: String?
    public let viewportBounds: CoordinateRect
    public let displayMetrics: DisplayMetrics

    public init(
        id: ObservationID = ObservationID(),
        sessionID: EnvironmentSessionID,
        version: Int64,
        observedAt: Date = Date(),
        source: ObservationSource,
        elements: [ElementRef: AccessibilityNodeSnapshot],
        screenshotBlobRef: String? = nil,
        viewportBounds: CoordinateRect,
        displayMetrics: DisplayMetrics
    ) {
        self.id = id
        self.sessionID = sessionID
        self.version = version
        self.observedAt = observedAt
        self.source = source
        self.elements = elements
        self.screenshotBlobRef = screenshotBlobRef
        self.viewportBounds = viewportBounds
        self.displayMetrics = displayMetrics
    }
}

// MARK: - Actions & Primitives

public enum PointerButton: String, Sendable, Codable {
    case left
    case right
    case middle
}

public struct KeyModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let option = KeyModifiers.alt
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public enum ActionTarget: Sendable, Codable, Equatable {
    case element(ElementRef)
    case coordinate(TargetPosition)
}

public enum CommonWaitCondition: Sendable, Codable, Equatable {
    case duration(milliseconds: Int)
    case stable(timeoutMs: Int)
    case elementVisible(ref: ElementRef, timeoutMs: Int)
    case elementGone(ref: ElementRef, timeoutMs: Int)
}

/// 跨环境通用的基础输入交互原语
public enum CommonInteractionPrimitive: Sendable, Codable, Equatable {
    case click(target: ActionTarget, button: PointerButton, count: Int)
    case hover(target: ActionTarget)
    case type(text: String, target: ActionTarget?)
    case keyPress(key: String, modifiers: KeyModifiers)
    case scroll(target: ActionTarget?, deltaX: Double, deltaY: Double)
    case drag(from: ActionTarget, to: ActionTarget)
    case wait(condition: CommonWaitCondition)
}

/// 浏览器专有交互动作
public enum BrowserAction: Sendable, Codable, Equatable {
    case primitive(CommonInteractionPrimitive)
    case navigate(url: String)
    case reload
    case goBack
    case waitForURL(pattern: String, timeoutMs: Int)
}

/// 桌面环境专有交互动作
public enum DesktopAction: Sendable, Codable, Equatable {
    case primitive(CommonInteractionPrimitive)
    case activateWindow(windowID: String)
    case moveWindow(windowID: String, bounds: CoordinateRect)
    case launchApp(identifier: String)
    case terminateApp(identifier: String)
}

/// 顶层交互动作包装
public enum InteractionAction: Sendable, Codable, Equatable {
    case browser(BrowserAction)
    case desktop(DesktopAction)
}

// MARK: - ActionBatch & Results

public struct ActionBatch: Sendable, Codable, Equatable {
    public let id: UUID
    public let actions: [InteractionAction]
    public let stopOnFailure: Bool
    public let intentHint: String?

    public init(
        id: UUID = UUID(),
        actions: [InteractionAction],
        stopOnFailure: Bool = true,
        intentHint: String? = nil
    ) {
        self.id = id
        self.actions = actions
        self.stopOnFailure = stopOnFailure
        self.intentHint = intentHint
    }
}

public struct ActionBatchResult: Sendable, Codable, Equatable {
    public let batchID: UUID
    public let completedStepCount: Int
    public let succeeded: Bool
    public let failureReason: String?
    public let finalObservationID: ObservationID?
    public let stepDurationsMs: [Double]

    public init(
        batchID: UUID,
        completedStepCount: Int,
        succeeded: Bool,
        failureReason: String? = nil,
        finalObservationID: ObservationID? = nil,
        stepDurationsMs: [Double] = []
    ) {
        self.batchID = batchID
        self.completedStepCount = completedStepCount
        self.succeeded = succeeded
        self.failureReason = failureReason
        self.finalObservationID = finalObservationID
        self.stepDurationsMs = stepDurationsMs
    }
}
