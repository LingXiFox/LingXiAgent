import Foundation
import LingXiPlatform
import LingXiClient
import LingXiProtocol

public enum ReviewCLI {

    public static func run(arguments: [String]) async throws {
        var args = arguments
        if args.first == "review" {
            args.removeFirst()
        }

        var baseBranch: String?
        var commit: String?
        var isYolo = false
        var modelID: String?
        var effortStr: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--base" && i + 1 < args.count {
                baseBranch = args[i + 1]
                i += 2
            } else if arg == "--commit" && i + 1 < args.count {
                commit = args[i + 1]
                i += 2
            } else if arg == "-y" || arg == "--yolo" {
                isYolo = true
                i += 1
            } else if arg == "-m" || arg == "--model" {
                if i + 1 < args.count {
                    modelID = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg == "-e" || arg == "--effort" {
                if i + 1 < args.count {
                    effortStr = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg == "-h" || arg == "--help" {
                print(renderHelp())
                return
            } else {
                i += 1
            }
        }

        // 1. Check Git repository
        guard FileManager.default.fileExists(atPath: ".git") || hasGitParent() else {
            FileHandle.standardError.write(Data("Error: Current directory is not a git repository.\n".utf8))
            exit(1)
        }

        // 2. Extract git diff —— CLI 是前端：它经 Core 的结构化 Git RPC 取内容，
        // 不自己启动 git 进程、不自己拼 argv（契约第十、十一节）。
        // Core 侧 argv 与执行只有一份（GitRunner），CLI 与 GUI / Agent 因此语义一致。
        let workingDirectory = URL(fileURLWithPath: LingXiPlatform.process.currentWorkingDirectory())
        let client = try await LingXiClientVNext.stdioCore(interactive: false, workingDirectory: workingDirectory)
        var diffContent = ""
        var dirtyPathCount = 0
        do {
            let requested = GitDiffRequest(scope: .head, baseReference: baseBranch, commitReference: commit, includeFileStats: false)
            diffContent = try await client.git.diff(requested).patch ?? ""
            // diff 为空时再看工作区：未跟踪改动也算待审查内容，但不一定出现在 diff 里。
            if diffContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dirtyPathCount = try await client.git.status().dirtyPathCount
                if dirtyPathCount > 0 {
                    diffContent = try await client.git.diff(GitDiffRequest(scope: .worktree, includeFileStats: false)).patch ?? ""
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Error: 无法通过 Core 读取 Git 差异：\(error)\n".utf8))
        }
        await client.disconnect()

        if diffContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dirtyPathCount == 0 {
            print("\u{2713} No uncommitted changes detected in working tree. Nothing to review.")
            return
        }

        if diffContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("\u{2713} Working tree clean. Nothing to review.")
            return
        }

        // 3. Assemble review prompt
        let prompt = """
        请对以下代码改动执行全面严谨的 Code Review：

        【审查关注点】
        1. 正确性与逻辑：边界条件处理、空值处理、并发与竞态、资源释放。
        2. 安全性隐患：凭据泄露风险、未经验证的外部输入、权限越界。
        3. 架构与性能：不必要的复杂度、重复代码、潜在性能瓶颈。
        4. 测试覆盖：改动是否具备对应的单元测试或验证逻辑。

        【输出格式】
        - 📋 变更概述
        - 🚨 关键问题（若有，标注文件名与修复代码片段）
        - 💡 优化建议（可读性、优雅度与防御性编码）
        - ⭐️ 最终结论（Approved / Approved with suggestions / Changes requested）

        ```diff
        \(diffContent)
        ```
        """

        var execArgs: [String] = ["exec"]
        if isYolo { execArgs.append("--yolo") }
        if let modelID { execArgs += ["--model", modelID] }
        if let effortStr { execArgs += ["--effort", effortStr] }
        execArgs.append(prompt)

        try await ExecCLI.run(arguments: execArgs)
    }

    private static func hasGitParent() -> Bool {
        var current = URL(fileURLWithPath: LingXiPlatform.process.currentWorkingDirectory())
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return false
    }


    public static func renderHelp() -> String {
        """
        Run Non-Interactive Automated Code Review:

        USAGE:
          lingxiagent review [options]

        OPTIONS:
          --base <branch>             与指定基线分支对比 (如 main, origin/main)
          --commit <hash>             审查指定 commit 的代码变动
          -m, --model <id>            指定执行审查的模型
          -e, --effort <effort>       推理深度 (auto | low | medium | high | max)
          -h, --help                  显示此帮助信息

        EXAMPLES:
          lingxiagent review                          审查当前工作区未提交的全部改动
          lingxiagent review --base main              审查当前分支相对于 main 分支的改动
          lingxiagent review -m gpt-5-5 --effort max  使用深度推理模型进行严谨代码审查
        """
    }
}
