import Foundation
import LingXiCore
import LingXiProtocol
import LingXiApplication
import LingXiTUI

let args = Array(CommandLine.arguments.dropFirst())
let route = CLIParser.parse(arguments: args)

switch route {
case let .tui(options):
    // 如果有 MCP 或 Skills 的启动配置变更，先执行应用
    for mcp in options.mcpEnables {
        _ = try? await MCPCLI.run(arguments: ["enable", mcp])
    }
    for mcp in options.mcpDisables {
        _ = try? await MCPCLI.run(arguments: ["disable", mcp])
    }
    for skill in options.skillEnables {
        _ = try? await SkillsCLI.run(arguments: ["enable", skill])
    }
    for skill in options.skillDisables {
        _ = try? await SkillsCLI.run(arguments: ["disable", skill])
    }
    do {
        let root = AppCompositionRoot(configuration: options.applicationConfiguration)
        let tui = ApplicationTUI(options: options)
        try await root.launch(with: tui)
        exit(0)
    } catch {
        let message: String
        if let posix = error as? POSIXError, posix.code == .EIO || posix.code == .ENOTTY {
            message = "Interactive TUI requires a controlling terminal (TTY)."
        } else {
            message = error.userMessage
        }
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }

case let .auth(authArgs):
    AuthCLI.installSignalHandlers()
    do {
        let output = try await AuthCLI.run(arguments: authArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .mcp(mcpArgs):
    do {
        let output = try await MCPCLI.run(arguments: mcpArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .skills(skillsArgs):
    do {
        let output = try await SkillsCLI.run(arguments: skillsArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .exec(execArgs):
    do {
        try await ExecCLI.run(arguments: execArgs)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .review(reviewArgs):
    do {
        try await ReviewCLI.run(arguments: reviewArgs)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case .doctor:
    do {
        let output = try await DoctorCLI.run()
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .resume(resumeArgs):
    do {
        let env = ProcessInfo.processInfo.environment
        let dataRoot = LingXiDataRootResolver.resolve(
            environment: env,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let summaries = (try? SQLitePersistenceStore.loadAllGlobalSessions(dataRoot: dataRoot)) ?? []
        let action = ResumeCLI.run(arguments: resumeArgs, summaries: summaries)
        switch action {
        case let .launch(sessionID, targetDir):
            if let targetDir, !targetDir.isEmpty, targetDir != FileManager.default.currentDirectoryPath {
                print("🔄 正在切换工作目录至: \(targetDir)")
                FileManager.default.changeCurrentDirectoryPath(targetDir)
            }
            let resumeOptions = TUILaunchOptions(resumeSessionID: sessionID)
            let root = AppCompositionRoot(configuration: resumeOptions.applicationConfiguration)
            let tui = ApplicationTUI(options: resumeOptions)
            try await root.launch(with: tui)
            exit(0)
        case let .output(msg):
            print(msg)
            exit(0)
        }
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case let .completion(compArgs):
    let output = CompletionCLI.run(arguments: compArgs)
    print(output)
    exit(0)

case .acp:
    do {
        let env = ProcessInfo.processInfo.environment
        let dataRoot = LingXiDataRootResolver.resolve(
            environment: env,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let configurations = try ConfigurationStore(dataRoot: dataRoot)
        let snapshot = try await configurations.load()
        let credentials = try PlatformSecureCredentialStore(dataRoot: dataRoot, passphrase: env["LINGXI_CREDENTIALS_PASSPHRASE"])
        let providers = try await RuntimeConfigurationResolver.resolveProviders(
            snapshot.providers,
            credentials: credentials,
            provenanceDirectory: dataRoot.appendingPathComponent("provider-provenance", isDirectory: true),
            diagnosticsEnabled: env["LINGXI_PROVIDER_DIAGNOSTICS"] == "1",
            performanceDiagnosticsEnabled: env["LINGXI_PERF_DEBUG"] == "1",
            environment: env
        )
        let host = try CoreHost(
            providerAssembly: providers.assembly,
            providerMissingRequirements: providers.missingRequirements,
            modelRuntimes: providers.runtimes,
            defaultModelSelection: providers.defaultSelection,
            configuration: snapshot.core,
            dataRoot: dataRoot,
            interactive: false,
            configurationStore: configurations,
            credentialStore: credentials
        )
        await host.start()
        let server = LingXiACPServer(service: host)
        try await server.run()
        await host.shutdown()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ACP Server Error: \(error.userMessage)\n".utf8))
        exit(1)
    }

case .help:
    print(CLIParser.renderHelp())
    exit(0)

case .version:
    print("lingxiagent version \(CLIParser.version) (\(CLIParser.releaseName))")
    exit(0)

case .smoke:
    print("🦊 [LingXiAgent Smoke] Initializing CoreHost subsystem...")
    do {
        let env = ProcessInfo.processInfo.environment
        let dataRoot = LingXiDataRootResolver.resolve(
            environment: env,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let configurations = try ConfigurationStore(dataRoot: dataRoot)
        _ = try await configurations.load()
        print("✓ CoreHost configuration & data store operational")

        print("🦊 [LingXiAgent Smoke] Initializing TUI Terminal & Renderer...")
        let walkedTerminal = try ApplicationTUI.smokeCheck()
        print(walkedTerminal
            ? "✓ TUI renderer & fallback pipeline operational"
            : "· no controlling terminal: raw-mode legs skipped, frame pipeline verified headless")

        print("✓ [LingXiAgent Smoke] All subsystems verified successfully.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Smoke Test Error: \(error.userMessage)\n".utf8))
        exit(1)
    }
}


