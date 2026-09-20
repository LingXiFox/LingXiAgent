import Foundation
import Testing
@testable import LingXiPlatform

@Suite("Platform Boundary Architecture Guard Tests (Phase 9)")
struct PlatformBoundaryArchitectureTests {

    @Test("OS-specific imports stay strictly inside Platform layer")
    func testOsSpecificImportsStayInsidePlatformLayer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Repo Root

        let sourcesDir = repoRoot.appendingPathComponent("Sources")

        let forbiddenImportPatterns = [
            "import AppKit",
            "import Cocoa",
            "import CoreGraphics",
            "import CoreFoundation",
            "import Security",
            "import Darwin",
            "import Glibc",
            "import WinSDK"
        ]

        let scannedModules = [
            "LingXiCore",
            "LingXiApplication",
            "LingXiClient",
            "LingXiTUI",
            "LingXiTUIComponents",
            "LingXiTUIApp",
            "LingXiPluginSDK",
            "LingXiProtocol",
            "LingXiCoreHost",
            "lingxiagent"
        ]

        var violations: [String] = []

        for module in scannedModules {
            let moduleDir = sourcesDir.appendingPathComponent(module)
            guard FileManager.default.fileExists(atPath: moduleDir.path) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: moduleDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                let lines = content.components(separatedBy: "\n")
                for (lineNum, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    for pattern in forbiddenImportPatterns {
                        if trimmed == pattern || trimmed.hasPrefix(pattern + ";") {
                            violations.append("\(fileURL.lastPathComponent):\(lineNum + 1): '\(trimmed)' in \(module)")
                        }
                    }
                }
            }
        }

        #expect(violations.isEmpty, "OS-specific framework imports leaked outside Platform layer:\n\(violations.joined(separator: "\n"))")
    }

    @Test("Non-portable POSIX system calls (setenv, usleep) are forbidden outside Platform layer")
    func testNonPortableApiCallsStayInsidePlatformLayer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sourcesDir = repoRoot.appendingPathComponent("Sources")

        let forbiddenCallPatterns = [
            "setenv(",
            "unsetenv(",
            "usleep("
        ]

        let scannedModules = [
            "LingXiCore",
            "LingXiApplication",
            "LingXiClient",
            "LingXiTUI",
            "LingXiTUIComponents",
            "LingXiTUIApp",
            "LingXiPluginSDK",
            "LingXiProtocol",
            "LingXiCoreHost",
            "lingxiagent"
        ]

        var violations: [String] = []

        for module in scannedModules {
            let moduleDir = sourcesDir.appendingPathComponent(module)
            guard FileManager.default.fileExists(atPath: moduleDir.path) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: moduleDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                let lines = content.components(separatedBy: "\n")
                for (lineNum, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Skip comment lines
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                        continue
                    }
                    for pattern in forbiddenCallPatterns {
                        if trimmed.contains(pattern) {
                            violations.append("\(fileURL.lastPathComponent):\(lineNum + 1): call to '\(pattern)' in \(module)")
                        }
                    }
                }
            }
        }

        #expect(violations.isEmpty, "Non-portable system calls leaked outside Platform layer (use LingXiPlatform abstractions instead):\n\(violations.joined(separator: "\n"))")
    }

    @Test("Cross-platform path absolute check works on POSIX and Windows styles")
    func testCrossPlatformPathIsAbsolute() {
        // POSIX paths
        #expect(PathUtilities.isAbsolute("/Users/test"))
        #expect(PathUtilities.isAbsolute("/etc/hosts"))
        #expect(!PathUtilities.isAbsolute("relative/path.swift"))
        #expect(!PathUtilities.isAbsolute("./local.txt"))
        #expect(!PathUtilities.isAbsolute("../parent"))

        // Windows drive and UNC paths
        #expect(PathUtilities.isAbsolute("C:\\Windows\\System32"))
        #expect(PathUtilities.isAbsolute("d:/projects/app"))
        #expect(PathUtilities.isAbsolute("\\\\server\\share\\file.txt"))
    }

    @Test("Terminal interactive query fallback defaults safely")
    func testTerminalInteractiveAbstraction() {
        let isInteractive = LingXiPlatform.terminal.isInteractive()
        // In headless CI/test execution, isInteractive should safely return false or true without crashing
        _ = isInteractive
        let sep = LingXiPlatform.path.pathListSeparator
        #expect(sep == ":" || sep == ";")
    }
}
