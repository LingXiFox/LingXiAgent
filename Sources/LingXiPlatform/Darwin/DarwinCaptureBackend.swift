#if os(macOS)
import Cocoa
import CoreGraphics
import ImageIO
import LingXiProtocol

public final class DarwinCaptureBackend: CaptureBackend, @unchecked Sendable {
    public init() {}

    public func availableSources() async throws -> [CaptureSource] {
        var sources: [CaptureSource] = []

        // 1. 获取主屏幕与外接显示器
        var displayCount: UInt32 = 0
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))

        if CGGetActiveDisplayList(maxDisplays, &displays, &displayCount) == .success {
            for i in 0..<Int(displayCount) {
                let dID = displays[i]
                let isMain = CGDisplayIsMain(dID) != 0
                sources.append(CaptureSource(
                    id: String(dID),
                    name: isMain ? "Main Display" : "External Display \(dID)",
                    isDisplay: true
                ))
            }
        }

        return sources
    }

    public func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame {
        // 权限前置检查
        if #available(macOS 10.15, *) {
            guard CGPreflightScreenCaptureAccess() else {
                throw SystemAuthorizationError.denied(
                    subsystem: "screenRecording",
                    guidance: "Grant Screen Recording permission in System Settings -> Privacy & Security -> Screen Recording"
                )
            }
        }

        let cgImage: CGImage
        let targetDisplayID: UInt32

        if source.kind == .window || source.windowID != nil, let winID = source.windowID ?? UInt32(source.id) {
            guard let winImg = CGWindowListCreateImage(.null, .optionIncludingWindow, winID, [.bestResolution]) else {
                throw ActionExecutionError.inputInjectionFailed(reason: "Failed to capture window image for windowID: \(winID)")
            }
            cgImage = winImg
            targetDisplayID = CGMainDisplayID()
        } else {
            guard let displayIDVal = UInt32(source.id) else {
                throw ActionExecutionError.inputInjectionFailed(reason: "Invalid display ID: \(source.id)")
            }
            guard let img = CGDisplayCreateImage(displayIDVal) else {
                throw ActionExecutionError.inputInjectionFailed(reason: "Failed to capture CGImage from display \(source.id)")
            }
            cgImage = img
            targetDisplayID = displayIDVal
        }

        let width = cgImage.width
        let height = cgImage.height

        // 处理可选裁剪 (NormalizedRect 0.0~1.0 -> 像素坐标)
        let finalImage: CGImage
        if let crop = cropRect {
            let cropX = crop.x * Double(width)
            let cropY = crop.y * Double(height)
            let cropW = crop.width * Double(width)
            let cropH = crop.height * Double(height)
            let rect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            finalImage = cgImage.cropping(to: rect) ?? cgImage
        } else {
            finalImage = cgImage
        }

        // 编码为 PNG Data
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, finalImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to finalize image destination")
        }

        let dynamicScaleFactor: Double = {
            if let mode = CGDisplayCopyDisplayMode(targetDisplayID) {
                let pixelW = mode.pixelWidth
                let logW = mode.width
                if logW > 0 {
                    return Double(pixelW) / Double(logW)
                }
            }
            let screens = NSScreen.screens
            if let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == targetDisplayID
            }) {
                return Double(screen.backingScaleFactor)
            }
            return 2.0
        }()

        return CapturedFrame(
            data: mutableData as Data,
            pixelWidth: finalImage.width,
            pixelHeight: finalImage.height,
            scaleFactor: dynamicScaleFactor
        )
    }
}
#endif
