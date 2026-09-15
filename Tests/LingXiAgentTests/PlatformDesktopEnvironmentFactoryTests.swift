import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform

@Suite("Cross Platform Desktop Environment Factory Tests")
struct PlatformDesktopEnvironmentFactoryTests {

    @Test("makeCurrentPlatformDefault returns a functional environment for current host")
    func testCurrentPlatformDefaultEnvironment() async throws {
        let env = DesktopEnvironment.makeCurrentPlatformDefault()

        let snapshot = await env.refreshCapabilities()

        #if os(macOS)
        #expect(env.capture != nil)
        #expect(env.accessibility != nil)
        #expect(env.input != nil)
        #expect(snapshot.windowManagement == .available)
        #expect(snapshot.applicationManagement == .available)
        #expect(snapshot.clipboard == .available)
        #elseif os(Linux)
        // Linux 平台下
        #expect(snapshot.applicationManagement == .available)
        #elseif os(Windows)
        // Windows 平台下
        #expect(snapshot.applicationManagement == .available)
        #endif
    }
}
