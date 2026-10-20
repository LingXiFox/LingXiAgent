# Phase 2.1 验收记录：产品接线、安全边界与 Provider 前置

> **状态：已验收（待合并与 CI run 记录）** —— 分支 `wip/phase2.1-host-wiring`，120 tests 全绿（104 内核 + 16 契约），`swift build --build-tests` 零告警。范围与阶段记账见 `Decisions/ADR-0002`。

## 一、交付

| 项 | 落点 |
|---|---|
| CoreHost 正式接线 | `Sources/LingXiCoreHost/main.swift`：读 `plugins.json` → 恢复 enabled 插件 → 同一个 `HookPipeline` 交给真实 `AgentLoop` → 退出时 `coordinator.shutdown()`（停进程，**不改注册表**） |
| 默认策略 | `PluginCoordinator.enable(policy: = .restricted)`；CoreHost 仅在 `LINGXI_PLUGIN_POLICY=development` 时放行 ad-hoc，并在输出中标注“untrusted” |
| PLG-008 | Host 环境只保留 `PATH/HOME/TMPDIR/LANG`；Host 新增 `diagnostics`（只返回环境变量名，不返回值）供 tripwire 验证 |
| PLG-019 | Mach-O `LC_LOAD_DYLIB` 解析：Swift 插件动态链接 `libswiftCore.dylib`、包内无副本；C 插件不链接 Swift 运行时 |
| 在途取消 | ABI invoke 增加 `requestID`、状态码增加 `LX_CANCELLED`；Host 读循环与插件调用分离（每插件串行队列），`cancel` 由读循环直转插件；客户端超时/取消会通知 Host 在途停止 |
| 背压 | 通知队列有界（256，丢最旧）；IPC 帧上限 32MB；stderr 环 256KB |

## 二、证据（新增 5 条，共 16 条契约测试）

| 验收要求 | 用例 |
|---|---|
| CoreHost 恢复插件并在重启后仍运行 | `PLG_001_coreHostRestoresPluginAcrossRestart`（同一数据目录连跑两次 + 默认受限第三次） |
| 默认策略不静默降级 | 同上第三段：`plugin policy: restricted`、`0 running`、出现 `plugin error:` |
| 敏感环境变量不泄漏 | `PLG_008_environmentSentinelDoesNotLeak`（`LINGXI_TEST_API_KEY` 与所有 `*_API_KEY` 不出现；PATH/HOME 保留） |
| 无内嵌 Swift 运行时 | `PLG_019_swiftRuntimeIsNotEmbedded` |
| 在途取消及时生效、Host 不被阻塞 | `LOOP_023_inFlightCancellation`（慢调用 2s，取消 < 1.2s；期间 ping 成功） |
| 超时不留悬挂执行与进程 | `LOOP_023_timeoutCancelsInHost`（200ms 超时后 ping 正常，退出后 PID 消失） |
| 崩溃隔离（回归） | `PLG_018_pluginCrashIsIsolated` |
| 另一份兼容插件无需改 Core | `PLG_015_cPluginUsesTheSameRuntimeAndABI` |

## 三、ABI-MANIFEST

revision 2，头文件 SHA-256 `4ea407f612b471bf4b4f30218ab373c08ba4e6641d544294cdc98bf52a0c7c74`。在 invoke 增加 requestID、状态码增加 `LX_CANCELLED` 后，**待取消测试通过后才重冻**。

## 四、残余风险

1. **流式事件传输尚未打通到 Provider 端口**：Host 已有 `emit` 通知与有界队列，但 `ModelProvider.stream` 的适配器（provider 插件能力）留到第一个真实 Provider 插件一起实现。本阶段没有假装它已完成。
2. **并发模型**：同一个插件的调用串行执行；跨插件并行。Provider 流式请求将是「一次调用 + 多帧事件」，需要在适配器里决定是否允许同一插件并发两个 stream（计划：每个 Run 一个 RequestID，Host 侧允许并发流，插件表再加 `startStream`/`poll` 会在 Provider 插件阶段评估）。
3. **签名正向路径**：本机没有 Developer ID，`restricted` 的放行分支只有逻辑覆盖，没有真实证书验证；`permissive` 与公证仍未实现（PLG-017 保持「进行中」）。
4. **超时后的插件计算**：客户端超时立即发 cancel；若插件不实现 cancel，Host 会在其返回后才释放该调用，但**不会**阻塞读循环或其他调用。这是契约要求（`cancel` 必须能中断长任务），不实现 cancel 的插件会在 Provider 阶段被拒。
5. **租约/熔断**（PLG-003/005）仍未建，与本阶段无关。

## 五、复现

```bash
swift build --build-tests && swift test          # 104 + 16 = 120
shasum -a 256 Sources/LingXiPluginABIC/include/lingxi_plugin_abi.h
# 4ea407f612b471bf4b4f30218ab373c08ba4e6641d544294cdc98bf52a0c7c74
```
