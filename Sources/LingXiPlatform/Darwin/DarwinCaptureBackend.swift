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

        guard let displayIDVal = UInt32(source.id) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Invalid display ID: \(source.id)")
        }

        guard let cgImage = CGDisplayCreateImage(displayIDVal) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to capture CGImage from display \(source.id)")
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

        return CapturedFrame(
            data: mutableData as Data,
            pixelWidth: finalImage.width,
            pixelHeight: finalImage.height,
            scaleFactor: 2.0 // macOS Retina 常见缩放比
        )
    }
}
#endif
