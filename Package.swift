// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lingxiagent", targets: ["lingxiagent"]),
        .executable(name: "LingXiCoreHost", targets: ["LingXiCoreHost"]),
        .executable(name: "LingXiTUI", targets: ["LingXiTUIApp"]),
        .library(name: "LingXiPluginSDK", targets: ["LingXiPluginSDK"]),
        .executable(name: "FoxPlugin", targets: ["FoxPlugin"]),
    ],
    targets: [
        // 演示与参考插件：FoxPlugin
        .executableTarget(
            name: "FoxPlugin",
            dependencies: ["LingXiPluginSDK"],
            path: "Plugins/FoxPlugin",
            exclude: ["README.md"]
        ),
        // 插件 SDK：供外部开发者开发 Swift 插件的标准库
        .target(name: "LingXiPluginSDK", dependencies: ["LingXiProtocol"]),
        // 平台层：跨平台系统抽象（macOS / Linux / Windows）
        .target(name: "LingXiPlatform", dependencies: ["LingXiProtocol"]),
        // 协议层：所有 Client 与 Core 共享的数据类型与契约。
        .target(name: "LingXiProtocol"),
        .target(name: "LingXiApplication", dependencies: ["LingXiClient", "LingXiProtocol", "LingXiPlatform"]),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),
        // Core：业务能力与状态权威。仅依赖 Protocol、Platform 与 PluginSDK 核心。
        .target(
            name: "LingXiCore",
            dependencies: ["LingXiProtocol", "LingXiPlatform", "LingXiPluginSDK", "CSQLite"],
            resources: [
                .copy("Resources/Configuration"),
                .copy("Provider/Products"),
                .copy("Provider/Protocols")
            ]
        ),
        // Client：所有客户端访问 Core 的正式入口。
        .target(name: "LingXiClient", dependencies: ["LingXiProtocol", "LingXiPlatform"]),
        .target(name: "OpenTUIShim"),
        .target(name: "LingXiTUIComponents", dependencies: ["LingXiProtocol", "OpenTUIShim", "LingXiPlatform"]),
        // Core Host executable：独立启动 Core 进程。
        .executableTarget(
            name: "LingXiCoreHost",
            dependencies: ["LingXiCore", "LingXiProtocol"]
        ),
        // Unified CLI tool: lingxiagent
        .executableTarget(
            name: "lingxiagent",
            dependencies: ["LingXiCore", "LingXiProtocol", "LingXiApplication", "LingXiTUI", "LingXiPlatform"]
        ),
        // TUI：Reference Client 库。禁止依赖 LingXiCore。
        .target(
            name: "LingXiTUI",
            dependencies: ["LingXiApplication", "LingXiTUIComponents", "LingXiPlatform"],
            exclude: ["RetainedTUI.swift"]
        ),
        // TUI 可执行封装，供 swift run LingXiTUI 启动
        .executableTarget(
            name: "LingXiTUIApp",
            dependencies: ["LingXiTUI"]
        ),
        .testTarget(
            name: "LingXiAgentTests",
            dependencies: ["LingXiProtocol", "LingXiCore", "LingXiClient", "LingXiApplication", "LingXiTUIComponents", "LingXiTUI", "LingXiPlatform", "LingXiPluginSDK"],
            exclude: ["VCR/README.md"],
            resources: [.copy("VCR/Fixtures"), .copy("VCR/Cassettes")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
