import Darwin
import Foundation

enum PoCError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(value) = self { return value }; return "unknown error" }
}

private typealias U32 = UInt32
private typealias Handle = U32
private typealias Ptr = UnsafeMutableRawPointer
private typealias YogaNode = UnsafeMutableRawPointer

private final class OpenTUI {
    let image: UnsafeMutableRawPointer

    typealias CreateRenderer = @convention(c) (U32, U32, UInt8, UInt8, Ptr?) -> Handle
    typealias DestroyRenderer = @convention(c) (Handle, Bool) -> Void
    typealias Render = @convention(c) (Handle, Bool) -> UInt8
    typealias ResizeRenderer = @convention(c) (Handle, U32, U32) -> Void
    typealias GetBuffer = @convention(c) (Handle) -> Handle
    typealias CreateBuffer = @convention(c) (U32, U32, UInt8, UInt8, Ptr?, U32) -> Handle
    typealias DestroyBuffer = @convention(c) (Handle) -> Void
    typealias BufferSize = @convention(c) (Handle) -> U32
    typealias BufferClear = @convention(c) (Handle, Ptr) -> Void
    typealias DrawText = @convention(c) (Handle, Ptr?, U32, U32, U32, Ptr, Ptr?, U32) -> Void
    typealias BufferCharSize = @convention(c) (Handle) -> U32
    typealias EncodeUnicode = @convention(c) (Ptr?, U32, Ptr, Ptr, UInt8) -> Bool
    typealias FreeUnicode = @convention(c) (Ptr, U32) -> Void
    typealias CreateTextBuffer = @convention(c) (UInt8) -> Handle
    typealias DestroyTextBuffer = @convention(c) (Handle) -> Void
    typealias TextAppend = @convention(c) (Handle, Ptr?, U32) -> Void
    typealias CreateTextView = @convention(c) (Handle) -> Handle
    typealias DestroyTextView = @convention(c) (Handle) -> Void
    typealias ViewportSize = @convention(c) (Handle, U32, U32) -> Void
    typealias Viewport = @convention(c) (Handle, U32, U32, U32, U32) -> Void
    typealias VirtualLineCount = @convention(c) (Handle) -> U32
    typealias CreateEditBuffer = @convention(c) (UInt8, U32) -> Handle
    typealias DestroyEditBuffer = @convention(c) (Handle) -> Void
    typealias EditSetText = @convention(c) (Handle, Ptr?, U32) -> Void
    typealias EditSetCursor = @convention(c) (Handle, U32) -> Void
    typealias EditInsertText = @convention(c) (Handle, Ptr?, U32) -> Void
    typealias EditGetText = @convention(c) (Handle, Ptr?, U32) -> U32
    typealias YogaConfigCreate = @convention(c) () -> YogaNode?
    typealias YogaConfigFree = @convention(c) (YogaNode) -> Void
    typealias YogaNodeCreate = @convention(c) () -> YogaNode?
    typealias YogaNodeCreateWithConfig = @convention(c) (YogaNode) -> YogaNode?
    typealias YogaNodeFreeRecursive = @convention(c) (YogaNode) -> Void
    typealias YogaInsertChild = @convention(c) (YogaNode, YogaNode, U32) -> Void
    typealias YogaSetValue = @convention(c) (YogaNode, U32, U32, U32, Float) -> Void
    typealias YogaCalculate = @convention(c) (YogaNode, Float, Float, U32) -> Void
    typealias YogaGetLayout = @convention(c) (YogaNode, Ptr) -> Void

    let createRenderer: CreateRenderer
    let destroyRenderer: DestroyRenderer
    let render: Render
    let resizeRenderer: ResizeRenderer
    let getNextBuffer: GetBuffer
    let getCurrentBuffer: GetBuffer
    let createBuffer: CreateBuffer
    let destroyBuffer: DestroyBuffer
    let bufferWidth: BufferSize
    let bufferHeight: BufferSize
    let bufferClear: BufferClear
    let drawText: DrawText
    let bufferCharSize: BufferCharSize
    let encodeUnicode: EncodeUnicode
    let freeUnicode: FreeUnicode
    let createTextBuffer: CreateTextBuffer
    let destroyTextBuffer: DestroyTextBuffer
    let textAppend: TextAppend
    let createTextView: CreateTextView
    let destroyTextView: DestroyTextView
    let viewportSize: ViewportSize
    let viewport: Viewport
    let virtualLineCount: VirtualLineCount
    let createEditBuffer: CreateEditBuffer
    let destroyEditBuffer: DestroyEditBuffer
    let editSetText: EditSetText
    let editSetCursor: EditSetCursor
    let editInsertText: EditInsertText
    let editGetText: EditGetText
    let yogaConfigCreate: YogaConfigCreate
    let yogaConfigFree: YogaConfigFree
    let yogaNodeCreate: YogaNodeCreate
    let yogaNodeCreateWithConfig: YogaNodeCreateWithConfig
    let yogaNodeFreeRecursive: YogaNodeFreeRecursive
    let yogaInsertChild: YogaInsertChild
    let yogaSetValue: YogaSetValue
    let yogaCalculate: YogaCalculate
    let yogaGetLayout: YogaGetLayout

    init(path: String) throws {
        guard let image = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw PoCError.message("dlopen failed: \(String(cString: dlerror()))")
        }
        self.image = image
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let symbol = dlsym(image, name) else { throw PoCError.message("missing symbol: \(name)") }
            return unsafeBitCast(symbol, to: T.self)
        }
        createRenderer = try load("createRenderer", CreateRenderer.self)
        destroyRenderer = try load("destroyRenderer", DestroyRenderer.self)
        render = try load("render", Render.self)
        resizeRenderer = try load("resizeRenderer", ResizeRenderer.self)
        getNextBuffer = try load("getNextBuffer", GetBuffer.self)
        getCurrentBuffer = try load("getCurrentBuffer", GetBuffer.self)
        createBuffer = try load("createOptimizedBuffer", CreateBuffer.self)
        destroyBuffer = try load("destroyOptimizedBuffer", DestroyBuffer.self)
        bufferWidth = try load("getBufferWidth", BufferSize.self)
        bufferHeight = try load("getBufferHeight", BufferSize.self)
        bufferClear = try load("bufferClear", BufferClear.self)
        drawText = try load("bufferDrawText", DrawText.self)
        bufferCharSize = try load("bufferGetRealCharSize", BufferCharSize.self)
        encodeUnicode = try load("encodeUnicode", EncodeUnicode.self)
        freeUnicode = try load("freeUnicode", FreeUnicode.self)
        createTextBuffer = try load("createTextBuffer", CreateTextBuffer.self)
        destroyTextBuffer = try load("destroyTextBuffer", DestroyTextBuffer.self)
        textAppend = try load("textBufferAppend", TextAppend.self)
        createTextView = try load("createTextBufferView", CreateTextView.self)
        destroyTextView = try load("destroyTextBufferView", DestroyTextView.self)
        viewportSize = try load("textBufferViewSetViewportSize", ViewportSize.self)
        viewport = try load("textBufferViewSetViewport", Viewport.self)
        virtualLineCount = try load("textBufferViewGetVirtualLineCount", VirtualLineCount.self)
        createEditBuffer = try load("createEditBuffer", CreateEditBuffer.self)
        destroyEditBuffer = try load("destroyEditBuffer", DestroyEditBuffer.self)
        editSetText = try load("editBufferSetText", EditSetText.self)
        editSetCursor = try load("editBufferSetCursorByOffset", EditSetCursor.self)
        editInsertText = try load("editBufferInsertText", EditInsertText.self)
        editGetText = try load("editBufferGetText", EditGetText.self)
        yogaConfigCreate = try load("yogaConfigCreate", YogaConfigCreate.self)
        yogaConfigFree = try load("yogaConfigFree", YogaConfigFree.self)
        yogaNodeCreate = try load("yogaNodeCreate", YogaNodeCreate.self)
        yogaNodeCreateWithConfig = try load("yogaNodeCreateWithConfig", YogaNodeCreateWithConfig.self)
        yogaNodeFreeRecursive = try load("yogaNodeFreeRecursive", YogaNodeFreeRecursive.self)
        yogaInsertChild = try load("yogaNodeInsertChild", YogaInsertChild.self)
        yogaSetValue = try load("yogaNodeStyleSetValue", YogaSetValue.self)
        yogaCalculate = try load("yogaNodeCalculateLayout", YogaCalculate.self)
        yogaGetLayout = try load("yogaNodeGetComputedLayout", YogaGetLayout.self)
    }

    deinit { dlclose(image) }
}

private func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PoCError.message(message) }
}
private func callWithBytes<T>(_ value: String, _ body: (UnsafeMutableRawPointer?, U32) throws -> T) rethrows -> T {
    var data = bytes(value)
    return try data.withUnsafeMutableBytes { raw in try body(raw.baseAddress, U32(raw.count)) }
}

private func color(_ value: UInt16 = 0) -> [UInt16] { [value, value, value, UInt16.max] }

private func verifyRenderer(_ api: OpenTUI) throws {
    let renderer = api.createRenderer(24, 8, 1, 1, nil)
    try require(renderer != 0, "renderer handle is null")
    defer { api.destroyRenderer(renderer, false) }
    let buffer = api.getNextBuffer(renderer)
    try require(buffer != 0, "next frame buffer is null")
    var fg = color(UInt16.max)
    var bg = color()
    try callWithBytes("OpenTUI C ABI\n中文") { pointer, length in
        fg.withUnsafeMutableBytes { fgRaw in
            bg.withUnsafeMutableBytes { bgRaw in
                api.drawText(buffer, pointer, length, 0, 0, fgRaw.baseAddress!, bgRaw.baseAddress!, 0)
            }
        }
    }
    try require(api.bufferCharSize(buffer) > 0, "frame buffer did not receive text")
    _ = api.render(renderer, true)
    print("renderer/frame buffer: PASS")
}

private func verifyYoga(_ api: OpenTUI) throws {
    guard let config = api.yogaConfigCreate(), let root = api.yogaNodeCreateWithConfig(config), let child = api.yogaNodeCreateWithConfig(config) else {
        throw PoCError.message("Yoga allocation failed")
    }
    defer { api.yogaNodeFreeRecursive(root); api.yogaConfigFree(config) }
    api.yogaSetValue(root, 0, 0, 1, 20)
    api.yogaSetValue(root, 1, 0, 1, 8)
    api.yogaSetValue(child, 0, 0, 1, 10)
    api.yogaSetValue(child, 1, 0, 1, 2)
    api.yogaInsertChild(root, child, 0)
    api.yogaCalculate(root, 20, 8, 1)
    var layout = [Float](repeating: 0, count: 6)
    layout.withUnsafeMutableBytes { api.yogaGetLayout(child, $0.baseAddress!) }
    try require(layout[4] == 10 && layout[5] == 2, "Yoga computed layout mismatch: \(layout)")
    print("Yoga layout: PASS")
}

private func verifyCJKWidth(_ api: OpenTUI) throws {
    var input = bytes("A中")
    var pointerSlot = UInt64(0)
    var lengthSlot = UInt64(0)
    let ok = input.withUnsafeMutableBytes { raw in
        withUnsafeMutableBytes(of: &pointerSlot) { pointer in
            withUnsafeMutableBytes(of: &lengthSlot) { length in
                api.encodeUnicode(raw.baseAddress, U32(raw.count), pointer.baseAddress!, length.baseAddress!, 1)
            }
        }
    }
    try require(ok && lengthSlot == 2, "Unicode encoder returned unexpected length")
    let encoded = UnsafeMutableRawPointer(bitPattern: UInt(pointerSlot))!
    defer { api.freeUnicode(encoded, U32(lengthSlot)) }
    let secondWidth = encoded.load(fromByteOffset: 8, as: UInt8.self)
    try require(secondWidth == 2, "CJK width was \(secondWidth), expected 2")
    print("CJK text width: PASS")
}

private func verifyResize(_ api: OpenTUI) throws {
    let renderer = api.createRenderer(10, 4, 1, 1, nil)
    try require(renderer != 0, "renderer allocation failed")
    defer { api.destroyRenderer(renderer, false) }
    api.resizeRenderer(renderer, 30, 12)
    let buffer = api.getNextBuffer(renderer)
    try require(api.bufferWidth(buffer) == 30 && api.bufferHeight(buffer) == 12, "resize dimensions mismatch")
    print("resize: PASS")
}

private func verifyScrollViewport(_ api: OpenTUI) throws {
    let text = api.createTextBuffer(1)
    try require(text != 0, "TextBuffer allocation failed")
    defer { api.destroyTextBuffer(text) }
    try callWithBytes("one\ntwo\nthree\nfour\n") { pointer, length in api.textAppend(text, pointer, length) }
    let view = api.createTextView(text)
    try require(view != 0, "TextBufferView allocation failed")
    defer { api.destroyTextView(view) }
    api.viewportSize(view, 20, 2)
    api.viewport(view, 0, 1, 20, 2)
    try require(api.virtualLineCount(view) >= 4, "viewport lost text lines")
    print("scroll viewport: PASS")
}

private func verifyEditBuffer(_ api: OpenTUI) throws {
    let edit = api.createEditBuffer(1, 0)
    try require(edit != 0, "EditBuffer allocation failed")
    defer { api.destroyEditBuffer(edit) }
    try callWithBytes("abc") { pointer, length in api.editSetText(edit, pointer, length) }
    api.editSetCursor(edit, 1)
    try callWithBytes("X") { pointer, length in api.editInsertText(edit, pointer, length) }
    var output = [UInt8](repeating: 0, count: 32)
    let outputCapacity = U32(output.count)
    let count = output.withUnsafeMutableBytes { api.editGetText(edit, $0.baseAddress, outputCapacity) }
    let result = String(decoding: output.prefix(Int(count)), as: UTF8.self)
    try require(result == "aXbc", "EditBuffer result was \(result.debugDescription)")
    print("EditBuffer input: PASS")
}

private func verifyStreamingRedraw(_ api: OpenTUI) throws {
    let renderer = api.createRenderer(30, 4, 1, 1, nil)
    try require(renderer != 0, "renderer allocation failed")
    defer { api.destroyRenderer(renderer, false) }
    var fg = color(UInt16.max)
    var bg = color()
    for index in 0..<100 {
        let buffer = api.getNextBuffer(renderer)
        try callWithBytes("stream \(index)") { pointer, length in
            fg.withUnsafeMutableBytes { fgRaw in
                bg.withUnsafeMutableBytes { bgRaw in
                    api.drawText(buffer, pointer, length, 0, 0, fgRaw.baseAddress!, bgRaw.baseAddress!, 0)
                }
            }
        }
        _ = api.render(renderer, false)
    }
    try require(api.getCurrentBuffer(renderer) != 0, "current buffer disappeared after redraws")
    print("continuous streaming redraw: PASS")
}

do {
    let path = ProcessInfo.processInfo.environment["OPENTUI_LIB"] ?? ""
    try require(!path.isEmpty, "set OPENTUI_LIB to libopentui.dylib")
    let api = try OpenTUI(path: path)
    try verifyRenderer(api)
    try verifyYoga(api)
    try verifyCJKWidth(api)
    try verifyResize(api)
    try verifyScrollViewport(api)
    try verifyEditBuffer(api)
    try verifyStreamingRedraw(api)
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
