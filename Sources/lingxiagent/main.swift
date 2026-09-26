import Foundation
import LingXiProtocol
import LingXiApplication
import LingXiTUI
import LingXiWebUI
import LingXiPlatform

let args = Array(CommandLine.arguments.dropFirst())
let route = CLIParser.parse(arguments: args)

switch route {
case let .tui(options):
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
            message = error.localizedDescription
        }

        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }

case let .serve(options):
    do {
        try await ServeCLI.run(options: options)
        exit(0)
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
    print("lingxiagent version \(CLIParser.version) (\(CLIParser.releaseName))")
    exit(0)

case .auth, .mcp, .skills, .exec, .review, .doctor, .resume, .acp, .task, .smoke:
    let cmd = args.first ?? "subcommand"
    print("🦊 [LingXiAgent] The '\(cmd)' operation is managed by the operations CLI.")
    print("Please run: lingxiagent-ops \(args.joined(separator: " "))")
    exit(1)
}
