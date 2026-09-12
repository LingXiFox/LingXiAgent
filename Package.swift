// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lingxiagent", targets: ["lingxiagent"]),
        .executable(name: "LingXiTUI", targets: ["LingXiTUIApp"]),
    ],
    targets: [
        // 协议层：所有 Client 与 Core 共享的数据类型与契约。
        .target(name: "LingXiProtocol"),
        .target(name: "LingXiApplication", dependencies: ["LingXiClient", "LingXiProtocol"]),
        // Core：业务能力与状态权威。仅依赖 Protocol。
        .target(
            name: "LingXiCore",
            dependencies: ["LingXiProtocol"],
            resources: [
                .copy("Resources/Configuration"),
                .copy("Provider/Products"),
                .copy("Provider/Protocols")
            ]
        ),
        // Client：所有客户端访问 Core 的正式入口。仅依赖 Protocol。
        .target(name: "LingXiClient", dependencies: ["LingXiProtocol"]),
        .target(name: "OpenTUIShim"),
        .target(name: "LingXiTUIComponents", dependencies: ["LingXiProtocol", "OpenTUIShim"]),
        // Core Host executable：独立启动 Core 进程。
        .executableTarget(
            name: "LingXiCoreHost",
            dependencies: ["LingXiCore", "LingXiProtocol"]
        ),
        // Unified CLI tool: lingxiagent
        .executableTarget(
            name: "lingxiagent",
            dependencies: ["LingXiCore", "LingXiProtocol", "LingXiApplication", "LingXiTUI"]
        ),
        // TUI：Reference Client 库。禁止依赖 LingXiCore。
        .target(
            name: "LingXiTUI",
            dependencies: ["LingXiApplication", "LingXiTUIComponents"],
            exclude: ["RetainedTUI.swift"]
        ),
        // TUI 可执行封装，供 swift run LingXiTUI 启动
        .executableTarget(
            name: "LingXiTUIApp",
            dependencies: ["LingXiTUI"]
        ),
        .testTarget(
            name: "LingXiAgentTests",
            dependencies: ["LingXiProtocol", "LingXiCore", "LingXiClient", "LingXiApplication", "LingXiTUIComponents", "LingXiTUI"],
            exclude: ["VCR/README.md"],
            resources: [.copy("VCR/Fixtures"), .copy("VCR/Cassettes")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
