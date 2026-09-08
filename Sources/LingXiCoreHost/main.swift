import Foundation
import LingXiCore
import LingXiProtocol

if let idx = CommandLine.arguments.firstIndex(of: "--crash-test"), CommandLine.arguments.count > idx + 3 {
    let stage = CommandLine.arguments[idx + 1]
    let path = CommandLine.arguments[idx + 2]
    let commandID = CommandID(CommandLine.arguments[idx + 3])
    let testDataRoot = URL(fileURLWithPath: path)
    setenv("LINGXI_CRASH_TEST_STAGE", stage, 1)
    let testHost = try CoreHost(dataRoot: testDataRoot)
    await testHost.start()
    let envelope = CommandEnvelope(
        commandID: commandID,
        payload: CreateSessionRequest(workspace: path)
    )
    _ = try await testHost.createSession(envelope: envelope)
    exit(0)
}

AuthCLI.installSignalHandlers()

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "auth" {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        let output = try await AuthCLI.run(arguments: args)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let environment = ProcessInfo.processInfo.environment
func debug(_ message: String) {
    guard environment["LINGXI_TUI_DEBUG"] == "1" else { return }
    let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    FileHandle.standardError.write(Data("[\(timestamp)] [LingXiCoreHost] \(message)\n".utf8))
}

debug("configuration.begin")
let dataRoot = LingXiDataRootResolver.resolve(
    environment: environment,
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
)
let configurations = try ConfigurationStore(dataRoot: dataRoot)
let snapshot = try await configurations.load()
let credentials = try FileCredentialStore(dataRoot: dataRoot, passphrase: environment["LINGXI_CREDENTIALS_PASSPHRASE"])
let providers = try await RuntimeConfigurationResolver.resolveProviders(
    snapshot.providers,
    credentials: credentials,
    provenanceDirectory: dataRoot.appendingPathComponent("provider-provenance", isDirectory: true),
    diagnosticsEnabled: environment["LINGXI_PROVIDER_DIAGNOSTICS"] == "1",
    performanceDiagnosticsEnabled: environment["LINGXI_PERF_DEBUG"] == "1",
    environment: environment
)
let mcp = try await RuntimeConfigurationResolver.resolveMCP(snapshot.mcp, credentials: credentials, schemaStoreDirectory: dataRoot.appendingPathComponent("mcp-schemas", isDirectory: true))
let host = try CoreHost(
    providerAssembly: providers.assembly,
    providerMissingRequirements: providers.missingRequirements,
    modelRuntimes: providers.runtimes,
    defaultModelSelection: providers.defaultSelection,
    configuration: snapshot.core,
    dataRoot: dataRoot,
    mcpPager: mcp.pager,
    interactive: CoreHost.stdioInteractive(environment: environment),
    configurationStore: configurations,
    credentialStore: credentials
)
debug("configuration.end")
await host.start()
debug("host.start.end")
if CommandLine.arguments.contains("--vnext") {
    debug("vnext.server.begin")
    try await VNextStdioCoreServer(service: host).run()
} else {
    let server = StdioCoreServer(endpoint: host)
    try await server.run()
}
await host.shutdown()
