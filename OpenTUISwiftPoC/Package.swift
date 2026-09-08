// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenTUISwiftPoC",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenTUISwiftPoC", targets: ["OpenTUISwiftPoC"])],
    targets: [.executableTarget(name: "OpenTUISwiftPoC")]
)
