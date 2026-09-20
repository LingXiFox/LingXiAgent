#if os(macOS)
import Cocoa
import CoreGraphics
import Vision
import LingXiProtocol

/// 端侧本地原生视觉文字识别与定位后端 (DarwinVisionOCRBackend)。
/// 基于 macOS 系统原生 Vision.framework 纯本地离线执行（利用 Apple Silicon 神经引擎 NPU，耗时约 10~25ms）。
/// 作为无障碍树 (Accessibility Tree) 缺失、无法穿透或节点为空时的轻量级零依赖兜底桥。
public final class DarwinVisionOCRBackend: @unchecked Sendable {
    public static let shared = DarwinVisionOCRBackend()
    public init() {}

    /// 对指定窗口或全屏进行本地视觉 OCR 识别，提取画面中可见的文字与对应的屏幕像素坐标
    public func recognizeElements(
        windowID: String? = nil,
        windowBounds: CoordinateRect? = nil
    ) async throws -> [VisualElementSnapshot] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Without screen recording authorization the CoreGraphics capture calls below can
                // block indefinitely, permanently pinning a GCD worker thread and eventually
                // starving the whole pool. Preflight the permission before touching CG.
                guard CGPreflightScreenCaptureAccess() else {
                    continuation.resume(throwing: ActionExecutionError.inputInjectionFailed(
                        reason: "Screen recording authorization is unavailable for visual OCR"
                    ))
                    return
                }
                do {
                    let image: CGImage
                    let baseOriginX: Double
                    let baseOriginY: Double
                    let scaleFactor: Double = 2.0 // Retina 典型像素比

                    if let windowID, let winIDNum = UInt32(windowID) {
                        let winRect: CGRect
                        if let wb = windowBounds {
                            winRect = CGRect(x: wb.origin.x, y: wb.origin.y, width: wb.width, height: wb.height)
                            baseOriginX = wb.origin.x
                            baseOriginY = wb.origin.y
                        } else {
                            winRect = .null
                            baseOriginX = 0
                            baseOriginY = 0
                        }
                        guard let cgImg = CGWindowListCreateImage(winRect, .optionIncludingWindow, winIDNum, [.bestResolution]) else {
                            continuation.resume(throwing: ActionExecutionError.inputInjectionFailed(reason: "Failed to capture window image for OCR"))
                            return
                        }
                        image = cgImg
                    } else if let wb = windowBounds {
                        let winRect = CGRect(x: wb.origin.x, y: wb.origin.y, width: wb.width, height: wb.height)
                        guard let cgImg = CGWindowListCreateImage(winRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
                            continuation.resume(throwing: ActionExecutionError.inputInjectionFailed(reason: "Failed to capture screen rect for OCR"))
                            return
                        }
                        image = cgImg
                        baseOriginX = wb.origin.x
                        baseOriginY = wb.origin.y
                    } else {
                        guard let cgImg = CGDisplayCreateImage(CGMainDisplayID()) else {
                            continuation.resume(throwing: ActionExecutionError.inputInjectionFailed(reason: "Failed to capture main display for OCR"))
                            return
                        }
                        image = cgImg
                        baseOriginX = 0
                        baseOriginY = 0
                    }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesCPUOnly = false
                    if #available(macOS 13.0, *) {
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                    }

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    guard let observations = request.results else {
                        continuation.resume(returning: [])
                        return
                    }

                    let imageWidth = Double(image.width)
                    let imageHeight = Double(image.height)

                    var results: [VisualElementSnapshot] = []
                    var index = 1

                    for obs in observations {
                        guard let topCandidate = obs.topCandidates(1).first else { continue }
                        let recognizedText = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !recognizedText.isEmpty else { continue }

                        // Vision 框架返回归一化坐标 (0.0~1.0)，原点在左下角 (Bottom-Left)
                        // macOS 屏幕坐标原点在左上角 (Top-Left)，需进行坐标系翻转与像素缩放转换
                        let box = obs.boundingBox
                        let pixelX = box.origin.x * imageWidth
                        let pixelY = (1.0 - box.origin.y - box.size.height) * imageHeight
                        let pixelW = box.size.width * imageWidth
                        let pixelH = box.size.height * imageHeight

                        // 转换至逻辑点坐标
                        let logicalX = baseOriginX + (pixelX / scaleFactor)
                        let logicalY = baseOriginY + (pixelY / scaleFactor)
                        let logicalW = pixelW / scaleFactor
                        let logicalH = pixelH / scaleFactor

                        let rect = CoordinateRect(
                            origin: TargetPosition(x: logicalX, y: logicalY, space: .logicalPoint(displayID: "main")),
                            width: logicalW,
                            height: logicalH
                        )

                        results.append(VisualElementSnapshot(
                            id: "vision_ref_\(index)",
                            text: recognizedText,
                            bounds: rect,
                            confidence: topCandidate.confidence,
                            isInteractable: true
                        ))
                        index += 1
                    }

                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 在画面文字中搜索最匹配指定 query 的元素并返回其中心点击坐标
    public func findElement(
        matching query: String,
        windowID: String? = nil,
        windowBounds: CoordinateRect? = nil
    ) async throws -> (element: VisualElementSnapshot, center: LogicalPoint)? {
        let elements = try await recognizeElements(windowID: windowID, windowBounds: windowBounds)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. 精确或包含匹配
        if let directHit = elements.first(where: {
            $0.text.lowercased() == trimmedQuery || $0.text.localizedCaseInsensitiveContains(trimmedQuery)
        }) {
            let cx = directHit.bounds.origin.x + directHit.bounds.width / 2.0
            let cy = directHit.bounds.origin.y + directHit.bounds.height / 2.0
            return (directHit, LogicalPoint(x: cx, y: cy))
        }

        // 2. 分词重合匹配（如搜 "检索" 命中 "执行检索"）
        let tokens = trimmedQuery.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
        if !tokens.isEmpty {
            if let tokenHit = elements.first(where: { item in
                let lower = item.text.lowercased()
                return tokens.contains(where: { lower.contains($0) })
            }) {
                let cx = tokenHit.bounds.origin.x + tokenHit.bounds.width / 2.0
                let cy = tokenHit.bounds.origin.y + tokenHit.bounds.height / 2.0
                return (tokenHit, LogicalPoint(x: cx, y: cy))
            }
        }

        return nil
    }
}
#endif
