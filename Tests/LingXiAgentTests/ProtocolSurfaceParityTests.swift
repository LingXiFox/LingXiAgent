import Foundation
import Testing
import LingXiProtocol

/// §11 + §13 of the GUI↔Core closure contract, enforced in one place.
///
/// The contract's complaint was not that any single RPC was wrong; it was that four things
/// (declared, dispatched, forwarded, implemented) were kept in agreement by hand, so any one of
/// them could drift and the build would still pass. A protocol default made that silent: an
/// unforwarded requirement resolved to the extension, which answered `applied: true` for work
/// nobody had done.
///
/// So this test reads the four sources and requires them to agree on the *same* set of names.
/// It is deliberately textual rather than reflective — Swift has no runtime listing of protocol
/// requirements, and a text scan fails with a message a person can act on.
@Suite("Protocol surface parity", .serialized)
struct ProtocolSurfaceParityTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LingXiAgentTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every `func name(envelope:)` requirement of `LingXiProtocolService`.
    private func requirements() throws -> [String] {
        let text = try source("Sources/LingXiProtocol/ProtocolService.swift")
        let body = text[...text.range(of: "public extension LingXiProtocolService")!.lowerBound]
        let found: [String] = body.components(separatedBy: "\n").compactMap { line in
            guard let open = line.range(of: "func "), line.contains("(envelope:") else { return nil }
            let tail = line[open.upperBound...]
            return String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        }
        return Set(found).sorted()
    }

    /// Names whose implementation throws `unsupportedCommand` on purpose. Optional features are
    /// allowed to be absent; they are not allowed to be absent *and* return something.
    ///
    /// Adding to this list is the review point: each entry must have a reason in the doc comment.
    private static let declaredUnsupported: Set<String> = [
        "listAgentPresets",  // no preset store behind it; the old default invented three presets
        "listAgentRuns",     // an empty list would read as "no runs", not as "unsupported"
        "compareMultiRuns",  // no comparison engine; it used to answer applied=true with {}
    ]

    // MARK: - §11.1 — no default may shadow a requirement

    @Test("no LingXiProtocolService requirement has a default implementation")
    func requirementsAreNotDefaultImplemented() throws {
        let names: [String] = defaultExtensionBody().components(separatedBy: "\n").compactMap { line in
            guard let open = line.range(of: "    func ") else { return nil }
            let tail = line[open.upperBound...]
            return String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        }
        let defaulted = Set(names)
        // The convenience overloads below are not defaults for a requirement — they are
        // one-argument forms of an authorised method, and each forwards to the real one.
        let permitted: Set<String> = ["getContentMetadata", "getContent", "getContentRange"]
        let violations = defaulted.subtracting(permitted).subtracting(Self.declaredUnsupported)
        #expect(violations.isEmpty,
                "这些 RPC 有协议默认实现，忘记实现也能编译通过：\(violations.sorted())")
    }

    // MARK: - §13 — declared ⇔ dispatched ⇔ forwarded ⇔ implemented

    @Test("every requirement is dispatched by the stdio server")
    func everyRequirementIsDispatched() throws {
        let server = try source("Sources/LingXiCore/App/VNextStdioCoreServer.swift")
        let missing = try requirements().filter { !server.contains("service.\($0)(envelope:") }
        #expect(missing.isEmpty, "VNext 服务器没有分派这些 RPC：\(missing)")
    }

    @Test("both transports forward every requirement")
    func bothTransportsForwardEverything() throws {
        let inProcess = try source("Sources/LingXiClient/VNext/Transport/InProcessTransport.swift")
        let stdio = try source("Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift")
        let missingInProcess = try requirements().filter { !inProcess.contains("service.\($0)(envelope:") }
        // The stdio transport declares `func name(envelope: …)` and emits a wire name from it;
        // matching the declaration is what proves the client side of the hop exists.
        let missingStdio = try requirements().filter { !stdio.contains("func \($0)(envelope:") }
        // An unforwarded method used to fall through to the protocol default and answer with a
        // fabricated success. There is no default left to fall through to, so this list failing
        // would also be a compile error — kept as a test because it names the methods.
        #expect(missingInProcess.isEmpty, "InProcessTransport 未转发：\(missingInProcess)")
        #expect(missingStdio.isEmpty, "VNextStdioTransport 未转发：\(missingStdio)")
    }

    @Test("every requirement is either implemented by Core or declares itself unsupported")
    func nothingIsSilentlyAbsent() throws {
        let core = try coreSource()
        var unbacked: [String] = []
        for name in try requirements() where !core.contains("func \(name)(envelope:") {
            if Self.declaredUnsupported.contains(name) { continue }
            unbacked.append(name)
        }
        #expect(unbacked.isEmpty,
                "CoreHost 既没实现也没声明 unsupported：\(unbacked)")
    }

    @Test("an unsupported RPC throws instead of returning a value")
    func unsupportedMeansThrows() throws {
        let body = defaultExtensionBody()
        for name in Self.declaredUnsupported {
            guard let at = body.range(of: "func \(name)(") else {
                Issue.record("\(name) 不在协议扩展里"); continue
            }
            // The body is the three lines between this brace and the one that closes it.
            let head = body[at.lowerBound...].prefix(while: { $0 != "}" })
            #expect(head.contains("throw CoreError"), "\(name) 声称可选但未以 throw 表达不支持")
            #expect(!head.contains("applied: true") && !head.contains("payload: []"),
                    "\(name) 仍在伪造成功返回")
        }
    }

    /// §11.2's forbidden shapes, searched for rather than trusted to be absent.
    @Test("no fabricated success remains anywhere in the protocol surface")
    func noFabricatedSuccess() throws {
        // Code only: the point of this extension is that these shapes are gone, and the comment
        // explaining that has to be allowed to name them.
        let code = defaultExtensionBody().components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for shape in ["applied: true", "payload: []", "payload: nil"] {
            #expect(!code.contains(shape), "协议默认实现里仍存在伪造成功形状：\(shape)")
        }
    }

    /// §12's other half: a broadcast feature is a promise about RPCs, so every method it names
    /// must exist at all four hops. Adding a `ProtocolFeature` case without wiring is the mistake
    /// this catches; the list CoreHost broadcasts is stated, never defaulted.
    @Test("every advertised feature has its methods wired end to end")
    func advertisedFeaturesAreWired() throws {
        let server = try source("Sources/LingXiCore/App/VNextStdioCoreServer.swift")
        let stdio = try source("Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift")
        let advertised = try advertisedFeatures()
        #expect(!advertised.isEmpty, "CoreHost 没有写出任何广播特性，客户端只能按无特性降级")
        for feature in advertised {
            #expect(!feature.requiredMethods.isEmpty, "\(feature) 被广播却没有方法清单")
            for method in feature.requiredMethods {
                #expect(server.contains("case \"" + method + "\""),
                        "\(feature) 被广播，但 VNext 服务器不分派 \(method)")
                #expect(stdio.contains("\"" + method + "\""),
                        "\(feature) 被广播，但客户端侧没有 \(method) 的 wire 名")
            }
        }
        // The converse: a fully wired feature that nobody broadcasts leaves the client guessing.
        for feature in ProtocolFeature.knownFeatures where !advertised.contains(feature) {
            let dispatched = feature.requiredMethods.filter { server.contains("case \"" + $0 + "\"") }
            #expect(dispatched.isEmpty,
                    "\(feature) 的 \(dispatched) 已接线却没被广播，客户端会以为不可用")
        }
    }

    /// The `supportedFeatures: [ … ]` literal CoreHost passes to `RuntimeCapabilities`, resolved
    /// back to cases. Interpolating a `String`-backed enum case yields its case name, which is
    /// exactly what the literal is written as.
    private func advertisedFeatures() throws -> [ProtocolFeature] {
        let text = try source("Sources/LingXiCore/App/CoreHost.swift")
        guard let start = text.range(of: "supportedFeatures:"),
              let open = text[start.lowerBound...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") else {
            Issue.record("CoreHost 未显式写出 supportedFeatures: [...]，广播不允许来自默认值")
            return []
        }
        let literal = String(text[open...close])
        let unknown = Set(literal.components(separatedBy: CharacterSet(charactersIn: "., \n[]"))
            .filter { $0.first?.isLetter == true })
            .subtracting(Set(ProtocolFeature.allCases.map { String(describing: $0) }))
        #expect(unknown.isEmpty, "广播里出现了不是 ProtocolFeature 的符号：\(unknown.sorted())")
        return ProtocolFeature.allCases.filter { literal.contains("." + String(describing: $0)) }
    }

    // MARK: - helpers

    /// All LingXiCore Swift sources concatenated, for "does Core implement this?" questions.
    private func coreSource() throws -> String {
        var text = ""
        for file in try swiftFiles(under: "Sources/LingXiCore") { text += try source(file) }
        return text
    }

    /// The text of `public extension LingXiProtocolService { … }`, up to its own closing brace.
    private func defaultExtensionBody() -> String {
        let text = (try? source("Sources/LingXiProtocol/ProtocolService.swift")) ?? ""
        guard let start = text.range(of: "public extension LingXiProtocolService") else { return "" }
        var depth = 0
        var sawOpen = false
        var index = start.lowerBound
        for character in text[start.lowerBound...] {
            defer { index = text.index(after: index) }
            if character == "{" { depth += 1; sawOpen = true }
            if character == "}" { depth -= 1 }
            if sawOpen && depth == 0 { return String(text[start.lowerBound..<index]) }
        }
        return String(text[start.lowerBound...])
    }

    private func swiftFiles(under directory: String) throws -> [String] {
        let base = Self.root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { $0.path.replacingOccurrences(of: Self.root.path + "/", with: "") }
            .sorted()
    }
}
