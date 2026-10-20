// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LingXiCoreHost", targets: ["LingXiCoreHost"]),
        .executable(name: "LingXiPluginHost", targets: ["LingXiPluginHost"]),
        .executable(name: "LingXiTUI", targets: ["LingXiTUI"]),
        // A plugin is a loadable dynamic library; the .lxap bundle around it is assembled by the
        // packaging step, not by SwiftPM.
        .library(name: "LingXiContextProbe", type: .dynamic, targets: ["LingXiContextProbe"]),
        .library(name: "LingXiCProbe", type: .dynamic, targets: ["LingXiCProbe"]),
        .library(name: "DeepSeekProvider", type: .dynamic, targets: ["DeepSeekProvider"]),
        .library(name: "MiMoProvider", type: .dynamic, targets: ["MiMoProvider"]),
    ],
    targets: [
        .target(name: "LingXiKernel"),
        // The C half of the ABI. Kept separate because a Swift target cannot export C structs, and
        // the contract structs must be C types for @convention(c) to accept them.
        .target(name: "LingXiFrontendProtocol"),
        .target(name: "LingXiPluginABIC"),
        // The Swift half: Core-Host wire types. Deliberately depended on by the host and the runtime,
        // never by the kernel, which keeps its own ports instead (L0).
        .target(name: "LingXiPluginABI", dependencies: ["LingXiPluginABIC"]),
        // Custody of declared provider credentials. Linked only into the Core: the TUI and the plugin
        // host must not be able to reach a saved secret, and that is enforced by the link graph.
        .target(name: "LingXiCredentialStore", dependencies: ["LingXiPluginABI"]),
        .executableTarget(name: "LingXiCoreHost", dependencies: ["LingXiKernel", "LingXiPluginRuntime", "LingXiPluginABI", "LingXiFrontendProtocol", "LingXiCredentialStore"]),
        .executableTarget(name: "LingXiPluginHost", dependencies: ["LingXiPluginABI"]),
        .target(name: "LingXiPluginRuntime", dependencies: ["LingXiKernel", "LingXiPluginABI"]),
        // Official plugin sources live under Plugins/, one directory per plugin (Project-Conventions §二).
        .target(name: "LingXiContextProbe", dependencies: ["LingXiPluginABI"], path: "Plugins/LingXiContextProbe"),
        .target(name: "LingXiCProbe", dependencies: ["LingXiPluginABIC"], path: "Plugins/LingXiCProbe", publicHeadersPath: "."),
        .target(name: "DeepSeekProvider", dependencies: ["LingXiPluginABI"], path: "Plugins/DeepSeekProvider"),
        .target(name: "MiMoProvider", dependencies: ["LingXiPluginABI"], path: "Plugins/MiMoProvider"),
        .executableTarget(name: "LingXiTUI", dependencies: ["LingXiFrontendProtocol"]),
        .testTarget(name: "LingXiKernelTests", dependencies: ["LingXiKernel"]),
        .testTarget(name: "LingXiCredentialStoreTests", dependencies: ["LingXiCredentialStore", "LingXiPluginABI"]),
        // L2: real Host process, real dlopen, real plugin dylib, real fault injection.
        .testTarget(name: "ContractTests", dependencies: ["LingXiKernel", "LingXiPluginRuntime", "LingXiPluginABI", "LingXiFrontendProtocol"], path: "ContractTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
