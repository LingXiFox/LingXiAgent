import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiApplication
@testable import LingXiTUI

@Suite("Platform Abstraction & TUI-Core Decoupling Tests")
struct PlatformAbstractionAndDecouplingTests {

    @Test func jsonNumbersAreNotMisclassifiedAsBooleans() throws {
        // Every NSNumber bridges leniently to Bool, so `value is Bool` cannot tell a JSON
        // integer from a JSON boolean. That made `"version": 1` validate as a boolean on
        // Windows, so the config schema rejected the shipped defaults it ships correctly.
        let json = #"{"version": 1, "enabled": true, "ratio": 0.5, "count": 0}"#
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        #expect(!LingXiPlatform.types.isBoolean(parsed["version"]!))
        #expect(LingXiPlatform.types.isBoolean(parsed["enabled"]!))
        #expect(!LingXiPlatform.types.isBoolean(parsed["ratio"]!))
        #expect(!LingXiPlatform.types.isBoolean(parsed["count"]!))

        #expect(LingXiPlatform.types.isInteger(parsed["version"]!))
        #expect(LingXiPlatform.types.isInteger(parsed["count"]!))
        #expect(!LingXiPlatform.types.isInteger(parsed["enabled"]!))
        #expect(!LingXiPlatform.types.isInteger(parsed["ratio"]!))
        #expect(!LingXiPlatform.types.isNumber(parsed["enabled"]!))
        #expect(LingXiPlatform.types.isNumber(parsed["ratio"]!))

        // Char-backed integers must not be mistaken for booleans: objCType reports "c" for
        // them as well, so the CoreFoundation type ID has to decide this on Darwin.
        #expect(!LingXiPlatform.types.isBoolean(NSNumber(value: Int8(1))))

        // Same contract for values that never went through NSNumber.
        #expect(LingXiPlatform.types.isBoolean(true))
        #expect(!LingXiPlatform.types.isBoolean(1))
    }

    @MainActor
    @Test func frontendProtocolAndTUIConformance() async {
        let tui = ApplicationTUI()
        // 验证 ApplicationTUI 遵循 Frontend 协议
        let frontend: any Frontend = tui
        #expect(frontend is ApplicationTUI)
    }

    @Test func compositionRootConfigurationBridging() {
        let options = TUILaunchOptions(
            initialPrompt: "Test prompt",
            initialModelID: "test-model",
            isYoloMode: true,
            reasoningEffort: .high,
            resumeSessionID: "sess-123"
        )
        let config = options.applicationConfiguration
        #expect(config.initialPrompt == "Test prompt")
        #expect(config.initialModelID == "test-model")
        #expect(config.isYoloMode == true)
        #expect(config.reasoningEffort == .high)
        #expect(config.resumeSessionID == "sess-123")

        let root = AppCompositionRoot(configuration: config)
        #expect(root.configuration == config)
    }

    @Test func platformSystemIdentity() {
        let osName = LingXiPlatform.system.osName
        let archName = LingXiPlatform.system.archName
        #expect(!osName.isEmpty)
        #expect(!archName.isEmpty)
        #expect(["macOS", "Linux", "Windows"].contains(osName))

        let configDir = LingXiPlatform.system.defaultConfigurationDirectory
        #expect(!configDir.path.isEmpty)
    }

    @Test func platformSecureRandomGeneration() {
        let bytes1 = LingXiPlatform.secureStorage.generateSecureRandomBytes(count: 32)
        let bytes2 = LingXiPlatform.secureStorage.generateSecureRandomBytes(count: 32)
        #expect(bytes1.count == 32)
        #expect(bytes2.count == 32)
        #expect(bytes1 != bytes2) // 强随机数不应碰撞
    }

    @Test func platformCurrentExecutablePath() {
        let currentExec = LingXiPlatform.process.currentExecutablePath()
        #expect(currentExec != nil)
        if let currentExec {
            #expect(FileManager.default.fileExists(atPath: currentExec.path))
        }
    }

    @Test func executableFinderResolvesCommonTools() {
        #if os(Windows)
        let toolName = "cmd.exe"
        #else
        let toolName = "sh"
        #endif
        let resolved = LingXiPlatform.process.resolveExecutable(named: toolName, customSearchPaths: nil)
        #expect(resolved != nil)
        if let resolved {
            #expect(FileManager.default.isExecutableFile(atPath: resolved))
        }
    }

    @Test func pathUtilitiesTildeExpansion() {
        #if os(Windows)
        let expectedHome = ProcessInfo.processInfo.environment["USERPROFILE"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        #else
        let expectedHome = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        #endif
        let expanded = PathUtilities.expandingTilde(in: "~/test_project")
        let normalizedExpanded = expanded.replacingOccurrences(of: "\\", with: "/")
        let normalizedExpected = expectedHome.replacingOccurrences(of: "\\", with: "/")
        #expect(normalizedExpanded.hasPrefix(normalizedExpected))
        #expect(normalizedExpanded.hasSuffix("test_project"))

        let unchanged = PathUtilities.expandingTilde(in: "/absolute/path")
        #expect(unchanged == "/absolute/path")
    }

    @Test func fallbackTerminalSafety() {
        let fallback = LingXiPlatform.fallbackTerminal
        // 验证纯 ANSI 软渲染方法调用安全无崩溃
        fallback.hideCursor()
        fallback.showCursor()
        fallback.setCursor(column: 1, row: 1)
    }
}
