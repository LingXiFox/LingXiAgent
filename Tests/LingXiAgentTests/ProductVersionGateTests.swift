import Foundation
import Testing
import LingXiCore
import LingXiProtocol
import LingXiTUI

/// 产品版本只有一个来源，其余位置必须引用它，而不是各自抄一份。
///
/// v1.1.0 发布时二进制仍自报 1.0.0，就是因为版本号散落在 CLI、Core、ACP、MCP、
/// UA、Sidecar 与 macOS bundle plist 里，谁都没和 tag 对齐。这里把"对齐"变成判据：
/// 引用点必须引用常量、不许出现硬编码副本、Sidecar 与网站 fallback 必须等于常量，
/// 而且已发布的 tag 不允许领先常量。
@Suite("Product version single source", .serialized)
struct ProductVersionGateTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LingXiAgentTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the CLI, Core and the constant are the same value")
    func consumersShareOneValue() {
        #expect(CLIParser.version == ProductVersion.current)
        #expect(CLIParser.releaseName == ProductVersion.releaseName)
        #expect(CoreHost.coreVersion == ProductVersion.current)
    }

    @Test("short form and UA marker derive from the constant")
    func derivedForms() {
        let components = ProductVersion.current.split(separator: ".")
        #expect(components.count == 3, "产品版本必须是三段 semver，tag 比较依赖这个形状")
        // 期望值从常量推导，不然每次 bump 版本都得来改一次测试。
        let expectedShort = "\(components[0]).\(components[1])"
        #expect(ProductVersion.short == expectedShort)
        #expect(ProductVersion.userAgent == "LingXiAgent/\(expectedShort)")
    }

    @Test("no site restates a version literal that must be referenced")
    func noRestatedLiterals() throws {
        // `LingXiAgent/<digit>` 是产品身份的直译副本，UA 必须由常量拼出来。
        let offenders = try Self.swiftSources(under: "Sources")
            .filter { _, body in body.range(of: #"LingXiAgent/[0-9]"#, options: .regularExpression) != nil }
            .map(\.path)
        #expect(offenders.isEmpty, "硬编码产品版本 UA：\(offenders)")

        // 版本与 releaseName 只允许在 ProductVersion.swift 里出现字面量。
        let cli = try text("Sources/LingXiTUI/CLIParser.swift")
        #expect(!cli.contains("static let version = \""), "CLIParser 不得再自己写版本号")
        let core = try text("Sources/LingXiCore/App/CoreHost.swift")
        #expect(!core.contains("static let coreVersion = \""), "CoreHost 不得再自己写版本号")
    }

    @Test("every declared consumer references the shared constant")
    func consumersReferenceTheConstant() throws {
        let requirements: [(String, String)] = [
            ("Sources/LingXiTUI/CLIParser.swift", "ProductVersion.current"),
            ("Sources/LingXiTUI/CLIParser.swift", "ProductVersion.releaseName"),
            ("Sources/LingXiCore/App/CoreHost.swift", "ProductVersion.current"),
            ("Sources/LingXiProtocol/ACPProtocol.swift", "ProductVersion.current"),
            ("Sources/LingXiProtocol/RuntimeEvents.swift", "ProductVersion.current"),
            ("Sources/LingXiCore/Modules/ACP/LingXiACPServer.swift", "ProductVersion.current"),
            ("Sources/LingXiCore/Modules/Model/OpenAICompatibleProvider.swift", "ProductVersion.userAgent"),
            ("Sources/LingXiCore/Configuration/ClientFingerprint.swift", "ProductVersion.userAgent"),
        ]
        var grouped: [String: [String]] = [:]
        for (file, needle) in requirements { grouped[file, default: []].append(needle) }
        for (file, needles) in grouped {
            let body = try text(file)
            for needle in needles {
                #expect(body.contains(needle), "\(file) 应引用 \(needle)")
            }
        }
    }

    @Test("the browser sidecar carries the same product version")
    func sidecarMatches() throws {
        let json = try text("Sidecars/browser-host/package.json")
        guard let range = json.range(of: "\"version\": \"") else {
            Issue.record("Sidecars/browser-host/package.json 没有 version 字段")
            return
        }
        let rest = json[range.upperBound...]
        let value = String(rest.prefix(while: { $0 != "\"" }))
        #expect(value == ProductVersion.current,
                "browser-host \u{201C}\(value)\u{201D} 与 ProductVersion.current 不一致")
    }

    @Test("the macOS bundle derives its version instead of hardcoding it")
    func bundleScriptDerivesVersion() throws {
        let script = try text("Scripts/bundle-mac-app.sh")
        #expect(script.contains("__PRODUCT_VERSION__"), "Info.plist 应写入占位符再由脚本替换")
        #expect(script.contains("ProductVersion.swift"), "bundle 脚本必须从 ProductVersion 取版本")
        #expect(!script.contains("<key>CFBundleShortVersionString</key>              <string>1"),
                "bundle 脚本里不得再出现写死的产品版本")
    }

    @Test("the website release fallback equals the product version")
    func siteFallbackMatchesProduct() throws {
        let body = try text("Server/agent-site/public/index.html")
        // 首页槽位是静态 fallback + 运行时用 GitHub API 覆盖；fallback 必须等于常量。
        #expect(body.contains(">v\(ProductVersion.current)<"),
                "首页 release fallback 应等于 v\(ProductVersion.current)")
    }

    @Test("a published tag must not outrun the compiled version")
    func tagDoesNotOutrunConstant() throws {
        let output = try Self.git(["describe", "--tags", "--abbrev=0"])
        guard !output.isEmpty else {
            // 没有可达 tag（浅克隆等）——没有可比对的发布事实。
            return
        }
        let tag = output.hasPrefix("v") || output.hasPrefix("V") ? String(output.dropFirst()) : output
        if Self.compare(tag, ProductVersion.current) == .orderedDescending {
            Issue.record("已发布 tag \(tag)，但二进制自报 \(ProductVersion.current)，发版流程要求先同步 ProductVersion.current")
        }
    }

    // MARK: - helpers

    private static func swiftSources(under directory: String) throws -> [(path: String, text: String)] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), body))
        }
        return found
    }

    private static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只比较数字段，语义与 ProductVersion 的三段 semver 约定一致。
    private static func compare(_ left: String, _ right: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(left), b = parts(right)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
