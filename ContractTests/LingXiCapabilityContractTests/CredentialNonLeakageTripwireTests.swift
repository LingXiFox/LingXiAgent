import Foundation
import Testing
import LingXiProtocol
import LingXiPlatform

/// Tripwire for the two child-process spawn sites that used to leak the host's
/// provider credentials — `PluginProcessHost.start` (which set no `proc.environment`
/// at all, so Foundation forwarded every parent var including
/// `LINGXI_CREDENTIALS_PASSPHRASE` that `LingXiCoreHost/main.swift` and
/// `lingxiagent/main.swift` put into the process env) and `BrowserHostClient.init`
/// (which copied `ProcessInfo.processInfo.environment` whole). Both now go through
/// `EnvironmentSanitizer.sanitized()`.
///
/// The MCP stdio transport still forwards resolver-provided values into the child
/// env. That path is intentionally left for the P27 CredentialBroker rewrite —
/// restricting it here would break every existing `mcpServers.*.env` config.
struct CredentialNonLeakageTripwireTests {

    private static let sentinelPassphrase = "sentinel-lingxi-passphrase-do-not-leak"
    private static let sentinelAPIKey = "sk-sentinel-do-not-leak"
    private static let sentinelToken = "ghp_sentinel_do_not_leak"
    private static let sentinelSecret = "aws-secret-key-sentinel-do-not-leak"
    private static let sentinelPassword = "hunter2-sentinel-do-not-leak"

    @Test("sanitizer strips every credential-shaped var the P22.1 leaks exposed")
    func sanitizerStripsCredentialVars() {
        let hostile: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/root",
            "LINGXI_CREDENTIALS_PASSPHRASE": Self.sentinelPassphrase,
            "LINGXI_DATA_DIR": "/var/lib/lingxi-secret",
            "LINGXI_STORAGE_ROOT": "/var/lib/lingxi-root",
            "OPENAI_API_KEY": Self.sentinelAPIKey,
            "ANTHROPIC_API_KEY": Self.sentinelAPIKey,
            "GITHUB_TOKEN": Self.sentinelToken,
            "AWS_SECRET_ACCESS_KEY": Self.sentinelSecret,
            "DB_PASSWORD": Self.sentinelPassword,
        ]
        let sanitized = EnvironmentSanitizer.sanitized(from: hostile)

        for (key, value) in sanitized {
            #expect(!key.hasPrefix("LINGXI_"), "sanitizer left a LINGXI_* key: \(key)")
            #expect(value != Self.sentinelPassphrase, "sanitizer forwarded the vault passphrase")
            #expect(value != Self.sentinelAPIKey, "sanitizer forwarded an API key")
            #expect(value != Self.sentinelToken, "sanitizer forwarded a token")
            #expect(value != Self.sentinelSecret, "sanitizer forwarded a secret")
            #expect(value != Self.sentinelPassword, "sanitizer forwarded a password")
        }

        for forbidden in [
            "LINGXI_CREDENTIALS_PASSPHRASE",
            "LINGXI_DATA_DIR",
            "LINGXI_STORAGE_ROOT",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "GITHUB_TOKEN",
            "AWS_SECRET_ACCESS_KEY",
            "DB_PASSWORD",
        ] {
            #expect(sanitized[forbidden] == nil, "sanitizer left \(forbidden)")
        }

        // PATH and HOME must survive so the child can operate.
        #expect(sanitized["PATH"] == "/usr/bin:/bin")
        #expect(sanitized["HOME"] == "/root")
    }

    @Test("sanitizer is a strict allow-list, not a filter")
    func sanitizerIsStrictAllowList() {
        // Anything not in the allow-list is dropped, including benign-looking variables.
        // Locking this in makes accidental widening impossible.
        let hostile: [String: String] = [
            "PATH": "/usr/bin",
            "MY_INTERNAL_APP_SECRET": "top-secret",
            "MY_INTERNAL_APP_TOKEN": "abc",
            "RANDOM_UNRELATED_ENV": "hi",
        ]
        let sanitized = EnvironmentSanitizer.sanitized(from: hostile)
        #expect(sanitized["MY_INTERNAL_APP_SECRET"] == nil)
        #expect(sanitized["MY_INTERNAL_APP_TOKEN"] == nil)
        #expect(sanitized["RANDOM_UNRELATED_ENV"] == nil)
        #expect(sanitized["PATH"] == "/usr/bin")
    }

    /// The concrete tripwire: put the sentinels into the *test process* env, spawn
    /// a shell child whose environment came from `EnvironmentSanitizer.sanitized()`,
    /// and prove the child cannot read any credential sentinel from its own env.
    /// This mirrors exactly what an overreaching plugin or browser sidecar would
    /// have seen before the P22.1 fix.
    @Test("a child spawned with sanitized env sees no credential")
    func childSeesNoCredential() async throws {
        #if !os(Windows)
        setenv("LINGXI_CREDENTIALS_PASSPHRASE", Self.sentinelPassphrase, 1)
        setenv("OPENAI_API_KEY", Self.sentinelAPIKey, 1)
        defer {
            unsetenv("LINGXI_CREDENTIALS_PASSPHRASE")
            unsetenv("OPENAI_API_KEY")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "env"]
        proc.environment = EnvironmentSanitizer.sanitized()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        // Drain to EOF *before* waiting: a child that fills the pipe buffer while the parent sits
        // in `waitUntilExit()` deadlocks, and both `env` and `cmd /c set` print the whole
        // environment.
        let reader = out.fileHandleForReading
        let data = reader.readDataToEndOfFile()
        proc.waitUntilExit()
        let dumped = String(decoding: data, as: UTF8.self)

        #expect(!dumped.contains(Self.sentinelPassphrase), "child env contained the vault passphrase")
        #expect(!dumped.contains(Self.sentinelAPIKey), "child env contained an API key")
        #expect(!dumped.contains("LINGXI_CREDENTIALS_PASSPHRASE="))
        #expect(!dumped.contains("OPENAI_API_KEY="))
        #else
        // Windows reaches the same production call, with the two platform differences the
        // assertion has to know about: the sentinels are put into the inherited environment
        // explicitly instead of through `setenv`, and the child prints its own environment via
        // `cmd.exe`'s `set` because there is no `/bin/sh`. Variable names are case-insensitive
        // there, so the name assertions compare uppercased text.
        var inherited = ProcessInfo.processInfo.environment
        inherited["LINGXI_CREDENTIALS_PASSPHRASE"] = Self.sentinelPassphrase
        inherited["OPENAI_API_KEY"] = Self.sentinelAPIKey

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LingXiPlatform.process.resolveExecutable(
            named: "cmd", customSearchPaths: nil) ?? "C:\\Windows\\System32\\cmd.exe")
        proc.arguments = ["/c", "set"]
        proc.environment = EnvironmentSanitizer.sanitized(from: inherited)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        // Drain to EOF *before* waiting: a child that fills the pipe buffer while the parent sits
        // in `waitUntilExit()` deadlocks, and both `env` and `cmd /c set` print the whole
        // environment.
        let reader = out.fileHandleForReading
        let data = reader.readDataToEndOfFile()
        proc.waitUntilExit()
        let dumped = String(decoding: data, as: UTF8.self)
        let upperDumped = dumped.uppercased()

        #expect(!dumped.contains(Self.sentinelPassphrase), "child env contained the vault passphrase")
        #expect(!dumped.contains(Self.sentinelAPIKey), "child env contained an API key")
        #expect(!upperDumped.contains("LINGXI_CREDENTIALS_PASSPHRASE="))
        #expect(!upperDumped.contains("OPENAI_API_KEY="))
        #endif
    }
}
