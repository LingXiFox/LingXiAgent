import Darwin
import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let probeID = "site.lingxi.plugin.contextprobe"

/// Minimal Mach-O reader: what a plugin actually links says whether it carries its own Swift runtime.
func linkedDylibs(at url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    func word(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
    guard data.count > 32, word(0) == 0xFEEDFACF else { return [] }
    let commandCount = Int(word(16))
    var offset = 32
    var names: [String] = []
    for _ in 0..<commandCount {
        let command = word(offset)
        let size = Int(word(offset + 4))
        guard size >= 8, offset + size <= data.count else { break }
        // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB
        if command == 0xC || command == 0x80000018 || command == 0x8000001F {
            let nameOffset = Int(word(offset + 8))
            var cursor = offset + nameOffset
            let end = offset + size
            while cursor < end, data[cursor] != 0 { cursor += 1 }
            names.append(String(decoding: data[(offset + nameOffset)..<cursor], as: UTF8.self))
        }
        offset += size
    }
    return names
}

private func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func writeRegistry(dataDirectory: URL, bundlePath: String) async throws {
    let registry = try PluginRegistry(configURL: dataDirectory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(bundleID: probeID, version: "1.0.0", bundlePath: bundlePath, enabled: true))
}

private struct HostRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runCoreHost(dataDirectory: URL, policy: String?) throws -> HostRun {
    let process = Process()
    process.executableURL = builtProduct("LingXiCoreHost")
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = dataDirectory.path
    environment.removeValue(forKey: "LINGXI_PLUGIN_POLICY")
    if let policy { environment["LINGXI_PLUGIN_POLICY"] = policy }
    process.environment = environment
    let out = Pipe(); let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HostRun(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

private func pidLine(_ stdout: String) -> Int32? {
    for line in stdout.split(separator: "\n") where line.contains("plugin host pid:") {
        guard let value = line.split(separator: "=").last.map(String.init) else { continue }
        return Int32(value.trimmingCharacters(in: .whitespaces))
    }
    return nil
}

@Test("PLG-001 the real CoreHost restores an enabled plugin and cleans up on exit, twice")
func PLG_001_coreHostRestoresPluginAcrossRestart() async throws {
    let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("corehost-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDirectory) }

    let bundle = try makeBundle(
        bundleID: probeID, executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"), capabilities: ["hook.contextProbe"]
    )
    try await writeRegistry(dataDirectory: dataDirectory, bundlePath: bundle.url.path)

    for attempt in 1...2 {
        let run = try runCoreHost(dataDirectory: dataDirectory, policy: "development")
        #expect(run.status == 0, "attempt \(attempt) stderr: \(run.stderr)")
        #expect(run.stdout.contains("plugin policy:  development"))
        #expect(run.stdout.contains("plugin handlers: \(probeID).contextProbe"))
        #expect(run.stdout.contains("1 running"))
        let pid = try #require(pidLine(run.stdout), "attempt \(attempt): no pid line")
        // The process was alive when the status was printed and is gone after the Core returns.
        #expect(await waitUntil { processExists(pid) == false })
    }

    // With no explicit opt-in the Core must fall back to the strict tier, refuse the ad-hoc bundle,
    // and still boot. A silent downgrade to development would show up as a running plugin here.
    let strict = try runCoreHost(dataDirectory: dataDirectory, policy: nil)
    #expect(strict.status == 0)
    #expect(strict.stdout.contains("plugin policy:  restricted"))
    #expect(strict.stdout.contains("0 running"))
    #expect(strict.stdout.contains("plugin error:"))
    #expect(!strict.stdout.contains("plugin handlers: \(probeID)"))
}

@Test("PLG-017 the coordinator default is restricted, so an ad-hoc plugin is refused")
func PLG_017_defaultPolicyIsRestricted() async throws {
    let registry = try PluginRegistry(configURL: nil)
    let pipeline = HookPipeline()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"), registry: registry, pipeline: pipeline
    )
    let bundle = try makeBundle(
        bundleID: probeID, executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"), capabilities: ["hook.contextProbe"]
    )
    try await coordinator.install(bundleID: probeID, version: "1.0.0", bundlePath: bundle.url.path)

    var refusal = ""
    do {
        // No policy argument: the default must be the strict tier, never development.
        _ = try await coordinator.enable(bundleID: probeID)
    } catch {
        refusal = "\(error)"
    }
    #expect(refusal.contains("ad-hoc"))
    #expect(await pipeline.mountedHandlerIDs.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("PLG-008 a sentinel credential in the Core environment never reaches the host")
func PLG_008_environmentSentinelDoesNotLeak() async throws {
    setenv("LINGXI_TEST_API_KEY", "sentinel-must-not-cross", 1)
    defer { unsetenv("LINGXI_TEST_API_KEY") }

    let process = PluginProcess(executableURL: builtProduct("LingXiPluginHost"))
    try process.start()
    defer { process.terminate() }
    struct Diagnostics: Decodable { let environment: [String] }
    let reply = try await process.send(HostRequest(id: nil, method: .diagnostics), timeout: .seconds(3))
    let keys = try #require(reply.payload).decode(Diagnostics.self).environment

    #expect(!keys.contains("LINGXI_TEST_API_KEY"))
    #expect(!keys.contains { $0.hasSuffix("_API_KEY") })
    // The allow-list keeps what a host needs to run at all.
    #expect(keys.contains("PATH"))
    #expect(keys.contains("HOME"))
}

@Test("PLG-019 the Swift plugin links the OS Swift runtime dynamically and embeds no copy")
func PLG_019_swiftRuntimeIsNotEmbedded() throws {
    let swiftDeps = try linkedDylibs(at: builtProduct("libLingXiContextProbe.dylib"))
    #expect(swiftDeps.contains { $0.contains("libswiftCore.dylib") })
    // No copy inside the plugin or the bundle: everything comes from the OS install.
    #expect(!swiftDeps.contains { $0.contains(".lxap") || $0.contains("LingXiContextProbe.dylib") })

    // A C plugin must not pull the Swift runtime in at all.
    let cDeps = try linkedDylibs(at: builtProduct("libLingXiCProbe.dylib"))
    #expect(!cDeps.contains { $0.contains("libswift") })
}

@Test("LOOP-023 an in-flight plugin call can be cancelled while the host stays responsive")
func LOOP_023_inFlightCancellation() async throws {
    let bundle = try makeBundle(
        bundleID: probeID, executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"), capabilities: ["hook.contextProbe"]
    )
    let session = PluginSession(bundlePath: bundle.url.path, hostExecutableURL: builtProduct("LingXiPluginHost"))
    try await session.enable(policy: .development, grantedPermissions: ["fault.slow"])
    defer { Task { await session.disable() } }

    let requestID = UUID().uuidString
    let started = Date()
    let call = Task {
        try await session.invoke(
            capability: "hook.contextProbe", payload: .object([:]), requestID: requestID
        )
    }

    // Give the call time to enter the plugin's slow path, then prove the host still answers.
    usleep(100_000)
    #expect(await session.ping(timeout: .seconds(1)))
    #expect(started.timeIntervalSinceNow > -2.0)

    await session.cancel(requestID: requestID)
    var failed = false
    do {
        _ = try await call.value
    } catch {
        failed = true
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(failed)
    // The plugin sleeps for 2s; a prompt cancel must land far earlier.
    #expect(elapsed < 1.2, "cancel took \(elapsed)s")

    let pid = try #require(await session.processIdentifier)
    await session.disable()
    #expect(await session.isRunning == false)
    #expect(await waitUntil { processExists(pid) == false })
}

@Test("LOOP-023 a timed-out call is cancelled in the host and leaves no process behind")
func LOOP_023_timeoutCancelsInHost() async throws {
    let bundle = try makeBundle(
        bundleID: probeID, executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"), capabilities: ["hook.contextProbe"]
    )
    let session = PluginSession(
        bundlePath: bundle.url.path, hostExecutableURL: builtProduct("LingXiPluginHost"),
        timeout: .milliseconds(200)
    )
    try await session.enable(policy: .development, grantedPermissions: ["fault.slow"])
    let pid = try #require(await session.processIdentifier)

    let started = Date()
    var failed = false
    do {
        _ = try await session.invoke(
            capability: "hook.contextProbe", payload: .object([:]), requestID: UUID().uuidString
        )
    } catch {
        failed = true
    }
    let elapsed = Date().timeIntervalSince(started)
    #expect(failed)
    #expect(elapsed < 1.0)

    // The host did not die from the timeout and still answers.
    #expect(await session.ping(timeout: .seconds(1)))
    await session.disable()
    #expect(await waitUntil { processExists(pid) == false })
}
