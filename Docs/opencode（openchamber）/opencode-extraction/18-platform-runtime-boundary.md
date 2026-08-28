# Platform Runtime Boundary

Filesystem、Git、shell、PTY、LSP 是 runtime 依赖或 tool executor，不是 Session domain state。

| 能力 | 分类 | 接入点 |
| --- | --- | --- |
| FS path/read/write/edit/patch | Tool runtime + FS adapter | Tool modules / `FSUtil` |
| shell/process/abort/output truncation | Tool runtime + platform adapter | Shell tool / ChildProcessSpawner |
| git diff/status/context | platform service，部分 Session summary | `Git`, `Vcs`, snapshot/revert |
| PTY | server transport/platform service | typed PTY route + ticket auth |
| LSP | tool-exposed platform service | `LSP` + optional LspTool |

`ToolRegistry.node` 依赖 `FSUtil`、CrossSpawnSpawner、Ripgrep、LSP、Database 等（427-452），显示这些适配器可在同一工具运行时组合，但它不使其成为 agent orchestration 的所有者。路径与 permission 的安全策略见 23。
