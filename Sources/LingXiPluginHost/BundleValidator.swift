import Foundation
import LingXiPluginABI

struct BundleManifest {
    let bundleID: String
    let version: String
    let abiMajor: UInt32
    let entryPoint: String
    let executableURL: URL
    let teamID: String?
    let signature: SignatureState
    let capabilities: [String]
    let permissions: [String]
}

enum SignatureState: String {
    case developerID
    case adHoc
    case teamMatched
    case unverified
}

enum BundleRejection: Error, CustomStringConvertible {
    case missingPath(String)
    case unparsableManifest(String)
    case missingField(String)
    case wrongArchitecture(String)
    case signatureFailed(String)
    case policyRefused(String)

    var description: String {
        switch self {
        case .missingPath(let p): "bundle is missing \(p)"
        case .unparsableManifest(let p): "Info.plist at \(p) is not a property list"
        case .missingField(let f): "manifest has no \(f); capability and permission declarations carry no defaults"
        case .wrongArchitecture(let why): "architecture check failed: \(why)"
        case .signatureFailed(let why): "codesign --verify --strict failed: \(why)"
        case .policyRefused(let why): "signature policy refused the bundle: \(why)"
        }
    }
}

/// The validation order the design fixes: bundle shape, then signature and team policy, then the
/// manifest with no defaulting. Nothing is `dlopen`ed before all three pass
/// (Plugin-System-Design.md §十, PLG-017).
enum BundleValidator {
    static func validate(bundleURL: URL, policy: SignaturePolicy, hostTeamID: String?) throws -> BundleManifest {
        let contents = bundleURL.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw BundleRejection.missingPath("Contents/Info.plist")
        }

        let data = try Data(contentsOf: plistURL)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BundleRejection.unparsableManifest(plistURL.path)
        }
        guard let bundleID = root["CFBundleIdentifier"] as? String,
              let version = root["CFBundleShortVersionString"] as? String,
              let executable = root["CFBundleExecutable"] as? String else {
            throw BundleRejection.missingField("CFBundleIdentifier / CFBundleShortVersionString / CFBundleExecutable")
        }

        guard let plugin = root["LingXiPlugin"] as? [String: Any] else {
            throw BundleRejection.missingField("LingXiPlugin dictionary")
        }
        // No defaults anywhere below: a missing key fails the load.
        guard let abiMajor = plugin["ABIMajor"] as? Int else {
            throw BundleRejection.missingField("LingXiPlugin.ABIMajor")
        }
        guard let entryPoint = plugin["EntryPoint"] as? String else {
            throw BundleRejection.missingField("LingXiPlugin.EntryPoint")
        }
        guard let capabilities = plugin["Capabilities"] as? [String] else {
            throw BundleRejection.missingField("LingXiPlugin.Capabilities")
        }
        guard plugin["Permissions"] != nil, let permissions = plugin["Permissions"] as? [String] else {
            throw BundleRejection.missingField("LingXiPlugin.Permissions")
        }
        guard !capabilities.isEmpty else {
            throw BundleRejection.missingField("at least one declared capability")
        }

        let executableURL = contents.appendingPathComponent("MacOS").appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw BundleRejection.missingPath("Contents/MacOS/\(executable)")
        }
        try requireSingleArm64Slice(at: executableURL)

        var teamID: String?
        let signature = try verifySignature(at: bundleURL, teamID: &teamID)
        try enforce(policy: policy, signature: signature, teamID: teamID, hostTeamID: hostTeamID)

        return BundleManifest(
            bundleID: bundleID, version: version, abiMajor: UInt32(abiMajor), entryPoint: entryPoint,
            executableURL: executableURL, teamID: teamID, signature: signature,
            capabilities: capabilities, permissions: permissions
        )
    }

    /// Two tiers and no third escape hatch: `restricted` requires the same Team ID as the host,
    /// `permissive` admits third-party signatures, and `development` admits an ad-hoc signature but
    /// labels it untrusted. `codesign --verify --strict` passing is *not* Developer ID or
    /// notarisation, and nothing here claims a sandbox (PLG-017).
    private static func enforce(
        policy: SignaturePolicy, signature: SignatureState, teamID: String?, hostTeamID: String?
    ) throws {
        switch policy {
        case .restricted:
            guard signature != .adHoc else {
                throw BundleRejection.policyRefused("ad-hoc signatures are not admitted in restricted mode")
            }
            guard let teamID, teamID == hostTeamID else {
                throw BundleRejection.policyRefused("team \(teamID ?? "none") is not the host team \(hostTeamID ?? "none")")
            }
        case .permissive:
            guard signature != .adHoc else {
                throw BundleRejection.policyRefused("ad-hoc signatures never enter a release channel")
            }
        case .development:
            break
        }
    }

    private static func requireSingleArm64Slice(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            throw BundleRejection.wrongArchitecture("could not read the Mach-O header")
        }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // 0xFEEDFACF is a thin 64-bit Mach-O; a fat header means more than one slice, which the
        // first release declares a packaging error rather than something to choose between.
        guard magic == 0xFEEDFACF else {
            throw BundleRejection.wrongArchitecture(
                magic == 0xCAFEBABE || magic == 0x0B1BA57E
                    ? "the bundle carries more than one architecture slice"
                    : "not a 64-bit Mach-O image (magic 0x\(String(magic, radix: 16)))"
            )
        }
    }

    private static func verifySignature(at url: URL, teamID: inout String?) throws -> SignatureState {
        let result = try runCodesign(["--verify", "--strict", url.path])
        guard result.status == 0 else {
            throw BundleRejection.signatureFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let details = try runCodesign(["-dvvv", url.path])
        let text = details.output
        let extracted = value("TeamIdentifier", in: text) ?? value("TeamID", in: text)
        teamID = extracted == "empty" || extracted == "adhoc" ? "adhoc" : extracted
        if text.contains("Signature=adhoc") || teamID == "adhoc" { return .adHoc }
        if text.contains("Authority=Developer ID") { return .developerID }
        return .unverified
    }

    private static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let equal = line.firstIndex(of: "=") else { continue }
            if line[..<equal].trimmingCharacters(in: .whitespaces) == key {
                return String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    struct RunResult { let status: Int32; let output: String }

    private static func runCodesign(_ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
