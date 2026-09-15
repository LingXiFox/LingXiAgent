#if os(macOS)
import Cocoa
import QuartzCore
import LingXiProtocol

/// macOS 桌面层虚拟发光指针悬浮窗。
/// 特性：
/// 1. 绝对鼠标穿透 (ignoresMouseEvents = true)，完全不阻碍底层任何操作，不与硬件鼠标冲突；
/// 2. 不抢占系统焦点 (nonactivatingPanel)，不在 Dock 栏显示图标；
/// 3. GPU 硬件加速动画：包含小狐狸专属荧光光标、平滑跟随与点击扩散光晕涟漪 (Click Ripple)。
@MainActor
public final class DarwinVirtualPointerOverlay: NSObject, @unchecked Sendable {
    public static let shared = DarwinVirtualPointerOverlay()

    private var panel: NSPanel?
    private var cursorLayer: CALayer?
    private var rippleLayer: CALayer?
    private var targetFrameLayer: CAShapeLayer?
    private var isInitialized = false

    private override init() {
        super.init()
    }

    /// 确保覆盖层窗口与图层已初始化
    public func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        // 设置为辅助进程模式，避免在 Dock 栏出现窗口图标
        NSApplication.shared.setActivationPolicy(.accessory)

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let overlayPanel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        overlayPanel.isOpaque = false
        overlayPanel.backgroundColor = .clear
        overlayPanel.hasShadow = false
        overlayPanel.ignoresMouseEvents = true // 核心：完全鼠标穿透！绝不拦截任何物理操作
        overlayPanel.level = .floating        // 置顶浮动在常规窗口之上
        overlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: screenFrame)
        contentView.wantsLayer = true
        guard let rootLayer = contentView.layer else { return }

        // 1. 虚拟光标图层 (Cyber Fox 荧光指针，增大尺寸并增强发光光晕)
        let cLayer = CALayer()
        cLayer.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        cLayer.anchorPoint = CGPoint(x: 0.2, y: 0.8) // 尖端为锚点
        cLayer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        cLayer.cornerRadius = 17
        cLayer.borderWidth = 2.5
        cLayer.borderColor = NSColor.white.cgColor
        cLayer.shadowColor = NSColor.orange.cgColor
        cLayer.shadowOpacity = 1.0
        cLayer.shadowRadius = 14.0
        cLayer.shadowOffset = CGSize(width: 0, height: 0)
        cLayer.opacity = 0.0 // 初始隐藏

        // 内部小光点装饰
        let dotLayer = CALayer()
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        dotLayer.position = CGPoint(x: 17, y: 17)
        dotLayer.cornerRadius = 5
        dotLayer.backgroundColor = NSColor.white.cgColor
        cLayer.addSublayer(dotLayer)

        rootLayer.addSublayer(cLayer)
        self.cursorLayer = cLayer

        // 2. 点击扩散光圈涟漪图层 (更大、更清澈的霓虹青扩散波纹)
        let rLayer = CALayer()
        rLayer.bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        rLayer.cornerRadius = 40
        rLayer.borderWidth = 3.0
        rLayer.borderColor = NSColor.cyan.cgColor
        rLayer.backgroundColor = NSColor.cyan.withAlphaComponent(0.3).cgColor
        rLayer.opacity = 0.0
        rootLayer.addSublayer(rLayer)
        self.rippleLayer = rLayer

        // 3. 目标应用/窗口劫持锁定高亮框 (Target Scoping Frame)
        let fLayer = CAShapeLayer()
        fLayer.lineWidth = 3.0
        fLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        fLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.04).cgColor
        fLayer.lineDashPattern = [8, 6]
        fLayer.shadowColor = NSColor.orange.cgColor
        fLayer.shadowOpacity = 0.8
        fLayer.shadowRadius = 8.0
        fLayer.opacity = 0.0
        rootLayer.addSublayer(fLayer)
        self.targetFrameLayer = fLayer

        overlayPanel.contentView = contentView
        overlayPanel.orderFrontRegardless()
        self.panel = overlayPanel
    }

    /// 移动虚拟光标到指定屏幕坐标（带可配置的慢动作平滑缓动）
    public func move(to point: LogicalPoint, duration: Double = 0.45, animated: Bool = true) {
        ensureInitialized()
        guard let cursorLayer, let screen = NSScreen.main else { return }

        let screenHeight = screen.frame.height
        let cocoaY = screenHeight - point.y
        let targetPosition = CGPoint(x: point.x, y: cocoaY)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        cursorLayer.opacity = 0.95
        cursorLayer.position = targetPosition
        CATransaction.commit()
    }

    /// 触发醒目的点击光圈扩散特效 (Ripple Animation)
    public func playClickEffect(at point: LogicalPoint, button: PointerButton = .left, duration: Double = 0.5) {
        ensureInitialized()
        guard let rippleLayer, let screen = NSScreen.main else { return }

        let screenHeight = screen.frame.height
        let cocoaY = screenHeight - point.y
        let center = CGPoint(x: point.x, y: cocoaY)

        let color: CGColor = {
            switch button {
            case .left: return NSColor.systemOrange.cgColor
            case .right: return NSColor.systemPurple.cgColor
            case .middle: return NSColor.systemBlue.cgColor
            }
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rippleLayer.position = center
        rippleLayer.borderColor = color
        rippleLayer.backgroundColor = color.copy(alpha: 0.35)
        rippleLayer.transform = CATransform3DMakeScale(0.2, 0.2, 1.0)
        rippleLayer.opacity = 1.0
        CATransaction.commit()

        // 缩放扩散与渐隐动画
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.2
        scaleAnim.toValue = 2.2
        scaleAnim.duration = duration
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0
        fadeAnim.duration = duration
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        rippleLayer.add(group, forKey: "clickRipple")
    }

    /// 绑定并高亮显示目标窗口区域（让主人明确获知 Agent 当前锁定在哪个 App/窗口）
    public func attachTargetBounds(_ bounds: CoordinateRect?) {
        ensureInitialized()
        guard let targetFrameLayer, let screen = NSScreen.main else { return }

        guard let bounds, bounds.width > 0, bounds.height > 0 else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            targetFrameLayer.opacity = 0.0
            CATransaction.commit()
            return
        }

        let screenHeight = screen.frame.height
        let cocoaY = screenHeight - (bounds.origin.y + bounds.height)
        let frameRect = CGRect(x: bounds.origin.x, y: cocoaY, width: bounds.width, height: bounds.height)

        let path = CGPath(roundedRect: frameRect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        targetFrameLayer.path = path
        targetFrameLayer.opacity = 1.0
        CATransaction.commit()
    }

    /// 优雅淡出隐藏虚拟光标与目标框
    public func hide(duration: Double = 0.6) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        cursorLayer?.opacity = 0.0
        targetFrameLayer?.opacity = 0.0
        CATransaction.commit()
    }
}
#endif
