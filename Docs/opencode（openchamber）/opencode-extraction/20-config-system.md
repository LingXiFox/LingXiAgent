# Config System

`Config.loadInstanceState` 按 directory/worktree 创建 cached InstanceState。读取/merge 次序包括 well-known remote config、global config、`OPENCODE_CONFIG`、向上发现的 project `opencode.{json,jsonc}`、`.opencode` directories、environment content、account/org config、managed config/preference 与 permission env override（`config/config.ts:328-610`）。deep merge，`instructions` 特殊去重拼接。

`ConfigPaths.files` 从当前 directory 向 worktree 向上查找并 reverse，`directories` 枚举 global 与 `.opencode` roots（`config/paths.ts:10-41`）。agent/command/plugin 会在这些 dirs 自动发现；`Config` 还可能后台安装 plugin dependency，但本研究未触发该路径。

缓存：global config 用 infinite TTL cache；instance config 由 `InstanceState` 持有。`invalidate()` 只 invalidates global cache；是否/何时 dispose/recreate directory instance 才影响正在运行 Session，静态证据不足，标记 `NEEDS VERIFICATION`。配置写入 API 不等于正在执行的 runner 动态重载。
