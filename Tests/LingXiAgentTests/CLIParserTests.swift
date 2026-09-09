import Foundation
import Testing
import LingXiProtocol
import LingXiTUI

struct CLIParserTests {
    @Test func emptyArgumentsLaunchesDefaultTUI() {
        let route = CLIParser.parse(arguments: [])
        #expect(route == .tui(.default))
    }

    @Test func directPromptLaunchesTUIWithInitialPrompt() {
        let route = CLIParser.parse(arguments: ["帮我分析当前项目结构"])
        let expected = TUILaunchOptions(initialPrompt: "帮我分析当前项目结构")
        #expect(route == .tui(expected))
    }

    @Test func multiWordDirectPromptCombinesCorrectly() {
        let route = CLIParser.parse(arguments: ["帮我", "分析", "当前项目结构"])
        let expected = TUILaunchOptions(initialPrompt: "帮我 分析 当前项目结构")
        #expect(route == .tui(expected))
    }

    @Test func yoloFlagEnablesYoloMode() {
        let routeLong = CLIParser.parse(arguments: ["--yolo", "修复全部测试"])
        #expect(routeLong == .tui(TUILaunchOptions(initialPrompt: "修复全部测试", isYoloMode: true)))

        let routeShort = CLIParser.parse(arguments: ["-y", "运行构建"])
        #expect(routeShort == .tui(TUILaunchOptions(initialPrompt: "运行构建", isYoloMode: true)))
    }

    @Test func modelFlagsOverrideInitialModelID() {
        let routeSeparate = CLIParser.parse(arguments: ["-m", "gpt-5-5", "测试对话"])
        #expect(routeSeparate == .tui(TUILaunchOptions(initialPrompt: "测试对话", initialModelID: "gpt-5-5")))

        let routeEqual = CLIParser.parse(arguments: ["--model=bai/deepseek-v4-flash", "你好"])
        #expect(routeEqual == .tui(TUILaunchOptions(initialPrompt: "你好", initialModelID: "bai/deepseek-v4-flash")))
    }

    @Test func workingDirFlagsOverrideDirectory() {
        let route = CLIParser.parse(arguments: ["-C", "/tmp/lingxi-work", "--yolo"])
        #expect(route == .tui(TUILaunchOptions(initialWorkingDir: "/tmp/lingxi-work", isYoloMode: true)))

        let routeEqual = CLIParser.parse(arguments: ["--cd=/tmp/other"])
        #expect(routeEqual == .tui(TUILaunchOptions(initialWorkingDir: "/tmp/other")))
    }

    @Test func reasoningEffortFlagsOverrideEffort() {
        let route = CLIParser.parse(arguments: ["-e", "high"])
        #expect(route == .tui(TUILaunchOptions(reasoningEffort: .high)))

        let routeEqual = CLIParser.parse(arguments: ["--effort=max"])
        #expect(routeEqual == .tui(TUILaunchOptions(reasoningEffort: .max)))
    }

    @Test func noAltScreenFlagSetsOption() {
        let route = CLIParser.parse(arguments: ["--no-alt-screen"])
        #expect(route == .tui(TUILaunchOptions(noAltScreen: true)))
    }

    @Test func doubleDashSeparatesPrompt() {
        let route = CLIParser.parse(arguments: ["--yolo", "--", "--model", "is-a-prompt"])
        #expect(route == .tui(TUILaunchOptions(initialPrompt: "--model is-a-prompt", isYoloMode: true)))
    }

    @Test func authSubcommandsRouteToAuthCLI() {
        let routeAuth = CLIParser.parse(arguments: ["auth", "status"])
        #expect(routeAuth == .auth(["auth", "status"]))

        let routeLogin = CLIParser.parse(arguments: ["login", "openai-codex"])
        #expect(routeLogin == .auth(["login", "openai-codex"]))

        let routeMatrix = CLIParser.parse(arguments: ["matrix"])
        #expect(routeMatrix == .auth(["matrix"]))

        let routeModels = CLIParser.parse(arguments: ["models", "openai-codex"])
        #expect(routeModels == .auth(["models", "openai-codex"]))
    }

    @Test func mcpSubcommandsRouteToMCPCLI() {
        let routeList = CLIParser.parse(arguments: ["mcp", "list"])
        #expect(routeList == .mcp(["mcp", "list"]))

        let routeStatus = CLIParser.parse(arguments: ["mcp", "status", "fetch"])
        #expect(routeStatus == .mcp(["mcp", "status", "fetch"]))

        let routeEnable = CLIParser.parse(arguments: ["mcp", "enable", "github"])
        #expect(routeEnable == .mcp(["mcp", "enable", "github"]))
    }

    @Test func skillsSubcommandsRouteToSkillsCLI() {
        let routeList = CLIParser.parse(arguments: ["skills", "list"])
        #expect(routeList == .skills(["skills", "list"]))

        let routeSkillSingular = CLIParser.parse(arguments: ["skill", "info", "test-runner"])
        #expect(routeSkillSingular == .skills(["skill", "info", "test-runner"]))

        let routeEnable = CLIParser.parse(arguments: ["skills", "enable", "debugger"])
        #expect(routeEnable == .skills(["skills", "enable", "debugger"]))
    }

    @Test func extensionLaunchFlagsSetOptions() {
        let route = CLIParser.parse(arguments: [
            "--enable-mcp", "server1",
            "--disable-mcp=server2",
            "--enable-skill", "skillA",
            "--disable-skill=skillB",
            "-y"
        ])
        let expected = TUILaunchOptions(
            isYoloMode: true,
            mcpEnables: ["server1"],
            mcpDisables: ["server2"],
            skillEnables: ["skillA"],
            skillDisables: ["skillB"]
        )
        #expect(route == .tui(expected))
    }

    @Test func phase3SubcommandsRouteCorrectly() {
        let routeExec = CLIParser.parse(arguments: ["exec", "分析代码"])
        #expect(routeExec == .exec(["exec", "分析代码"]))

        let routeExecAlias = CLIParser.parse(arguments: ["e", "-y", "run"])
        #expect(routeExecAlias == .exec(["e", "-y", "run"]))

        let routeReview = CLIParser.parse(arguments: ["review", "--base", "main"])
        #expect(routeReview == .review(["review", "--base", "main"]))

        let routeDoctor = CLIParser.parse(arguments: ["doctor"])
        #expect(routeDoctor == .doctor(["doctor"]))

        let routeResume = CLIParser.parse(arguments: ["resume", "--last"])
        #expect(routeResume == .resume(["resume", "--last"]))

        let routeCompletion = CLIParser.parse(arguments: ["completion", "zsh"])
        #expect(routeCompletion == .completion(["completion", "zsh"]))
    }

    @Test func helpAndVersionFlags() {
        #expect(CLIParser.parse(arguments: ["--help"]) == .help)
        #expect(CLIParser.parse(arguments: ["-h"]) == .help)
        #expect(CLIParser.parse(arguments: ["--version"]) == .version)
        #expect(CLIParser.parse(arguments: ["-v"]) == .version)

        let helpText = CLIParser.renderHelp()
        #expect(helpText.contains("--yolo"))
        #expect(helpText.contains("auth <command>"))
        #expect(helpText.contains("mcp <command>"))
        #expect(helpText.contains("skills <command>"))
        #expect(helpText.contains("exec <prompt>"))
        #expect(helpText.contains("review [options]"))
        #expect(helpText.contains("doctor"))
        #expect(helpText.contains("resume [sessionID]"))
        #expect(helpText.contains("completion <shell>"))
    }
}

