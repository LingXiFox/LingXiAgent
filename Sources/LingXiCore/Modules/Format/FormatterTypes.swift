import Foundation

/// 格式化工具配置项
public struct FormatterConfig: Sendable, Codable, Equatable {
    public let name: String
    public let command: [String]
    public let extensions: [String]
    public let enabled: Bool
    public let fallbackCommand: [String]?

    public init(
        name: String,
        command: [String],
        extensions: [String],
        enabled: Bool = true,
        fallbackCommand: [String]? = nil
    ) {
        self.name = name
        self.command = command
        self.extensions = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        self.enabled = enabled
        self.fallbackCommand = fallbackCommand
    }

    /// 开箱即用的预置主流语言代码格式化工具矩阵
    public static var builtinConfigurations: [FormatterConfig] {
        [
            // 1. Swift
            FormatterConfig(
                name: "swift-format",
                command: ["swift-format", "format", "--in-place", "$FILE"],
                extensions: ["swift"]
            ),
            // 2. Python
            FormatterConfig(
                name: "ruff",
                command: ["ruff", "format", "$FILE"],
                extensions: ["py", "pyi"],
                fallbackCommand: ["black", "$FILE"]
            ),
            // 3. TypeScript / JavaScript / Web
            FormatterConfig(
                name: "prettier",
                command: ["npx", "prettier", "--write", "$FILE"],
                extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "md", "html", "css", "yaml", "yml"],
                fallbackCommand: ["npx", "@biomejs/biome", "format", "--write", "$FILE"]
            ),
            // 4. Rust
            FormatterConfig(
                name: "rustfmt",
                command: ["rustfmt", "$FILE"],
                extensions: ["rs"]
            ),
            // 5. Go
            FormatterConfig(
                name: "gofmt",
                command: ["gofmt", "-w", "$FILE"],
                extensions: ["go"],
                fallbackCommand: ["goimports", "-w", "$FILE"]
            ),
            // 6. C / C++
            FormatterConfig(
                name: "clang-format",
                command: ["clang-format", "-i", "$FILE"],
                extensions: ["c", "cpp", "cc", "cxx", "h", "hpp", "hh"]
            )
        ]
    }
}

/// 格式化执行结果
public struct FormatterResult: Sendable, Codable, Equatable {
    public let path: String
    public let formatterName: String
    public let success: Bool
    public let changed: Bool
    public let message: String?
    public let durationMs: Double

    public init(
        path: String,
        formatterName: String,
        success: Bool,
        changed: Bool = false,
        message: String? = nil,
        durationMs: Double = 0.0
    ) {
        self.path = path
        self.formatterName = formatterName
        self.success = success
        self.changed = changed
        self.message = message
        self.durationMs = durationMs
    }
}
