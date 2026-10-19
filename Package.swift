// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "LingXiKernel"),
        .executableTarget(name: "LingXiCoreHost", dependencies: ["LingXiKernel"]),
        .testTarget(name: "LingXiKernelTests", dependencies: ["LingXiKernel"]),
    ],
    swiftLanguageModes: [.v6]
)
