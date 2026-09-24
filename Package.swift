// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lingxiagent", targets: ["lingxiagent"]),
        .executable(name: "lingxiagent-ops", targets: ["lingxiagent-ops"]),
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
        // Unified Interactive CLI tool: lingxiagent (Pure presentation, strictly no LingXiCore)
        .executableTarget(
            name: "lingxiagent",
            dependencies: ["LingXiProtocol", "LingXiApplication", "LingXiTUI", "LingXiPlatform"]
        ),
        // Operations & Diagnostics CLI: lingxiagent-ops (Links LingXiCore for backend administration)
        .executableTarget(
            name: "lingxiagent-ops",
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
        // FrontendKit: macOS/iOS GUI Shared Component Library (Strictly no LingXiCore)
        .target(
            name: "LingXiFrontendKit",
            dependencies: ["LingXiApplication", "LingXiClient", "LingXiProtocol"],
            path: "Apps/LingXiApp/Shared"
        ),

        .testTarget(
            name: "LingXiAgentTests",
            dependencies: [
                "LingXiProtocol", "LingXiCore", "LingXiClient", "LingXiApplication",
                "LingXiTUIComponents", "LingXiTUI", "LingXiPlatform", "LingXiPluginSDK",
                .target(name: "LingXiFrontendKit", condition: .when(platforms: [.macOS]))
            ],
            exclude: ["VCR/README.md"],
            resources: [.copy("VCR/Fixtures"), .copy("VCR/Cassettes")]
        ),
        // ContractTests targets (Strictly black-box: no @testable, no import LingXiCore)
        .testTarget(
            name: "LingXiWireContractTests",
            dependencies: ["LingXiProtocol"],
            path: "ContractTests/LingXiWireContractTests"
        ),
        .testTarget(
            name: "LingXiFrontendContractTests",
            dependencies: ["LingXiProtocol", "LingXiClient"],
            path: "ContractTests/LingXiFrontendContractTests"
        ),
        .testTarget(
            name: "LingXiPlatformContractTests",
            dependencies: ["LingXiProtocol", "LingXiPlatform"],
            path: "ContractTests/LingXiPlatformContractTests"
        ),
        .testTarget(
            name: "LingXiIPCRobustnessContractTests",
            dependencies: ["LingXiProtocol", "LingXiPlatform"],
            path: "ContractTests/LingXiIPCRobustnessContractTests"
        ),
        .testTarget(
            name: "LingXiTaskLifecycleContractTests",
            dependencies: ["LingXiProtocol", "LingXiPlatform", "CSQLite"],
            path: "ContractTests/LingXiTaskLifecycleContractTests"
        ),
        .testTarget(
            name: "LingXiCapabilityContractTests",
            dependencies: ["LingXiProtocol", "LingXiPlatform"],
            path: "ContractTests/LingXiCapabilityContractTests"
        ),
        .testTarget(
            name: "LingXiTraceContractTests",
            dependencies: ["LingXiProtocol"],
            path: "ContractTests/LingXiTraceContractTests"
        ),
        // Evaluation Runner target: independent decoupled benchmark executor
        .executableTarget(
            name: "LingXiEvalRunner",
            dependencies: ["LingXiClient", "LingXiProtocol"],
            path: "Evals/Runner"
        ),
    ],
    swiftLanguageModes: [.v5]
)
