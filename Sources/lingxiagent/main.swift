import Foundation
import LingXiCore
import LingXiProtocol
import LingXiApplication
import LingXiTUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

AuthCLI.installSignalHandlers()

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
    await ApplicationTUI(options: options).run()
    exit(0)

case let .auth(authArgs):
    do {
        let output = try await AuthCLI.run(arguments: authArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .mcp(mcpArgs):
    do {
        let output = try await MCPCLI.run(arguments: mcpArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .skills(skillsArgs):
    do {
        let output = try await SkillsCLI.run(arguments: skillsArgs)
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .exec(execArgs):
    do {
        try await ExecCLI.run(arguments: execArgs)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .review(reviewArgs):
    do {
        try await ReviewCLI.run(arguments: reviewArgs)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case .doctor:
    do {
        let output = try await DoctorCLI.run()
        print(output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .resume(resumeArgs):
    do {
        let action = try await ResumeCLI.run(arguments: resumeArgs)
        switch action {
        case let .launch(sessionID, targetDir):
            if let targetDir, !targetDir.isEmpty, targetDir != FileManager.default.currentDirectoryPath {
                print("🔄 正在切换工作目录至: \(targetDir)")
                FileManager.default.changeCurrentDirectoryPath(targetDir)
            }
            await ApplicationTUI(options: TUILaunchOptions(resumeSessionID: sessionID)).run()
            exit(0)
        case let .output(msg):
            print(msg)
            exit(0)
        }
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case let .completion(compArgs):
    let output = CompletionCLI.run(arguments: compArgs)
    print(output)
    exit(0)

case .help:
    print(CLIParser.renderHelp())
    exit(0)

case .version:
    print("lingxiagent version \(CLIParser.version)")
    exit(0)
}


