// swift-tools-version:6.0

import PackageDescription

// The macOS GUI is SwiftUI-only source and is not part of the CLI / TUI / WebUI delivery scope;
// compiling it on Linux or Windows dies on `import SwiftUI`. The manifest is the one place that
// decides which targets exist per host, so the GUI is admitted here rather than scattered as
// `#if os(...)` through the sources.
#if os(macOS)
let guiProducts: [Product] = [
    .library(name: "LingXiFrontendKit", targets: ["LingXiFrontendKit"]),
    .executable(name: "LingXiMacApp", targets: ["LingXiMacApp"]),
]
let guiTargets: [Target] = [
    // FrontendKit: the macOS GUI component library. It is not platform-neutral and was never
    // going to be: `DesignSystem/Tokens.swift`, `Components.swift` and `WallpaperStyle.swift`
    // import AppKit with no `#if` guard at all, so iOS cannot compile this layer as it stands.
    // It therefore sits under `Apps/macOS`, named after the module rather than after a promise
    // of reuse it never kept.
    .target(
        name: "LingXiFrontendKit",
        dependencies: ["LingXiApplication", "LingXiClient", "LingXiProtocol"],
        path: "Apps/macOS/FrontendKit",
        // App icon previews exported from `LingXiAgent Icon/ICON.icon` (Default / Dark).
        resources: [.copy("Resources")]
    ),
    // macOS GUI executable entry. Wrapped into LingXiAgent.app by Scripts/bundle-mac-app.sh.
    // The library keeps its own directory: pointing both targets at `Apps/macOS` is rejected
    // outright with "target 'LingXiMacApp' has overlapping sources", because a recursive sweep
    // from that path also claims `LingXiMacApp.swift` for the library. Disjoint target paths are
    // what keeps the two lists below from ever needing to grow as the GUI gains files.
    .executableTarget(
        name: "LingXiMacApp",
        dependencies: ["LingXiFrontendKit"],
        path: "Apps/macOS",
        exclude: ["FrontendKit", "LingXiMacApp.xcodeproj"],
        sources: ["LingXiMacApp.swift"]
    ),
]
let guiTestDependency: [Target.Dependency] = [.target(name: "LingXiFrontendKit", condition: .when(platforms: [.macOS]))]
#else
let guiProducts: [Product] = []
let guiTargets: [Target] = []
let guiTestDependency: [Target.Dependency] = []
#endif

// 两个公共 SDK 住在各自的仓库里，通过公开 SwiftPM 分发接入 —— LingXiAgent 是它们的
// 普通消费者，与第三方拿到的完全同一份构件。没有 path 依赖，也没有仓库内副本：
// 这里一旦解析失败，就说明它们还不具备对第三方发布的条件。
//
// 单独成句而不是内联：整个 Package(...) 字面量已经大到 SwiftPM 无法在合理时间内
// 完成类型推断，拆开是必需的，不是风格问题。
let publicSDKDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/LingXiFox/LingXiModelSDK.git", from: "0.1.0"),
    .package(url: "https://github.com/LingXiFox/LingXiPluginSDK.git", from: "0.1.0"),
]

// 目标清单单独成句。Package(...) 这一个字面量在本仓库已经长到 SwiftPM 无法在合理
// 时间内完成类型推断（“the compiler is unable to type-check this expression in
// reasonable time”），加上显式类型的数组绑定是解法，不是排版偏好。
let packageTargets: [Target] = [
        // 演示与参考插件：FoxPlugin
        .executableTarget(
            name: "FoxPlugin",
            dependencies: [.product(name: "LingXiPluginSDK", package: "LingXiPluginSDK")],
            path: "Plugins/FoxPlugin",
            exclude: ["README.md"]
        ),
        // 插件 SDK：供外部开发者开发 Swift 插件的标准库
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
        // Core：业务能力与状态权威。两个公共 SDK 都以 SwiftPM 外部产品的形态接入 ——
        // 与第三方拿到的是同一份构件，没有仓库内的特殊通道。
        .target(
            name: "LingXiCore",
            dependencies: [
                "LingXiProtocol", "LingXiPlatform", "CSQLite",
                .product(name: "LingXiModelSDK", package: "LingXiModelSDK"),
                .product(name: "LingXiPluginSDK", package: "LingXiPluginSDK"),
            ],
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
            dependencies: ["LingXiProtocol", "LingXiApplication", "LingXiTUI", "LingXiWebUI", "LingXiPlatform"]
        ),
        // WebUI：与 CLI/TUI 并列的正式浏览器前端，仅通过 Frontend 契约访问 Runtime（strictly no LingXiCore）。
        .target(
            name: "LingXiWebUI",
            dependencies: ["LingXiProtocol", "LingXiPlatform", "LingXiApplication", "LingXiClient"],
            resources: [
                .copy("Assets")
            ]
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
        // FrontendKit / LingXiMacApp are declared in `guiTargets` above.

        .testTarget(
            name: "LingXiAgentTests",
            dependencies: [
                "LingXiProtocol", "LingXiCore", "LingXiClient", "LingXiApplication",
                "LingXiTUIComponents", "LingXiTUI", "LingXiPlatform",
                .product(name: "LingXiModelSDK", package: "LingXiModelSDK"),
                .product(name: "LingXiPluginSDK", package: "LingXiPluginSDK"),
            ] + guiTestDependency,
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
]

let package = Package(
    name: "LingXiAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lingxiagent", targets: ["lingxiagent"]),
        .executable(name: "lingxiagent-ops", targets: ["lingxiagent-ops"]),
        .executable(name: "LingXiCoreHost", targets: ["LingXiCoreHost"]),
        .executable(name: "LingXiTUI", targets: ["LingXiTUIApp"]),
        .executable(name: "FoxPlugin", targets: ["FoxPlugin"]),
    ] + guiProducts,
    dependencies: publicSDKDependencies,
    targets: packageTargets + guiTargets,
    swiftLanguageModes: [.v5]
)
