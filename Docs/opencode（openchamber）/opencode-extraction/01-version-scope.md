# 版本与范围

## Research HEAD

- Repository: `/Volumes/Development/Projects/projects/opencode-source`
- Ref: `dev` / `origin/dev`
- Commit: `755ebdb94ee755a9d5691e47af2c16f56696996e`
- Describe: `github-v1.2.25-1875-g755ebdb94e`
- Subject: `sync release versions for v1.18.25`

## OpenChamber-compatible version

- LingXiFox root、UI 与 VS Code package pin `@opencode-ai/sdk: 1.18.21`。
- `bun.lock` resolves `@opencode-ai/sdk@1.18.21`.
- Electron `prepare-opencode-cli.mjs:143-159` defaults the bundled OpenCode CLI to that exact SDK version and downloads release `v1.18.21`.
- Upstream tag: `v1.18.21`, commit `826d9ad46a22bef0294998e08daa3c4904fea28f`.

## Version relationship

两条历史的 merge-base 是 `57fa34f23599f65dd1027f9caac31e6c576ce644`；`v1.18.21...HEAD` 的独有提交计数为 tag 侧 1、HEAD 侧 94。对 `packages/opencode/src` 的三点 diff 为 11 个文件、787 additions、75 deletions。因此本报告以当前 HEAD 为源码事实，同时不能称其为 OpenChamber 打包 CLI 的逐行实现。

## Known mismatch

- 已用 Git object ID 直接核对：`packages/core/src/session/runner/llm.ts`、`packages/core/src/session.ts`、`packages/server/src/handlers/session.ts` 在 `v1.18.21` 与 Research HEAD 相同；`packages/core/src/session`、`packages/server/src/handlers/session.ts`、`packages/protocol/src/groups/session.ts`、`packages/core/src/system-context` 的 tag diff 为空。因此本报告最核心的 V2 turn/context/HTTP 链可视为与 OpenChamber pin 一致。
- 其余 Provider、MCP、tool、plugin 和 legacy V1 模块未做逐 blob release audit；相关结论仍以 Research HEAD 为准并保留版本风险。
- 未 checkout、未修改 refs。

## 排除范围

未启动 server、未调用模型、未读取任何生产数据库、未构建或安装依赖；仅创建本目录 Markdown。
