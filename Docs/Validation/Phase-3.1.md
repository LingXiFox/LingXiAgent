# Phase 3.1 验收记录：多 Provider 隔离与动态撤销

> **状态：已验收** —— 137 tests 全绿（104 内核 + 33 契约），`swift build --build-tests` 零告警，CI 记录见第六节。

## 一、修复内容

| 问题 | 修复 |
|---|---|
| `ModelRouter` 只增不减 | 新增原子 `register`（重复 provider / 模型冲突整批拒绝）与 `unregister(providerID:)`（只删该所有者的路由、返回被移除的模型），见 ADR-0004 |
| `disable` 不撤销 Provider 路由 | 协调器持有 router：启用注册、禁用撤销；启用任一步失败整体回滚（路由、Hook、Host、注册表内存态） |
| 撤销顺序与在途请求 | 注册表先写 → 摘路由 → `cancelAll` 取消在途 → 卸 Hook → 停 Host；在途 Run 以 `failed / providerFailure` 收敛 |
| Host 崩溃留下失效路由 | `terminationHandler` 单次回调 → 协调器按插件作用域清理路由/Hook，注册表置 `enabled=false`，不影响其他插件 |
| 注册表写入失败 | `upsert/remove` 先落盘再提交内存；禁用写盘失败则整个禁用不发生；启用写盘失败则回滚已装内容 |
| 常驻 Core 无法验证运行时切换 | `LINGXI_CORE_CONTROL=1` 行式控制面：`models` / `plugins` / `enable <id>` / `disable <id>` / `quit`；stdout 无缓冲；不写会话日志 |

## 二、逐项证据（新增 7 条 + 2 条加固）

| 要求 | 用例 |
|---|---|
| 1–2 双 Provider 同时加载，各自经所属 Host 完成请求 | `PLG_001_twoProvidersServeIndependently` |
| 3–5 禁用 MiMo → 路由消失、DeepSeek 路由与 PID 不变、继续完成新 Run | `PLG_002_disableRevokesOnlyOwnedRoutes` |
| 6 不重启 Core 重新启用 MiMo 后恢复可用 | `PLG_002_disableRevokesOnlyOwnedRoutes`（进程内）+ `PLG_001_residentCoreRuntimeSwitching`（常驻 Core 路由恢复） |
| 7 强杀 MiMo Host：路由清理、其他插件与 Core 不受影响 | `PLG_018_forceKilledProviderIsScoped` |
| 8 Core 重启恢复用户启停状态 | `PLG_001_residentCoreRuntimeSwitching`（禁用 MiMo → quit → 重启：MiMo stopped、DeepSeek running） |
| 9 in-flight 期间禁用：无幽灵路由、无迟到污染、无残留进程 | `LOOP_023_disableDuringInFlightProviderRequest`（等 `inFlightRequestCount > 0` 后禁用；旧 Run failed；新 MiMo Run 被拒；重启用后输出干净） |
| 重复模型/Provider | `PLG_011_registrationConflicts` |
| 注册表写入失败回滚 | `STORE_010_registryWriteFailureRollsBackEnable`（目录只读 → enable 报错、无路由、无进程、内存态未变） |
| 原 MiMo 撤销测试补齐 | `MIMO_disableRemovesProviderRoute` 现断言 `offeredModels` 为空、`resolve` 失败、PID 退出 |
| 崩溃清理断言更新 | `PLG_018_pluginCrashIsIsolated` 现断言死插件的 Hook 路由被自动清除，存活插件不受影响 |

常驻 Core 测试同时断言：控制命令与插件启动**不写** `events.jsonl`；退出后两个 Host PID 均消失。

## 三、计数与稳定性

- 内核 104；契约 33（原 26 + 6 隔离 + 1 常驻 Core）。
- 全套 **137 tests 连跑 3 次全绿**；构建零告警。
- 期间修复常驻 Core 的真实缺陷：stdout 接管道时块缓冲导致父进程读不到状态与 `control: ready`（改为无缓冲）。

## 四、残余风险

1. **崩溃后需手动重新启用**：注册表置 `enabled=false`，避免自动复活；熔断与退避不在本阶段（PLG-005）。
2. **禁用依赖注册表可写**：不可写时禁用整体失败、保持原状（明确报错，不部分生效）。
3. **在途请求的收敛是失败**：禁用会取消在途 provider 请求，Run 以 `failed / providerFailure` 结束；是否应报 `cancelled` 属产品语义，留待有前端交互时决定。
4. **重启只恢复启停选择**，不会自动重试崩溃插件的加载；若 bundle 被删除，Core 启动会记录 `plugin error` 并继续。
5. **租约、事件流卸载、前端 unregister** 仍未建（PLG-002 保持「进行中」）。
6. **控制面是测试用最小接口**，不是前端协议；TUI 阶段会替换。

## 五、复现

```bash
swift build --build-tests && swift test    # 104 + 33 = 137
# 常驻 Core 手工验证：
LINGXI_DATA_DIR=<dir> LINGXI_CORE_CONTROL=1 LINGXI_PLUGIN_POLICY=development .build/debug/LingXiCoreHost
# 依次输入 models / disable site.lingxi.provider.mimo / models / enable ... / quit
```

## 六、CI 记录

待本轮 push 后回填。
