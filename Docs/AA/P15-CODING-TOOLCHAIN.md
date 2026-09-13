# P15 Coding Toolchain

## 状态

P15 READY。Provider-facing tool result 使用 `ModelToolResultProjection`，将内部 `ToolResult` 与 provider wire 明确分离；MCP fixture 与 VCR child-run canonicalization 均已通过并行稳定性验证。

## 工具能力

| 能力 | 实现 |
| --- | --- |
| read | UTF-8/binary guard、workspace 与 sensitive path guard、可选行范围分页、版本信息 |
| glob/grep | 受控 `rg`、`.gitignore`、敏感/生成目录策略、workspace-relative deterministic path |
| edit/write | 精确匹配、stale hash/version guard、atomic write、统一 edit 权限 |
| apply_patch | Add/Update/Delete/Move、hunk precondition、snapshot rollback、changed files internal result |
| shell/process | explicit cwd、sanitized env、stdout/stderr、exit status、timeout/cancel、background poll/input/terminate |
| git | 既有 allow-listed structured Git，staged diff 可使用受控 shell `git diff --cached` |

## Result Boundary

`ToolResult` 是 Core、Persistence、Context 与 Diagnostics 使用的 rich internal result，保留 `exitCode`、`diagnostics`、`changedFiles`、`continuation`、output truncation/archive metadata。

`ModelToolResultProjection.project(_:)` 是唯一的模型可见投影：`callID`、`toolName`、`success`、稳定 content。OpenAI Chat、OpenAI Responses 与 Anthropic adapter 均在 wire encode 前调用它；没有 Provider adapter 直接 JSON encode `ToolResult`。

Projection 不输出内部 archive reference、absolute path、diagnostics、changed files、empty/nil metadata。失败结果保持 P14 的 `ToolError` JSON 文本表示。ToolCallID 一直保持 domain canonical；adapter 只使用既有 `ProviderContinuation` 做 external call ID 映射。

## Sandbox

macOS 13+ workspace shell 在 `/usr/bin/sandbox-exec` 存在时使用 OS-enforced workspace filesystem policy，network deny，且 backend 不可用或请求 host allow-list 时 fail closed。该 backend 不提供强 process namespace/resource isolation；`processIsolationEnforced` 明确为 false。非 macOS 或无 `sandbox-exec` 环境不能声称已 sandboxed，workspace shell 返回 `sandboxUnavailable` 并交由权限策略处理。

## Deferred

- P16：Agent behavior、prompt、workflow
- P17：LSP/code intelligence
- GUI、remote runtime、provider contract v2
