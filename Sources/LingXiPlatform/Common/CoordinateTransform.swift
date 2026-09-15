import Foundation
import LingXiProtocol

/// 跨平台坐标几何空间变换引擎。
/// 负责在物理像素坐标、模型归一化坐标、窗口局部坐标与系统逻辑点坐标之间进行严格无歧义的转换。
/// 转换失败时强制抛出强类型错误，绝对杜绝静默返回裸坐标导致的漂移点击事故。
public struct CoordinateTransform: Sendable {

    /// 将任意坐标空间的目标位置精准转换为操作系统逻辑点坐标（用于原生输入事件注入）
    public static func toLogicalPoint(
        from target: TargetPosition,
        displayMetrics: DisplayMetrics,
        windowBounds: CoordinateRect? = nil
    ) throws -> LogicalPoint {
        switch target.space {
        case let .logicalPoint(targetDisplayID):
            guard targetDisplayID.isEmpty || targetDisplayID == displayMetrics.displayID else {
                throw CoordinateTransformError.unsupportedSpace("Display mismatch: target=\(targetDisplayID), current=\(displayMetrics.displayID)")
            }
            return LogicalPoint(x: target.x, y: target.y)

        case let .physicalPixel(targetDisplayID):
            guard targetDisplayID.isEmpty || targetDisplayID == displayMetrics.displayID else {
                throw CoordinateTransformError.unsupportedSpace("Display mismatch: target=\(targetDisplayID), current=\(displayMetrics.displayID)")
            }
            guard displayMetrics.scaleFactor > 0 else {
                throw CoordinateTransformError.invalidScaleFactor(displayMetrics.scaleFactor)
            }
            return LogicalPoint(
                x: target.x / displayMetrics.scaleFactor,
                y: target.y / displayMetrics.scaleFactor
            )

        case let .normalized(targetDisplayID):
            guard targetDisplayID.isEmpty || targetDisplayID == displayMetrics.displayID else {
                throw CoordinateTransformError.unsupportedSpace("Display mismatch: target=\(targetDisplayID), current=\(displayMetrics.displayID)")
            }
            guard target.x >= 0.0 && target.x <= 1.0 && target.y >= 0.0 && target.y <= 1.0 else {
                throw CoordinateTransformError.coordinateOutOfBounds(x: target.x, y: target.y)
            }
            let logicalOrigin = try toLogicalPoint(from: displayMetrics.bounds.origin, displayMetrics: displayMetrics)
            return LogicalPoint(
                x: logicalOrigin.x + target.x * displayMetrics.bounds.width,
                y: logicalOrigin.y + target.y * displayMetrics.bounds.height
            )

        case .windowLocal:
            guard let windowBounds else {
                throw CoordinateTransformError.missingWindowContext
            }
            let windowOrigin = try toLogicalPoint(from: windowBounds.origin, displayMetrics: displayMetrics)
            return LogicalPoint(
                x: windowOrigin.x + target.x,
                y: windowOrigin.y + target.y
            )

        case let .browserViewport(tabID):
            throw CoordinateTransformError.unsupportedSpace("browserViewport (\(tabID)) requires page DOM layout context")
        }
    }
}
