import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct CodebaseGraphTests {

    @Test func testGraphExtractionAndCallTopology() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GraphTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. 创建模拟服务文件 Service.swift
        let serviceFile = tempDir.appendingPathComponent("Service.swift")
        let serviceCode = """
        import Foundation

        public class OrderService: BaseService {
            public func createOrder() {
                validateOrder()
            }

            private func validateOrder() {
                print("validating")
            }
        }
        """
        try serviceCode.write(to: serviceFile, atomically: true, encoding: .utf8)

        // 2. 创建模拟控制器文件 Controller.swift
        let controllerFile = tempDir.appendingPathComponent("Controller.swift")
        let controllerCode = """
        import Foundation

        public class OrderController {
            public func handleRequest() {
                let service = OrderService()
                service.createOrder()
            }
        }
        """
        try controllerCode.write(to: controllerFile, atomically: true, encoding: .utf8)

        // 3. 执行图谱索引
        let engine = CodebaseGraphEngine()
        let overview = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        #expect(overview.totalFiles == 2)
        #expect(overview.totalNodes >= 4) // 2 files + OrderService + OrderController + methods
        #expect(overview.totalEdges >= 3) // defines, imports, calls

        // 4. 测试搜索
        let searchResults = await engine.search(query: "OrderService")
        #expect(!searchResults.isEmpty)
        #expect(searchResults.first?.name == "OrderService")

        // 5. 测试拓扑追踪 (Trace)
        // 追查谁调用了 createOrder (inbound)
        if let traceReport = await engine.traceCallPath(symbolNameOrId: "createOrder", direction: .inbound, maxDepth: 3) {
            #expect(traceReport.root.name == "createOrder")
            #expect(!traceReport.steps.isEmpty)
            let callerNames = traceReport.steps.map(\.from.name)
            #expect(callerNames.contains("handleRequest"))
        } else {
            Issue.record("Expected traceReport for createOrder not to be nil")
        }

        // 6. 测试架构热点 (Hotspots)
        let arch = await engine.getArchitecture()
        #expect(!arch.layers.isEmpty)
    }

    @Test func testGraphSearchWithKindFilter() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSearchTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codeFile = tempDir.appendingPathComponent("Types.swift")
        let code = """
        public struct UserConfig {
            public let id: String
        }
        public func parseConfig() {}
        """
        try code.write(to: codeFile, atomically: true, encoding: .utf8)

        let engine = CodebaseGraphEngine()
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        // 仅搜索 struct
        let structs = await engine.search(query: "Config", kind: .struct)
        #expect(structs.count == 1)
        #expect(structs.first?.name == "UserConfig")

        // 仅搜索 function
        let funcs = await engine.search(query: "Config", kind: .function)
        #expect(funcs.count == 1)
        #expect(funcs.first?.name == "parseConfig")
    }

    @Test func testEngineIndexingStatusAndMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GraphStatusTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("Sample.swift")
        try "public func helloWorld() {}".write(to: sampleFile, atomically: true, encoding: .utf8)

        let engine = CodebaseGraphEngine()
        #expect(await engine.isIndexed == false)
        #expect(await engine.isIndexingInProgress == false)
        #expect(await engine.nodeCount == 0)

        _ = await engine.indexWorkspace(workspaceURL: tempDir)
        #expect(await engine.isIndexed == true)
        #expect(await engine.nodeCount >= 2) // file + function
        #expect(await engine.isIndexingInProgress == false)
    }
}
