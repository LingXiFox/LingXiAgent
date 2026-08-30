import Foundation
import LingXiCore
import LingXiProtocol

let environment = ProcessInfo.processInfo.environment
let dataRoot = LingXiDataRootResolver.resolve(
    environment: environment,
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
)
let configurations = try ConfigurationStore(dataRoot: dataRoot)
let snapshot = try await configurations.load()
let credentials = try FileCredentialStore(dataRoot: dataRoot)
let providers = try await RuntimeConfigurationResolver.resolveProviders(
    snapshot.providers,
    credentials: credentials,
    diagnosticsEnabled: environment["LINGXI_PROVIDER_DIAGNOSTICS"] == "1",
    performanceDiagnosticsEnabled: environment["LINGXI_PERF_DEBUG"] == "1"
)
let mcp = try await RuntimeConfigurationResolver.resolveMCP(snapshot.mcp, credentials: credentials)
let host = try CoreHost(
    providerAssembly: providers.assembly,
    providerMissingRequirements: providers.missingRequirements,
    modelRuntimes: providers.runtimes,
    defaultModelSelection: providers.defaultSelection,
    configuration: snapshot.core,
    dataRoot: dataRoot,
    mcpPager: mcp.pager
)
await host.start()
let server = StdioCoreServer(endpoint: host)
try await server.run()
await host.shutdown()
