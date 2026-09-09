import Foundation

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

        // 2. Extract git diff
        let diffArgs: [String]
        if let commit {
            diffArgs = ["diff", "\(commit)^!"]
        } else if let base = baseBranch {
            diffArgs = ["diff", "\(base)...HEAD"]
        } else {
            diffArgs = ["diff", "HEAD"]
        }

        var diffContent = runProcess("/usr/bin/git", arguments: diffArgs) ?? ""

        // If git diff HEAD is empty, check unstaged or untracked changes
        if diffContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let status = runProcess("/usr/bin/git", arguments: ["status", "-s"]) ?? ""
            if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("✓ No uncommitted changes detected in working tree. Nothing to review.")
                return
            }
            // Try regular git diff
            diffContent = runProcess("/usr/bin/git", arguments: ["diff"]) ?? ""
        }

        if diffContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("✓ Working tree clean. Nothing to review.")
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
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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

    private static func runProcess(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
