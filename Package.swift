// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LingXiCoreHost", targets: ["LingXiCoreHost"]),
        .executable(name: "LingXiPluginHost", targets: ["LingXiPluginHost"]),
        // A plugin is a loadable dynamic library; the .lxap bundle around it is assembled by the
        // packaging step, not by SwiftPM.
        .library(name: "LingXiContextProbe", type: .dynamic, targets: ["LingXiContextProbe"]),
        .library(name: "LingXiCProbe", type: .dynamic, targets: ["LingXiCProbe"]),
    ],
    targets: [
        .target(name: "LingXiKernel"),
        // The C half of the ABI. Kept separate because a Swift target cannot export C structs, and
        // the contract structs must be C types for @convention(c) to accept them.
        .target(name: "LingXiPluginABIC"),
        // The Swift half: Core-Host wire types. Deliberately depended on by the host and the runtime,
        // never by the kernel, which keeps its own ports instead (L0).
        .target(name: "LingXiPluginABI", dependencies: ["LingXiPluginABIC"]),
        .executableTarget(name: "LingXiCoreHost", dependencies: ["LingXiKernel"]),
        .executableTarget(name: "LingXiPluginHost", dependencies: ["LingXiPluginABI"]),
        .target(name: "LingXiPluginRuntime", dependencies: ["LingXiKernel", "LingXiPluginABI"]),
        // Official plugin sources live under Plugins/, one directory per plugin (Project-Conventions §二).
        .target(name: "LingXiContextProbe", dependencies: ["LingXiPluginABI"], path: "Plugins/LingXiContextProbe"),
        .target(name: "LingXiCProbe", dependencies: ["LingXiPluginABIC"], path: "Plugins/LingXiCProbe", publicHeadersPath: "."),
        .testTarget(name: "LingXiKernelTests", dependencies: ["LingXiKernel"]),
        // L2: real Host process, real dlopen, real plugin dylib, real fault injection.
        .testTarget(name: "ContractTests", dependencies: ["LingXiKernel", "LingXiPluginRuntime", "LingXiPluginABI"], path: "ContractTests"),
    ],
    swiftLanguageModes: [.v6]
)
