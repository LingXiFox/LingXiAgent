# Phase 2 验收记录：最小动态插件闭环

> **状态：已验收（待合并与 CI run 记录）** —— 分支 `wip/phase2-plugin-host`，114 tests 全绿（104 内核 + 10 契约），`swift build --build-tests` 零告警。范围记账见 `Decisions/ADR-0002`，许可轨道见 `ADR-0001`，注册表存储见 `ADR-0003`。

## 一、交付面

| 能力 | 落点 |
|---|---|
| 固定 C ABI（v1，冻结） | `Sources/LingXiPluginABIC`（头文件 + `ABI-MANIFEST.txt`），Swift 侧 `Sources/LingXiPluginABI`（线协议与钩子载荷） |
| 通用 Plugin Host（每插件一进程） | `Sources/LingXiPluginHost`：验包 → 签名/Team 策略 → manifest（无默认值）→ `dlopen` → `LingXiPlugin_Init` → ABI 协商 → 单管双向 JSON |
| Core 侧监管 | `Sources/LingXiPluginRuntime`：`PluginRegistry`（独立 `plugins.json`）、`PluginSession`（启停/调用/超时）、`PluginHookBridge`（内核 Hook 端口）、`PluginCoordinator`（启用/禁用/卸载编排） |
| 实验插件 | `Plugins/LingXiContextProbe`（Swift）与 `Plugins/LingXiCProbe`（C），各声明一个 `contextPrepare` Hook，真实追加一条非特权文本条目 |

## 二、证据（10 条契约测试，`ContractTests`）

| 要求 | 用例 |
|---|---|
| 启用生效 / 禁用不再参与 / 重启用 / 卸载零残留 | `PLG_001_enableRewriteDisableReenableUninstall` |
| 注册表独立持久化 | `PLG_001_registryPersistsAsSeparateConfig` |
| C 与 Swift 插件共用同一运行时与 ABI | `PLG_015_cPluginUsesTheSameRuntimeAndABI` |
| 结构体尺寸/偏移冻结 | `PLG_015_boundaryStructLayoutIsPinned` |
| manifest 与函数表 ABI 主版本不一致拒载 | `PLG_011_manifestAbiMajorMismatchIsRefused` |
| 缺 `Permissions` 声明拒载 | `PLG_009_missingPermissionDeclarationFailsTheLoad` |
| 签名策略分级 | `PLG_017_signaturePolicyTiers` |
| 崩溃隔离与拒绝语义 | `PLG_018_pluginCrashIsIsolated` |
| 活管道请求/响应（不等 EOF） | `IPC_001_livePipeRoundTrip` |
| 线上帧往返 | `PLG_012_loadFrameRoundTrips` |

崩溃隔离实测：C 插件在 Hook 调用中 `abort()`，仅其 Host 进程死亡；Swift 插件的 Host 继续运行且路由保留；
受影响 Run 为 `failed / hookDenied`，provider 请求数为 0；随后该 Session 的新 Turn 正常完成。

## 三、ABI 冻结

`Sources/LingXiPluginABIC/ABI-MANIFEST.txt`，在下列测试全部通过后写入：
尺寸 `LingXiStatus=12`、`LingXiPluginAPI=64`、`LingXiHostAPI=24`；主版本 1；
头文件 SHA-256 `648171026f5ad8bd54180951fff122d0deef0174c1c233f5e0a0af4ffbbcf5f6`。
状态结构体为纯标量并走出参，调用一律返回 `int32_t`；缓冲由被调方分配、调用方经函数表的 `free` 释放。

## 四、不修改 / 不重编 Core 的证明

同一份 `LingXiPluginHost` 与同一份 `LingXiPluginRuntime` 在同一次测试运行中加载了 Swift 与 C 两个插件；
两者的 `bundleID`、`.lxap` 路径与实现语言都不同，内核代码零改动。内核仍由 L0 门禁保证不含 `dlopen`、
`dlsym`、`@_cdecl` 与任何厂商名。**没有**任何插件 ID 出现在 `Sources/LingXiKernel` 或 `Sources/LingXiCoreHost`。

## 五、残余风险

1. **未实现**：租约状态机（PLG-003）、熔断与指数退避（PLG-005）、`permissive` 档与公证、`security` 类 Hook 的人工确认（ADR-0002）、插件工具能力（PLG-007）、Swift 运行时唯一性检测（PLG-019）、in-flight 请求的取消传播（cancel 方法目前为占位）。
2. **内存所有权**：每次调用都经函数表的 `free` 释放回复与 identity 缓冲，双释放会在测试中崩溃；但**泄漏**未被度量。
3. **并发**：单个 Host 一次只处理一个请求（请求-响应严格串行），尚未实现单管多路事件流；多路复用排在阶段 3。
4. **签名**：ad-hoc 只在 development 档放行；本机没有 Developer ID，故 `restricted` 的正向路径用“同 Team 拒绝/放行”逻辑覆盖，未用真实签名证书验证。
5. **CI**：本分支尚未推送；合并到 `rewrite/2.0` 后跑 `macos-26` 门禁并回填。

## 六、复现

```bash
git checkout wip/phase2-plugin-host
swift build --build-tests
swift test                       # 期望 104 + 10 = 114 passed
shasum -a 256 Sources/LingXiPluginABIC/include/lingxi_plugin_abi.h
# 期望 648171026f5ad8bd54180951fff122d0deef0174c1c233f5e0a0af4ffbbcf5f6
```
