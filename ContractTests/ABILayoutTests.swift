import Testing
import LingXiPluginABI

/// The layout pins. A field reordering or a widened integer moves one of these numbers, so the check
/// fails before a plugin ever loads. The values are repeated in ABI-MANIFEST once the live load tests
/// pass.
@Test("PLG-015 the boundary structs keep their published size and offsets")
func PLG_015_boundaryStructLayoutIsPinned() {
    #expect(MemoryLayout<LingXiStatus>.size == 12)
    #expect(MemoryLayout<LingXiStatus>.stride == 12)
    #expect(MemoryLayout<LingXiStatus>.offset(of: \.structSize) == 0)
    #expect(MemoryLayout<LingXiStatus>.offset(of: \.abiMajor) == 4)
    #expect(MemoryLayout<LingXiStatus>.offset(of: \.code) == 8)

    // 8 bytes of header plus seven pointers.
    #expect(MemoryLayout<LingXiPluginAPI>.size == 64)
    #expect(MemoryLayout<LingXiPluginAPI>.offset(of: \.abiMajor) == 4)
    #expect(MemoryLayout<LingXiPluginAPI>.offset(of: \.describe) == 8)
    #expect(MemoryLayout<LingXiPluginAPI>.offset(of: \.free) == 56)

    // 8 bytes of header plus two callbacks.
    #expect(MemoryLayout<LingXiHostAPI>.size == 24)
    #expect(LingXiABI.major == 1)
    #expect(LingXiStatus.make().structSize == 12)
    #expect(LingXiStatus.make(.abiViolation).statusCode == .abiViolation)
}
