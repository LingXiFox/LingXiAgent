import Foundation
import Testing

struct ArchitectureBoundaryTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func domainModulesDoNotReadProcessEnvironment() throws {
        let modules = ["Agent", "Session", "Model", "Context", "Tool", "MCP", "Permission"]
        for module in modules {
            let directory = root.appendingPathComponent("Sources/LingXiCore/Modules/\(module)")
            for file in try swiftFiles(in: directory) {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("ProcessInfo.processInfo.environment"), "\(file.path) must receive typed configuration from App/Infrastructure")
                #expect(!source.contains("getenv("), "\(file.path) must receive typed configuration from App/Infrastructure")
            }
        }
    }

    @Test func packageAndImportsPreserveClientBoundary() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains(#".target(name: "LingXiClient", dependencies: ["LingXiProtocol"])"#))
        #expect(package.contains(#"dependencies: ["LingXiClient", "LingXiProtocol"]"#))
        for directory in ["Sources/LingXiClient", "Sources/LingXiTUI"] {
            for file in try swiftFiles(in: root.appendingPathComponent(directory)) {
                let imports = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("import ") }
                #expect(!imports.contains("import LingXiCore"), "\(file.path) must not depend on LingXiCore")
            }
        }
    }

    @Test func providerAdaptersContainNoAgentStrategy() throws {
        for name in ["OpenAICompatibleProvider.swift", "OpenAIResponsesProvider.swift", "AnthropicMessagesProvider.swift"] {
            let file = root.appendingPathComponent("Sources/LingXiCore/Modules/Model/\(name)")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["SessionRuntime", "ContextPager", "ContextCompactor", "PermissionEngine", "SubagentToolService", "AgentRuntime"] {
                #expect(!source.contains(forbidden), "\(name) must only translate domain and wire data")
            }
        }
    }

    @Test func providerProvenanceDoesNotEnterProtocol() throws {
        for file in try swiftFiles(in: root.appendingPathComponent("Sources/LingXiProtocol")) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["previousResponseID", "responseID", "itemID", "item_id", "anthropicToolUseID"] {
                #expect(!source.contains(forbidden), "\(file.path) contains provider-specific identity \(forbidden)")
            }
        }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
