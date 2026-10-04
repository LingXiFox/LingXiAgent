# 产品版本单一来源 ruling — 2026-10-01

状态：**已采纳并落地**（主人指令：「改成一处版本号，所有地方都引用这个版本号变量」）。

## 问题

`lingxiagent --version` 打印 `1.0.0 / Stable`，而 GitHub 最新正式 release 是 `v1.1.0`。
排查后发现不是某个常量忘了改，而是**根本没有版本注入机制**：

```text
git tag v1.1.0 ──► .github/workflows/release.yml:230-244  只拿 tag 当 Release 的名字
swift build      ──► 不带任何版本参数，二进制里编译进去的是源码常量
```

而"产品版本"这个事实散落在 7 处独立硬编码：

| 位置 | 用途 |
|---|---|
| `Sources/LingXiTUI/CLIParser.swift:24-25` | `--version`、help 文本（三个可执行入口都读它） |
| `Sources/LingXiCore/App/CoreHost.swift:71` | `coreVersion`：**扩展准入比较的输入** |
| `Sources/LingXiProtocol/ACPProtocol.swift:111` | ACP agent 身份默认值 |
| `Sources/LingXiProtocol/RuntimeEvents.swift:91` | Core 实例自报版本 |
| `Sources/LingXiCore/Modules/ACP/LingXiACPServer.swift:51` | ACP initialize 回包 |
| `ClientFingerprint.swift:126` / `OpenAICompatibleProvider.swift:122` / `ProviderConnectivityProbe.swift:42` / `ModelDiscoveryAdapters.swift:378` | 出站 `User-Agent` |
| `Sidecars/browser-host/package.json`、`Scripts/bundle-mac-app.sh:67` | Sidecar 与 macOS bundle 版本 |

后果不止"显示不准"：`ExtensionCompatibility.supports(coreVersion:)`
（`ExtensionPlatform.swift:28-38`）拿 `CoreHost.coreVersion` 与扩展声明的
`minimumCoreVersion` 比较，所以任何 `minimumCoreVersion: 1.1.0` 的插件 / 技能 /
自定义命令在 **v1.1.0 的真实构建上会被判 incompatible 而拒载**。

原有防护抓不到：测试全部引用符号（`CoreClientTests.swift:19`、
`RuntimeDiagnosticsTests.swift:48`、`PublicSDKIntegrationTests.swift:157`、
`VCRTypes.swift:33` 等），常量内部自我一致但对外不一致永远不会红；workflow 只把
`lingxiagent --version` 打进日志（`ci.yml:111-112`、`release.yml:194`），没有比对。

## 决定

1. **单一真源**：`Sources/LingXiProtocol/ProductVersion.swift` 的
   `ProductVersion.current`（放在最底层的 Protocol 模块，Core / TUI / GUI / ops 都能引用）。
   同处提供 `releaseName`、`short`、`userAgent` 派生值。
2. **所有消费者引用它**，不再各写一份：`CLIParser.version` / `releaseName`、
   `CoreHost.coreVersion`、ACP 两处、RuntimeEvents 默认值、四处 UA、macOS bundle
   （`bundle-mac-app.sh` 在打包时从常量文件读出并注入 `Info.plist`）。
3. **一致性由判据保证**，不靠人记：
   - `Scripts/version-consistency-check.sh`：引用点必须引用常量、不许出现
     `LingXiAgent/<digit>` 字面量、Sidecar 与首页 release fallback 必须等于常量、
     **已发布 tag 不允许领先常量**（落后 = FAIL，领先 = 发布前正常 warn）。
   - `Tests/LingXiAgentTests/ProductVersionGateTests.swift`（8 项）：同样的不变量，
     跑在常规测试里；期望值从常量推导，所以 bump 版本不需要改测试。
4. **发版流程**：打 tag 之前先把 `ProductVersion.current` 改成同一个值；两处一起改，
   就是主人说的「设置 tag + 这个全局版本号」。

## 明确不合并的版本轴

这些和发版 tag 不同步是**正确的**，禁止为了"统一"把它们塞进 `ProductVersion`：

| 轴 | 位置 | 理由 |
|---|---|---|
| 前端 wire 契约 | `ProtocolVersion.current` = 1.1、`FrontendWire.protocolVersion` = "2.0" | 协议兼容性按契约演进，与发版号无关 |
| 插件 IPC 契约 | `PluginIPC.currentVersion`（在 LingXiPluginSDK 仓库） | 跨仓库协商，见握手版本判定 |
| 数据契约 | `models.json` 的 `schemaVersion`（≠ `catalogRevision`）、四个配置文档的 `version: 1` | 数据形状版本，由发布管线负责 |
| 外部规范日期 | `MCPSpecRevision` / `ACPSpecRevision` = "2024-11-05" | 别人的版本号 |
| 扩展自身版本 | `ExtensionPlatform.swift:75/528`、`CoreHost.swift:1344/5241/5296/5329` 的 `"1.0.0"` 占位 | 那是**某个扩展**没声明版本时的占位，不是产品版本；已在代码里逐处注释标明 |

## 行为影响（不只是显示）

`CoreHost.coreVersion` 从 `1.0.0` 变成 `1.1.0` 会改变扩展准入判定：

- **解锁**：声明 `minimumCoreVersion: 1.1.0` 的插件 / 技能 / 自定义命令，此前在 v1.1.0
  构建上被错误判为 incompatible，现在能正常加载。
- **收紧**：声明 `maximumCoreVersion` 低于 `1.1.0` 的扩展会开始被拒——这是正确行为
  （它在契约上就只承诺旧宿主），但如果有扩展把上界写得过窄，升级后会消失。
  仓库内当前只有一处兼容性 fixture（`ExtensionPlatformTests.swift:47` 用 `99.0.0`），
  不受影响。
- 出站 `User-Agent` 的产品标记由 `LingXiAgent/1.0`、`LingXiAgent/2.0` 统一成
  `LingXiAgent/1.1`。若某个上游按 UA 版本串做灰度，可能观察到行为差异——这是把
  三个互相矛盾的版本收敛成一个的必然结果，不是回归。

## 验证

```text
swift build                                                     ✓ Build complete
swift test --filter ProductVersionGateTests                      ✓ 8/8
bash Scripts/version-consistency-check.sh                        ✓ 20 项全 ok，exit 0
负例：把 current 改成 1.0.9                                      ✓ 脚本 exit 1（Sidecar、首页
                                                                fallback、tag 领先三项 FAIL）
                                                                ✓ gate 测试同样失败（3 issues）
```

顺带把同样已经作废的 README 发布口径一起修正并纳入脚本判据：Windows 不再是「实验性 / V1.0.0 无发布包」
（v1.1.0 已发布 `lingxiagent-windows-x86_64.zip`），13 处 `lingxiagent <ops 动词>` 示例改为
`lingxiagent-ops …`，文档链接统一 `/docs.html`。

## 尚未处理的 README 债务（另案）

README 里仍有整段旧架构与不可复现数字，和本轮修正后的官网互相矛盾：

| 行 | 内容 | 问题 |
|---|---|---|
| 75 | 冷启动 ~10ms、内存 ~35MB | 无复现 benchmark |
| 82 | 动态宿主感知与**反封锁伪装** | 绝对化宣传 |
| 87 | 无缝兼容 **75+** 模型 | 硬编码计数，目录已统一由 Models Hub 发布 |
| 136 / 238 / 249 | 60FPS、P/E-Core context水位 | 未实测数字 + 旧架构 |
| 156 / 212-228 | `ContextCompactor`、PCore Hot / RecallCache Warm / ProjectIndex Cold 与 mermaid 图 | 已废弃架构，官网已按 P/E 重写 |
| 370 | Frontend「允许自由分发二次上架」 | 与 `LICENSE-MATRIX.md` 的 binary: no 口径不一致（许可文本，需主人定夺） |

建议下一步单独一轮：把 README 的架构与能力段落按官网同一套判据重写，并把
`AgentSiteContentGateTests` 的陈旧词扫描扩展到 README（届时才可开全量 needle 集）。

## 遗留

- `ModelDiscoveryAdapters.swift:378` 的 UA 里仍写着 `(macOS; discovery)`、
  `GeminiNativeProvider` 等处若存在硬编码平台字段：那是**平台**声明而非版本，
  与 `ClientFingerprint.currentPlatform()` 的宿主感知原则相悖，本轮未动，另案处理。
- 本轮把常量对齐到 `1.1.0`（与已发布 tag 一致）。下次发版若跳到 1.2.0，需按流程先改常量再打 tag。
