import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct FormatCoordinatorTests {

    @Test func testMatchingConfigurationForVariousLanguages() async {
        let coordinator = FormatCoordinator.shared

        // Swift
        let swiftURL = URL(fileURLWithPath: "/workspace/App.swift")
        let swiftConfig = await coordinator.matchingConfig(for: swiftURL)
        #expect(swiftConfig?.name == "swift-format")

        // Python
        let pyURL = URL(fileURLWithPath: "/workspace/script.py")
        let pyConfig = await coordinator.matchingConfig(for: pyURL)
        #expect(pyConfig?.name == "ruff")
        #expect(pyConfig?.fallbackCommand?.first == "black")

        // TypeScript / JavaScript / JSON
        let tsURL = URL(fileURLWithPath: "/workspace/index.tsx")
        let tsConfig = await coordinator.matchingConfig(for: tsURL)
        #expect(tsConfig?.name == "prettier")

        let jsonURL = URL(fileURLWithPath: "/workspace/data.json")
        let jsonConfig = await coordinator.matchingConfig(for: jsonURL)
        #expect(jsonConfig?.name == "prettier")

        // Rust
        let rsURL = URL(fileURLWithPath: "/workspace/main.rs")
        let rsConfig = await coordinator.matchingConfig(for: rsURL)
        #expect(rsConfig?.name == "rustfmt")

        // Go
        let goURL = URL(fileURLWithPath: "/workspace/server.go")
        let goConfig = await coordinator.matchingConfig(for: goURL)
        #expect(goConfig?.name == "gofmt")

        // C / C++
        let cppURL = URL(fileURLWithPath: "/workspace/native.cpp")
        let cppConfig = await coordinator.matchingConfig(for: cppURL)
        #expect(cppConfig?.name == "clang-format")

        // Unknown
        let txtURL = URL(fileURLWithPath: "/workspace/readme.txt")
        let txtConfig = await coordinator.matchingConfig(for: txtURL)
        #expect(txtConfig == nil)
    }

    @Test func testFormatFileGracefullyHandlesUnknownExtension() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("notes.unknownext")
        try? "hello world".write(to: testFile, atomically: false, encoding: .utf8)

        let coordinator = FormatCoordinator()
        let result = await coordinator.format(fileURL: testFile, workspaceRoot: tempDir)

        #expect(result.success == true)
        #expect(result.changed == false)
        #expect(result.formatterName == "none")
    }

    @Test func testFormatFileGracefullyHandlesMissingExecutable() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("main.swift")
        try? "let x=1\n".write(to: testFile, atomically: false, encoding: .utf8)

        // 配置一个不存在的格式化器
        let customConfig = FormatterConfig(
            name: "non-existent-formatter",
            command: ["non-existent-formatter-xyz", "$FILE"],
            extensions: ["swift"]
        )
        let coordinator = FormatCoordinator(configurations: [customConfig])
        let result = await coordinator.format(fileURL: testFile, workspaceRoot: tempDir)

        #expect(result.success == false)
        #expect(result.changed == false)
        #expect(result.message?.contains("not found") == true)
    }

    @Test func testAutoFormatToggle() async {
        let coordinator = FormatCoordinator()
        #expect(await coordinator.autoFormatEnabled() == true)

        await coordinator.setAutoFormatEnabled(false)
        #expect(await coordinator.autoFormatEnabled() == false)

        await coordinator.setAutoFormatEnabled(true)
        #expect(await coordinator.autoFormatEnabled() == true)
    }
}
