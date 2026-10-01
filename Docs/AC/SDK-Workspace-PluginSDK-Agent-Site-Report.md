# SDK Workspace + LingXiPluginSDK + 官方网站收尾 — 执行报告

契约来源：主人 2026-10-01 三段式冻结指令（`LingXiModelSDK 独立仓库迁移` §1–§38、
`Dogfood 补充冻结` §1–§11、`SDK Workspace + PluginSDK + 官网收尾` §1–§82）。
本报告按 §82 的 A–S 顺序逐项给证据；判据在 §79/§81，结论在文末。

本轮范围：**仓库源码 + 本地验证**。生产站点未部署（§80），远程 CI 保持关闭（§81）。

---

## A. SDK workspace 目录树

```text
LingXiAgent/                      git: github.com/LingXiFox/LingXiAgent
├── Package.swift                 只用远程 .package(url:, from:) 引用两个 SDK
├── Sources/                      无任何 SDK 源码副本
├── Plugins/FoxPlugin/            第一方参考插件（消费公共 product）
└── SDKs/                         本地联合开发工作区
    ├── README.md                 ← 主仓库唯一跟踪的文件
    ├── LingXiModelSDK/           ← 独立 repo，被 .gitignore 忽略
    └── LingXiPluginSDK/          ← 独立 repo，被 .gitignore 忽略
```

三个彼此独立的 Git repository，不是 submodule / subtree vendor / monorepo（契约 §1）。
边界由机器验证，不靠人自觉：

```text
$ git check-ignore -v SDKs/LingXiModelSDK SDKs/LingXiPluginSDK
.gitignore:31:/SDKs/LingXiModelSDK/
.gitignore:32:/SDKs/LingXiPluginSDK/

$ git ls-files SDKs
SDKs/README.md
```

`git status` 在主仓库永远看不到两个 SDK 的内部文件，因此 §77/§78 的「根目录 `git add -A`
误吞 SDK」不成立；每个 SDK 的 commit 必须在各自目录内执行。

## B. LingXiModelSDK 仓库与发布

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/LingXiFox/LingXiModelSDK （Public） |
| `main` HEAD | `0bf83adad12bb83bf5af8f8dceb2840989af2eef` |
| tag | `0.1.0`（同名 GitHub Release 已发布） |
| 迁移方式 | `git subtree split --prefix Sources/LingXiModelSDK` + 无关历史 merge 带入测试历史 |
| 许可证 | MIT（`Copyright (c) 2026 LingXiFox`），显式允许商业使用、闭源产品链接、源码/二进制再分发 |

## C. LingXiPluginSDK 仓库与发布

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/LingXiFox/LingXiPluginSDK （Public） |
| `main` HEAD | `67bb88cceb37833937e2041f4dfe80cc7edd4bb6` |
| tag | `0.1.0`（同名 GitHub Release 已发布） |
| 迁移方式 | 同 ModelSDK：subtree split 保留源码历史，测试历史以 merge commit 带入，未丢失任何测试 |
| 许可证 | MIT |

## D. PluginSDK 依赖闭包（契约 §8）

```text
Sources/LingXiPluginSDK 的 import 统计：
   9 Foundation
Tests 的 import 统计：
   3 Foundation · 3 Testing
```

`import LingXiProtocol` 已删除，`Package.swift` 无 package-level dependency，target 无
dependency。闭包为 **Foundation / Swift 标准库 only**，不依赖 Protocol / Core / Platform /
Client / Application / GUI。ModelSDK 同理（`Foundation` + 非 Darwin 平台的
`FoundationNetworking` 条件导入）。

## E. PluginSDK 许可

`SDKs/LingXiPluginSDK/LICENSE` = MIT 全文；README 与 `sdk.html` 均写明商业使用、
闭源插件、修改与源码/二进制再分发都允许，唯一义务是保留版权与许可声明。
主仓库 `LICENSE-MATRIX.md` 不再列两个 SDK；`LICENSE-SDK` 已删除，root `LICENSE`
对它的 scope 引用一并清除（§73）。

## F. PluginSDK 公共 API 变化（§11–§18、§64–§67）

| 变化 | 语义 |
|---|---|
| `PluginRuntimeSnapshot` 新增 | Core → 插件的权威只读投影：`observedAt` · `ipcVersion` · 四个可空段落 |
| DTO 全字段 optional 化 | `PluginContextStateInfo` / `PluginPECoreInfo` / `PluginPerformanceInfo` 字段可为 nil；`PluginWorkspaceInfo` 保留必然已知的 rootPath / isGitRepository / coreVersion |
| `PluginPECoreInfo` 重写 | 由旧的 `pCoreRole` / `eCoreRole` / `cacheDebt` / `pCoreToECoreTimeRatio` 改为 `pCoreTokens` / `eCoreObjects` / `eCoreReferences` / `lastEvictionTrigger` / `reasoningEffort` / `backgroundTaskCount`，与冻结 P/E 语义一致 |
| `PluginInfoUnavailable` 新增 | typed error：`field` + `lastObservedAt`，替代 `idle` / `unknown` / `0` 假数据 |
| `PluginInfoField` 新增 | 四个段落的枚举，错误信息可读 |
| `PluginIPC` 新增 | `Method` 常量表 + `currentVersion` / `supportedVersions` / `isCompatible(_:)` |
| `PluginInitializeParams` 新增 | `hostIPCVersion` + `coreVersion`，握手带宿主版本 |
| `PluginHandshakeResult.ipcVersion` | 插件侧声明自己支持的协议版本 |
| `PluginManifest.minimumCoreVersion` | 明确降级为「人类可读提示」，不参与线上兼容判定 |
| `DefaultPluginInfoHub` | 不再自带默认值，只回放最近一次快照；`apply(_:)` 按 `observedAt` 单调，丢弃过期推送 |

契约 §9 要求的公共符号全部在位（34 个 public 类型，含 `LingXiPlugin`、`PluginContext`、
`PluginTool`、`PluginCommand`、`PluginHookEvent`、`PluginDriver`、五个 IPC DTO 等）。
Core 实现、`PermissionEngine`、`SessionStore`、P/E 实现、Provider runtime 未进 SDK。

## G. 权威快照链路（§12–§17）

```text
CoreHost
  └─ CoreHost+PluginSnapshot.swift   ← 唯一的快照装配点，只读真实 Core 状态
        workspace  ← getWorkspaceSummary()
        contextState ← sessionStore.session(id).messages.count、activeModelID、token 水位
        peCore     ← eCoreStore 对象/引用计数、session.reasoningEffort、
                    await backgroundManagerRef.runningTasksCount
        performance ← 不伪造：Core 未发布该段就留 nil
  └─ PluginProcessHost.pushSnapshot() → host.snapshot → PluginDriver.apply(_:)
```

顺序冻结为 `spawn → host.snapshot → plugin.initialize → activate(context:)`，因此插件在
`activate` 内读 `context.info` 也不会拿到假默认值；每次 `tool.execute` /
`command.execute` / `hook.emit` 前再刷新一次。无会话调用只推 workspace 段。
SDK 侧禁止读 Core 文件、SQLite、环境变量或扫描工作区（§17）——快照字段只可能来自宿主。

## H. Plugin IPC 版本与方法表（§19–§21、§65–§66）

方法名唯一来源是 `PluginIPC.Method`，文档不得自创：

| Method | 方向 | 参数 | 结果 |
|---|---|---|---|
| `host.snapshot` | Core → Plugin | `PluginRuntimeSnapshot` | empty |
| `plugin.initialize` | Core → Plugin | `PluginInitializeParams` | `PluginHandshakeResult` |
| `tool.execute` | Core → Plugin | `PluginToolCallParams` | `String` |
| `command.execute` | Core → Plugin | `PluginCommandCallParams` | `PluginCommandCallResult` |
| `hook.emit` | Core → Plugin | `PluginHookPayload` | empty |

`tool.call` 是旧文档虚构的名字，已在网站、README、示例与测试里全部替换。
协议正名为 **LingXi Plugin IPC / JSON Lines**：线上报文没有 `"jsonrpc": "2.0"` 字段，
也没有 batch/notification，因此不再宣称 JSON-RPC 2.0。
兼容判定走 `ipcVersion`（`PluginIPC.currentVersion = 1`，`supportedVersions = [1]`）：
握手时双方无交集即 `terminate()` + 明确错误，不会拖到某个 command 解码才炸。

契约测试：`PluginIPCContractTests` 覆盖 initialize / host.snapshot / tool.execute /
command.execute / hook.emit / 未知方法 / 畸形输入 / 缺参 / 错误响应 / EOF 关闭；
`PluginInfoHubTests` 钉住快照语义；`DocumentationExampleCompileTests` 编译文档示例
（§21、§38）。

## I. FoxPlugin 集成（§68）

`Plugins/FoxPlugin` 仍是仓库内的第一方 E2E dogfood：根 `Package.swift`
以 `.product(name: "LingXiPluginSDK", package: "LingXiPluginSDK")` 消费公共 product，
`.executableTarget(name: "FoxPlugin", path: "Plugins/FoxPlugin")`，独立 executable product。
它的 `/fox-info` 命令按段落渲染，宿主未推送的段落显示「宿主未发布」而不是 0 ——
这正是 §11 语义在真实插件里的表现。README 改为公共包消费者写法。

## J. LingXiAgent 远程依赖（§4、dogfood §2–§4、§72）

```swift
let publicSDKDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/LingXiFox/LingXiModelSDK.git", from: "0.1.0"),
    .package(url: "https://github.com/LingXiFox/LingXiPluginSDK.git", from: "0.1.0"),
]
```

`Sources/LingXiModelSDK`、`Sources/LingXiPluginSDK` 及二者的单测已删除，正式 main
无 `path:` fallback。本地联调用 `swift package edit --path`（§5、§76），不提交。

## K. sdk.html 变更（§34–§42、§64、§69、§70）

| 位置 | 之前 | 现在 |
|---|---|---|
| Quick Start 依赖块 | `LingXiAgent.git, branch: "main"` + `package: "LingXiAgent"` | `LingXiPluginSDK.git, from: "0.1.0"` + `package: "LingXiPluginSDK"` |
| 顶部 | 仅 "Framework" | Version 0.1.0 · MIT · Independent Repository + 两个 GitHub 入口 + 真实平台栏（macOS 13+，Foundation only） |
| main.swift 示例 | `PluginManifest(...)` 旧签名、`pe.pCoreRole`（已不存在的字段） | 与 SDK 仓库 `DocumentationExampleCompileTests` 同源的编译验证示例；三个 block 全部带 Copy |
| PluginInfo 文案 | 「SDK 感知高维指标」 | 明确「值来自 Core 推送的 runtime snapshot」，缺段抛 `PluginInfoUnavailable` |
| API 卡片 | `PECoreInfo` / `ContextStateInfo` 等假类型名 | `PluginPECoreInfo` 等真实类型 + 字段行；补 `CommandExecutionContext`（原先导航指向不存在的锚点）；标明 `ToolExecutionContext` 不带 info |
| IPC 章节 | 「JSON-RPC IPC 跨语言协议规范」+ `tool.call` | 「LingXi Plugin IPC · JSON Lines」+ 五方法表 + 与真实 Codable DTO 一致的报文样例 + 错误语义 |
| 安全章节 | 「四大安全防线」「无法读取任何 API Key」「越界一定被拦截」 | 分层准确表述 + 显式列出「不提供 OS 级 syscall 沙箱」 |
| 新增章节 | — | Compatibility & Versioning（§64）、Troubleshooting（§70，9 条与真实错误文案对齐） |

## L. 首页（index.html）变更（§43–§55、§60、§61）

- 版本槽位改为由 `api.github.com/repos/LingXiFox/LingXiAgent/releases/latest` 运行时填充，
  静态快照 `v1.1.0 / 2026-09-28 / 三个资产名` 仅作 fallback；「v2.0 Native」删除。
  这样页面不再需要有人记得改版本号（§44、§71）。
- 平台文案与 release 事实对齐：macOS arm64 / Linux x86_64 / Windows x86_64 均有预编译包；
  新增「预编译可用性 / 源码构建 / 能力差异」三档区分，Intel Mac 与 AArch64 Linux 走源码。
- 删除不可复现数字：`~10ms`、`35MB`、`60FPS`、`85%`；对比表把「启动耗时 & 内存消耗」
  换成「运行时依赖」，并加一行说明本项目未做跨产品 benchmark。
- Provider 文案去绝对化：`反封锁 / 反检测 / 杜绝风控 / 100% 指纹一致` 改为
  「宿主感知的请求画像」，并明确它只影响应用层 HTTP 头、不改变传输层 TLS 栈。
- 模型数量不再硬编码 `75+`，改为指向 Models Hub。
- 新增 `#architecture`（P-Core / E-Core 职责 + Runtime 分层图 + 模块边界表：
  Internal Runtime Modules vs Public Developer SDKs）、`#release`、`#sdks` 三个区域。
- 凭据描述改为真实的 `credentials.vault`（AES-256-GCM、PBKDF2 / 机器绑定密钥、0600、
  Keychain 仅一次性迁移读取）。
- 页脚 `MIT License` 是错的：LingXiAgent 是 LCSAL-1.1 + PolyForm Noncommercial 多轨许可，
  已改为准确表述并链到 LICENSE-MATRIX。
- TUI 演示窗口加了「界面示意 · 演示数据」标注，去掉 `Context L1` 与 60 FPS 标记。

## M. docs.html 变更（§58、§59）

- 标题/摘要去掉「Windows 实验性」；概览四卡重写（性能数字改为定性说明、
  L1/L2/L3 改为 P/E 职责、反封锁改为请求画像并声明不承诺绕过风控）。
- `#arch-dual-core` 改为冻结语义，并新增两节：`#arch-context`（预算、page-out 与召回，
  阈值全部取自 `ConfigurationTypes.swift` 默认值与 `config.schema.json`）与
  `#arch-decoupling`（Frontend 契约）。
- `#config-spec` 的示例原本是编造的（`defaultModel` / `effort` / `permission.rules` /
  `contextBudget.l1MaxTokens` / `compactionThreshold` 均不存在）。现按随包
  `Defaults/config.json` 与 schema 顶层键重写，并说明旧 `l1/l2/l3`、
  `ecoreStorageEnabled` 键的兼容读取优先级。
- 新增 6 节填补「导航承诺但页面不存在」的空洞：`#vault-spec`、`#models-universal`、
  `#mcp-ecosystem`、`#skills-ecosystem`、`#slash-commands`、`#cli-manual`、
  `#client-fingerprint`、`#public-sdks`。
- Windows 卡片改为「v1.1.0 起发布 x86_64 预编译包」，并附三档支持级别说明。
- 全站命令入口纠正：`auth` / `acp` / `review` / `doctor` / `exec` / `resume` / `mcp` /
  `skills` / `models` 属 `lingxiagent-ops`，页面不再写成 `lingxiagent <verb>`；Zed ACP
  配置的 `command` 同步改为 `lingxiagent-ops`。
- providers.json / mcp.json 示例改为真实 Schema 形态（`providers` 为对象、
  `servers` 为数组、凭据字段只接受 `{env:...}` / `{vault:...}`，明文凭据会被校验拒绝）。
- 导航链接统一为 `/docs.html` 与 `/sdk.html` 一套写法（§60）；页脚补许可与 Releases 入口。

## N. 安装器文档（§56、§57）

`install.ps1` 顶部注释与 fallback 文案的「V1.0.0 暂无 Windows 包 / V1.1.0 才恢复」已改为
「v1.1.0 起发布 Windows x86_64 预编译包」。脚本本身早已指向
`releases/latest/download/lingxiagent-windows-x86_64.zip`，与 release 资产名一致；
`install.sh` 无陈旧版本陈述（三个站点文件与新 gate 测试一起验证）。

## O. 陈旧词搜索结果（§58）

```bash
rg -n 'v2\.0|V1\.0\.0|Windows 实验|L1/L2/L3|三级上下文|tool\.call|75\+|60 ?FPS|~10ms|35MB|反封锁|反检测|JSON-RPC' \
  Server/agent-site/public Server/models-site/public/index.html
```

命中 5 行，逐条确认全部是「否认句或真实协议事实」，无残留宣传：

1. `sdk.html:884` — 「**不是** JSON-RPC 2.0」：§20 要求的正名句子。
2. `docs.html:458` — 「L1/L2/L3 语义**已废弃**，当前架构只有两个核心」。
3. `docs.html:654` — LSP 确实是 Stdio JSON-RPC（与插件 IPC 无关的真实事实）。
4. `docs.html:950` — ACP 确实是 JSON-RPC 2.0（代码 `LingXiACPServer` 发 `jsonrpc: "2.0"`，
   `ACPSpecRevision.modern = "2024-11-05"`）。
5. `docs.html:1283` — 「不宣称 TLS/JA3/JA4 指纹伪装、不承诺免封」。

`实验` / `60 FPS` / `~10ms` / `35MB` 在两个站点已 0 命中。

## P. 两个 SDK 仓库的构建与测试

```text
LingXiModelSDK:  swift build ✓ · swift test ✓（ModelCatalogTests, ModelCatalogLoadingTests,
                                  ModelSDKExampleCompileTests）
LingXiPluginSDK: swift build ✓ · swift test ✓（PluginIPCContractTests, PluginInfoHubTests,
                                  DocumentationExampleCompileTests，共 26 项）
```

两仓库均以 Swift 6 严格并发模式构建（`ISO8601DateFormatter` 非 Sendable 的问题通过
每次调用构造 formatter 解决，而不是降级语言模式）。

## Q. LingXiAgent 干净环境 resolve / build / test

见文末「本地回归结果」。

## R. 生产部署状态

主人 2026-10-01 追加授权上线两个站点（不重出 release）。执行记录：

```text
备份（先备份再覆盖）：
  /var/backups/lingxi-deploy-20261001-151248/
    models-site.tgz        两个站点根目录 + 旧 index.html
    agent-site.tgz
    sync-models.py.old     /srv/lingxi-models-sync/sync-models.py（6721B，schema 1.0 发布器）
    lingxi-models-sync     /etc/cron.d/lingxi-models-sync
    summary.json.retired   原 summary.json（3537036B，移出 web root，未删除）

models.lingxifox.cn：
  /srv/lingxi-models-sync/sync-models.py ← 换成事务式 v2 发布器（原文件留 .v1.bak）
  cron 命令行不变（`sync-models.py /var/www/models.lingxifox.cn`，位置参数接口一致）
  当场以 cron 同权限跑一次：
    published 8341 models / 225 providers，skipped 0，warnings 0
    catalogHash sha256:a3582ac4…453491 · sourceHash sha256:c6fdd95f…9ca6ce · 5,295,273 字节
  新 index.html（读 /models.json）部署；summary.json 退役 → 404
  origin 自检：/models.json = schemaVersion 2.0，/publication.json 200，/summary.json 404

agent.lingxifox.cn：
  bash Server/agent-site/deploy.sh aliyun（rsync --delete，先 --dry-run 确认无删除项）
  origin 与公网均已生效：首页含 #architecture / #sdks / #release，sdk.html 含
  LingXiPluginSDK.git，docs.html 含 lingxiagent-ops，install.ps1 陈旧计数 0
```

公网边缘状态（关键差异）：

```text
agent.lingxifox.cn   全部对象已是新版（HIT 的也是新内容）
models.lingxifox.cn  origin 已是新版，但 ESA 命中 30 天旧缓存：
                     /models.json  Age 164611s · X-Swift-CacheTime 2592000 · v1.0/8277
                     /             仍返回 9-13 的旧 index.html
                     带 ?pb=1 绕过缓存即拿到 5,295,273 字节的 v2 与新 index → 部署本身正确
```

```text
SITE_SOURCE         = READY
PRODUCTION_DEPLOY   = DONE（origin 层，两站点）
EDGE_REFRESH        = PENDING —— 需 ESA 缓存刷新（URL 精确刷新）
```

刷新目标 URL：

```text
https://models.lingxifox.cn/models.json
https://models.lingxifox.cn/
https://models.lingxifox.cn/publication.json
```

本机与服务器都没有 aliyun CLI，当前连接的 MCP 里没有阿里云工具，凭据也不在本狐可碰的范围内，
因此这一步需要主人在 ESA 控制台执行，或明确授权一条带凭据的调用路径。
`Cache-Control: public, max-age=60, must-revalidate` 在源站是对的，ESA 侧对这两个对象
套了 30 天边缘 TTL，所以不刷新就只能等 TTL 自然过期。

## S. 未闭环项

1. **ESA 边缘缓存待刷新**（见 R）：`models.lingxifox.cn` 的 `/`、`/models.json`、
   `/publication.json` 三个对象。属运维动作，不涉及代码正确性。
2. **未重出 release**（主人指示）：本次修复的是安装脚本，v1.1.0 包里本来就含
   `lingxiagent-ops`；用旧脚本装过的人需要重跑安装脚本才会补上该命令。
3. 远程 CI 仍按 §81 保持关闭，等主人下令开启。
4. **产品版本已收敛为单一来源**（原 S4 已闭环）：新增 `Sources/LingXiProtocol/ProductVersion.swift`
   作为唯一真源，CLI / Core / ACP / MCP / 四处 UA / macOS bundle / Sidecar 全部引用它，并由
   `Scripts/version-consistency-check.sh` + `ProductVersionGateTests`（8 项）钉住
   「tag 不允许领先常量」。机制与行为影响见
   `Docs/Decisions/Product-Version-Single-Source-2026-10-01.md`。
   负例已实测：把常量临时改成 `1.0.9` 时脚本 exit 1 并报 3 项 FAIL，gate 测试同样失败。
5. 两站点仍通过 CDN 引 Tailwind 与字体且无 SRI（既有状态，本轮未扩大范围）。

### 本轮追加闭环：ops 安装缺口（主人 2026-10-01 授权修复）

先纠正本报告初版的错误归因：当时根据 `Scripts/package-release.sh` 推断「release 包里没有
`lingxiagent-ops`」。实际下载 v1.1.0 macOS 包列目录证明包里有（CI 三个 job 都 build 且
stage：`release.yml:39,49 / 94,102 / 166,172`）。真正的问题是安装脚本没有把它拷进 bin 目录：

| 文件 | 修复 |
|---|---|
| `Server/agent-site/public/install.sh` | 预编译路径与源码编译路径都安装 `lingxiagent-ops`（源码分支补 `--product lingxiagent-ops`） |
| `Server/agent-site/public/install` | 与 install.sh 保持同内容（该域名同时提供 `/install`） |
| `Server/agent-site/public/install.ps1` | 场景 A / B / C 三条安装路径都拷 `lingxiagent-ops.exe` |
| `Scripts/package-release.sh` | 与本狐 CI 对齐：build 并 stage `LingXiTUI` 与 `lingxiagent-ops`，消除「本地包 ≠ CI 包」 |
| `Scripts/ci-artifact-smoke.sh` | `lingxiagent-ops` 从 `note:` 升级为必需成员，并纳入 exec-bit 检查 |
| `Server/agent-site/public/docs.html` | `#cli-manual` 的缺口说明改为如实描述（包里有、旧脚本没装、如何补齐） |

`bash -n` 通过三个 shell 脚本；`AgentSiteContentGateTests` 16/16 复跑通过。
本机与服务器都无 `pwsh`，`install.ps1` 未做机器语法检查 —— 改动是与相邻
`Test-Path` / `Copy-Item` 块完全同形的五行插入，人工比对通过，但这一点如实记录为
未机器验证项。

---

## 本地回归结果

```text
# 干净环境证明（在删除本地 SDK 副本、切到远程包时执行，见 commit 5b267e5）
$ rm -rf .build && swift package reset && swift package resolve && swift build
resolved: LingXiModelSDK 0.1.0, LingXiPluginSDK 0.1.0（均从 GitHub tag 取得，无本地 path）
Sources/ 与 Tests/ 下无任何 SDK 副本
build: ✓

# 本轮网站改动后的全量回归（网站是静态文件，但门禁测试读的是同一棵树）
$ bash Scripts/ci-integration-tests.sh
Discovered 1439 tests across 204 suites (5 of them XCTest).
chunks run:       98
tests executed:   1437 swift-testing + 5 XCTest / 1439 discovered
failures:         0
timeouts (hang):  0
lingering:        0
All chunks passed.            wall time: 543s
```

本轮新增/相关门禁（均通过）：

```text
AgentSiteContentGateTests              16/16   agent-site 内容、锚点、CLI 形态、安装块与 Package.swift 一致性
ModelCatalogConvergenceGateTests        9/9    双 Catalog 结束、事务发布、跨语言排序
PublicSDKConsumerGateTests              6/6    已解析 checkout 为 Foundation-only、网站与 manifest 版本一致
LingXiAgentPublicModelSDKIntegrationTests、PluginSDKIntegrationTests  6/6  远程包 → import → Core 消费链路
LicenseMatrixDriftTests、CoreDependencyGraphGateTests                 ✓    26 目标许可矩阵同步
Scripts/catalog-pipeline-check.sh                                     ✓    发布管线保证
```

页面可用性验证：本地 `python3 -m http.server` 下 `/`、`/docs.html`、`/sdk.html`、
`/install.sh`、`/install.ps1` 全部 200；三个页面的内联 JS 通过 `node --check`；
首页 release 绑定逻辑用 stub DOM + stub fetch 实跑，确认 `tag_name` / `published_at` /
asset 列表被正确注入且 `.sha256` 被过滤；GitHub API 实际返回
`v1.1.0 / 2026-09-28 / linux-x86_64.tar.gz, macos-arm64.tar.gz, windows-x86_64.zip`，
与页面 fallback 完全一致。本地预览服务已关闭，临时脚本已清理。

## 最终判据

| Gate | 结果 |
|---|---|
| `SDK_MIGRATION` | READY |
| `SDK_WORKSPACE` | READY |
| `PLUGIN_SDK` | READY |
| `AGENT_SITE` | READY |
| `CI_GATE` | READY |
| `PRODUCTION_DEPLOY` | DONE（origin）· `EDGE_REFRESH = PENDING`（ESA 刷新，需主人执行） |

§81 的 16 项清单全部闭环：两个独立 SDK 仓库、双 MIT、0.1.0、Agent 消费远程包、
PluginSDK Foundation-only、假遥测清除、host snapshot 落地、IPC 契约更正、
插件文档更正、首页更正、docs.html 更正、install.ps1 陈旧文案更正、本地 build/test、
干净远程 resolve。ops 安装缺口是本轮追加发现并追加修复的，现已闭环。

唯一未达成「公网可见」的动作是 `models.lingxifox.cn` 三个对象的 ESA 缓存刷新，
属于主人侧权限的运维操作，不改变代码、数据与源站状态（见 R）。

