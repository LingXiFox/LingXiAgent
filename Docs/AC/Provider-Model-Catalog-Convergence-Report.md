---
title: Provider / Model Catalog 语义收敛落地报告
date: 2026-10-01
contract: Docs/Decisions/Provider-Model-Catalog-Convergence-Freeze-2026-10-01.md
scope: 双 Catalog 结束、models.json 唯一发布物、LingXiModelSDK 建立、模型站与部署漂移
---

# 落地报告（契约 §38 要求的九项）

一句话结论：**旧 Unified Model Registry 的生产路径已全部清零，`models.json` 成为唯一公共模型数据源，
新增的 `LingXiModelSDK` 是它的开发者接口，LingXiAgent 只是 SDK 的上层消费者之一。**
本轮没有触碰 P/E Core 语义。

---

## 1. 删除的旧 Registry production paths

Swift 侧（`/v1/catalog`、`ModelRegistryClient`、`registry-catalog.json` 三个词在全仓生产代码里现已 0 命中，
由 `ModelCatalogConvergenceGateTests` 扫描守护）：

| 删除/改写 | 说明 |
| --- | --- |
| `Sources/LingXiCore/Configuration/ModelRegistryClient.swift` | 整个文件删除。远程 `/v1/catalog` 拉取、ETag 复用、`~/.lingxiagent/cache/registry/registry-catalog.json` 缓存随之消失 |
| `RegistryCatalog` / `RegistryCatalogStatus` / `RegistryCatalogMetadata` / `RegistryVendor` / `RegistryCacheSummary` | 旧 catalog 文档类型删除；`ModelRegistryTypes.swift` → `ProviderContractTypes.swift`，只保留运行时 provider 契约类型（§4） |
| `CoreHost.scheduleRegistryRefresh()` | → `scheduleCatalogWarmup()`，启动只 warmup 公共目录，不再访问 `lingxiagent.lingxifox.cn/v1/catalog`（§3.2） |
| `CoreHostStartupPolicy.refreshRegistry` | → `refreshModelCatalog`，语义与命名一起收敛 |
| `CoreHost.providerModels()` | 产品集合来自 `BuiltinProviderCatalog.registryProducts`，元数据来自公共目录 `publishedRecords(forProduct:)`；不再存在「Registry 优先、models.json 补缺」的双源判断 |
| `ModelCatalogDefaults.registryRecord()` | 删除。目录默认值只有 `models.json` 一个来源（§3.3） |
| `AuthCLI.renderModelIDs()` / `renderModels()` / `syncCloudCatalog()` | 前两者改走公共目录 + 账号缓存；`auth models sync` 语义变成刷新公共目录，输出 `catalogRevision` / `catalogHash` / `source` |
| `ModelDiscoveryEngine` 离线回退 | `cachedModelsForProduct` → `discoveredModels(forProduct:)`（SDK 数据） |
| `registryModels:` 参数 | → `catalogModels:`，27 处调用点与文档措辞一起改；注释里「registry 决定我们知道多少」改成「公共目录决定」 |
| `Tests/.../UnifiedModelRegistryTests.swift` | → `ModelAvailabilityAndDiscoveryTests.swift`；其中 5 个专测旧 client 的用例删除（ETag、不可达回退、partial catalog 解码等），同等语义在 SDK 测试里以更强的形式重新覆盖 |

服务器侧（审计结论：这三处**只**服务旧 Unified Registry，无任何 Swift / CI / Script 消费者）：

- 删除 `Server/lingxi-registry/`（Go daemon，12 文件；路由表只有 `GET /v1/*` 八个端点，无 `/schema`、无 auth、无 telemetry）
- 删除 `Server/registry/`（`vendors/providers/oauth-products/overlays/discovery-profiles` + README，唯一读者是 `internal/registry/loader.go`）
- 删除 `Server/deploy/lingxi-registry.service`
- `Server/deploy/Caddyfile` 摘掉两处 `handle /v1/* { reverse_proxy 127.0.0.1:8787 }` 及配套 `@static` 匹配器
- **保留** `lingxiagent.lingxifox.cn` 两个 server block 的静态 `file_server`：`/var/www/lingxiagent/schema/*.json` 仍是四份 JSON Schema 的 `$id` 归属地，删除 host 会打断配置校验（§5 明令禁止牵连）
- 顺带消除一份重复副本：`Server/models-site/Caddyfile` 与 `Server/deploy/Caddyfile` 曾逐字节相同，删掉前者，部署脚本 `deploy-caddy.sh` 只认一个来源

## 2. 新的唯一 Catalog 数据流

```
models.dev/api.json
      │  sync-models.py：validate source → normalize → validate catalog → temp → 回读解码 → sha256 → os.replace
      ▼
models.lingxifox.cn/models.json      ← 唯一发布物（schemaVersion 2.0）
      ├──────────────→ LingXiModelSDK ──→ LingXiAgent（经 PublicModelCatalogClient）
      │                                └─→ 第三方 Agent / App
      └──────────────→ models.lingxifox.cn Web UI（同一份 /models.json）
```

职责三分，互不重叠（§2.2 / §4 / §36）：

| 层 | 权威内容 | 落点 |
| --- | --- | --- |
| 公共模型目录 | 身份、roster、上下文/输出上限、价格、能力、发布/更新时间 | `models.json` + `LingXiModelSDK` |
| Runtime Provider 契约 | auth / OAuth / 协议族 / driver / 端点覆盖 / 账号级发现 | `BuiltinProviderCatalog` + `ProviderRegistry` + 用户 `providers.json` |
| Account Discovery | 该账号真正可达的模型 | `AccountScopedCatalogCache` 等 |

最终可选模型 = Public Catalog ∩ Runtime Provider Capability ∩ Account Availability，
实现仍在 `ModelAvailabilityResolver`，但三个入参的来源已各自归位。

`ProviderCatalog` 里最重要的一处语义修正：可连接判断不再读 catalog 的 `swiftDriver`，
而由 `BuiltinProviderCatalog.protocolFamily` 回答（`openai → openai_responses`、
`anthropic → anthropic_messages`、`deepseek → openai_chat`）；runtime 没有契约的厂商
「列出但不可连接」，不再靠上游包名猜协议。命名空间靠 `productProviderAliases` 显式桥接
（`openai-api↔openai`、`gemini-api↔google`、`mimo-api↔xiaomi`、`zai-api↔zai/zhipuai` 等，
逐个对着发布 roster 核过），顺带修好了此前 curated 产品在公共目录里查不到 roster 的问题。

## 3. models-site 同步修复（§7–§12、§17、§21、§22）

`Server/models-site/sync-models.py` 整体重写：

- **单一发布物**：不再产出 `summary.json`（曾是一份 8337 行的第二套模型投影）；网页读同一份 `models.json`
- **事务化发布**：`fetch → validate_source → normalize → validate_generated → mkstemp+fsync → 回读并再解码 → sha256/revision → os.replace → 写 publication.json 标记`；
  任何一步失败 → 旧 `models.json` 一字节不动，退出码 2
- **上游 schema 防线**：provider/`models`/model entry 必须是对象、ID 非空、`limit` 非负整数、
  `cost` 为对象或 null、capability 字段类型合法、modalities 为字符串数组；
  单条不合格 → warning + 跳过；整体形状漂移（过半 provider 没有模型对象）→ abort
- **不再猜运行时信息**：删除 `determine_swift_driver()`、`reasoningField` 推断、
  `swiftSnippet`，并显式剔除历史遗留字段（`RUNTIME_GUESS_FIELDS`）——不发布 `lingxi` 增强命名空间，
  因为网页按 §19 已不该显示这些，发布它们没有消费者
- **保留上游语义**：provider / model 对象整体透传（含 SDK 尚未认识的字段，
  实测 `brand_new_upstream_field` 原样存活），只做加法：`baseURL`（镜像上游 `api`）、`modelCount`
- **envelope 正式化**：`schemaVersion` / `catalogRevision` / `catalogHash` / `generatedAt` /
  `sourceFetchedAt` / `source` / `sourceURL` / `sourceHash`；
  `catalogRevision` 由 providers 内容哈希导出 —— 数据不变则 revision 不变，schema 不变则 `schemaVersion` 不变
- **确定性排序**：厂商 `displayName` 数字感知自然序 → `providerID`；模型 发布日期 DESC → family → name → modelID；
  删除 `POPULAR_PROVIDERS` 硬编码，也不再按模型数量排（数量不是重要性）
- **可观测性 + 骤降保护**：输出 source/published 计数、跳过数、warning 数、双哈希、字节数、耗时；
  模型或厂商数跌破 `--min-model-ratio`（默认 0.7）→ 拒绝覆盖 last-known-good，除非显式 `--allow-shrink`
- 死代码 `generate_swift_code()` 删除

发布结果：225 providers / 8341 models / 0 跳过 / 0 warning，5,294,879 字节（旧发布物 19 MB）。

## 4. Web UI 排序与数据源修复（§7、§13–§20）

- 数据源唯一：`fetch('/models.json')`；`totalProviders/totalModels/updatedAt/schemaVersion/catalogRevision/sourceHash` 全部来自同一文档
- 排序显式：`Intl.Collator('en', { numeric: true, sensitivity: 'accent' })` + id 兜底，模型侧按发布日期倒序、family、name、id
- 卡片字段按 §19：Provider、Name、Model ID、上下文窗口、最大输出、输入/输出单价、
  Reasoning、Vision/Attachments、Tool Calling、Structured Output（源数据存在才显示）、
  Release/Updated（源数据存在才显示）、deprecated 标记
- 主卡片不再出现 `swiftDriver`（LingXi 内部实现细节）
- §18：环境变量只渲染目录明确给出的 `env`，缺省写「来源未提供环境变量名」，不再用 `providerId.upper()` 拼 `XXX_API_KEY`
- §15：端点只在上游明确给出时展示；没有可信 baseURL 就写「由 Provider 配置决定（来源未发布端点）」，
  私有中转地址作为 fallback 的路径被彻底删除
- §20：厂商面板展示 Name / ID / 官方端点（仅来源有）/ 官方文档 / env 名 / 模型数 / 最后同步时间

## 5. 删除与替换的错误 Swift 示例

删除的伪造 API（曾同时存在于网页弹窗、同步脚本死代码和**线上发布的数据本身**）：

```swift
import LingXiAgent
LingXiAgent.model("openai/gpt-5", apiKey: processEnvironment["OPENAI_API_KEY"])
LingXiProvider.openAICompatible(baseURL: URL(string: baseURL || "https://api.lingxifox.cn/v1")!, ...)
session.stream(...)   // 不存在的推理 API
```

替换为真实、且被编译门禁保护的最小示例（目录查询，不是推理）：

```swift
import LingXiModelSDK

let catalog = try await LingXiModelCatalog.load()
if let model = catalog.model(provider: "deepseek", id: "deepseek-v4-flash") {
    print(model.name, model.contextWindow ?? 0, model.maxOutputTokens ?? 0)
    print(model.capabilities.reasoning, model.capabilities.toolCalling)
    print(model.pricing.input ?? 0.0, model.pricing.output ?? 0.0)
}
let eligible = catalog.models(matching: ModelFilter(vision: true, minimumContextWindow: 200_000))
print(catalog.revision.catalogRevision, catalog.revision.generatedAt as Any)
```

守护方式：`ModelSDKExampleCompileTests` 编译同样的调用形式（示例不能编译 = CI 失败）；
`ModelCatalogConvergenceGateTests.webExampleMatchesRealSDK` 把网页里的 `SDK_EXAMPLE` 逐成员抽出，
要求每个名字都在 `Sources/LingXiModelSDK` 里真实声明过。Python 与 HTML 各写一份示例的旧局面结束。

## 6. LingXiModelSDK 的新增边界与 Public API

新增独立 target + library product `LingXiModelSDK`，依赖闭包为空（只 import Foundation，
Linux 上加 FoundationNetworking），第一阶段只承担目录/元数据，不含 Agent Loop、Tool Runtime、
P/E Core、Session、Permission、Computer Use、Workflow、Subagent（§25），也不含推理（§31）。

| 类型 | 作用 |
| --- | --- |
| `LingXiModelCatalog` | `load(configuration:transport:cache:forceRefresh:)`、`decoded(from:)`、快照值类型 |
| `LingXiModelCatalog.Revision` | `schemaVersion` / `catalogRevision` / `catalogHash` / `source` / `sourceURL` / `sourceHash` / `generatedAt` / `sourceFetchedAt` / 计数 |
| `CatalogProvider` / `CatalogModel` | 身份、`baseURL`（仅来源给出）、`documentationURL`、`environmentVariableNames`、limits / capabilities / pricing / status、`qualifiedID` |
| `ModelLimits` / `ModelCapabilities` / `ModelPricing` | 「未知」与「零/否」可区分：缺失保持 `nil` |
| `ModelFilter` + `search(_:limit:)` | 能力、模态、窗口下限、是否含 deprecated 的过滤与检索 |
| `ModelCatalogOrdering` | 全仓唯一排序规则；发布端与网页分别用等价实现，并由门禁对齐 |
| `ModelCatalogConfiguration` / `ModelCatalogTransport` / `ModelCatalogCache` / `ModelCatalogCacheStore` | 端点、maxAge、可选磁盘缓存、ETag 再验证、可注入传输层（测试离线） |
| `ModelCatalogValue` | 承载 SDK 尚未建模的上游字段（§11 的「不无声删除」） |
| `ModelCatalogError` | `invalidCatalog` / `unsupportedSchemaVersion` / `unexpectedStatus` / `transport` / `unavailable` |

Schema 兼容只在这里发生（§34）：v1 文档（`version`/`updatedAt`，含历史 `swiftDriver` 等字段）仍可读，
v2 是正式 envelope，未知 `schemaVersion` 主版本直接拒绝而不是半读；
单条坏数据只丢那一条，结构性损坏才失败。取不到网络且有缓存 → 回退缓存；什么都没有 → 抛错，
绝不返回「空目录」这种看起来像「上游没有模型」的假答案。

依赖方向由 `ModelSDKDependencyGateTests` 三条门禁锁死：SDK 依赖闭包为空、源码只 import Foundation、
`LingXiCore → LingXiModelSDK` 单向且 Core 侧不得再出现 `JSONDecoder` / `Codable`（第二套 schema 理解）。

## 7. LingXiAgent 接入 LingXiModelSDK 的迁移状态

已完成的迁移（本轮即达成，不是「以后再说」）：

- `Sources/LingXiCore/Provider/Discovery/PublicModelCatalogClient.swift`（原 `LingXiModelsCatalogClient.swift`）
  变成 SDK 之上的薄适配层：删掉了自有的 `CatalogPayload/ProviderEntry/ModelEntry` 解码结构，
  改持有 `LingXiModelCatalog` 快照，并把目录答案映射成 Core 已有的 `DiscoveredRemoteModel` / `RegistryModelRecord`
- 消费者全部改读 SDK 类型：`ModelCatalogDefaults`、`ProviderCatalog`、`CoreHost`（列表 + assembly 兜底）、
  `ModelDiscoveryEngine`、`AuthCLI`
- 前端与 RPC 契约面**未变**：GUI / TUI / WebUI 依旧只经 `provider.catalog` 等既有 RPC 拿数据，
  本轮改的是 Core 内部的数据权威来源，因此 §1–§4 的前端零 raw-git 类约束不受影响

仍然存在的残留（如实说明）：`RegistryProduct` / `RegistryModelRecord` / `RegistryCapabilities`
等**类型名**保留 `Registry` 前缀。它们承载的是 §4 的运行时 provider 契约，不是已退役的公共目录；
文件头已写明这一点。把它们改名成 `Provider*` 是纯机械改名，会波及约 40 处调用点，本狐按最小化原则
没有顺手做，留作独立的小任务。

## 8. 部署版本漂移检查结果

`Scripts/catalog-drift-check.sh` 已落地（CI 的 `catalog-drift` 作业，按需触发，只读 GET、不写服务器）。
本狐在 2026-10-01 实测一次，结论是**线上确实与仓库不同源，而且两个方向都在漂**：

| 对象 | 线上 | 仓库（本轮构建） |
| --- | --- | --- |
| `index.html` | sha256 `8ea6f19c014c…`，仍 `fetch('/summary.json')`，含 1 处 `import LingXiAgent`、1 处 `api.lingxifox.cn` | sha256 `e2c317e39ee5…`，读 `/models.json`，无上述内容 |
| `models.json` | `version 1.0`，`updatedAt 2026-09-30T20:01:34Z`，225 providers / 8337 models，20,980,317 字节 | `schemaVersion 2.0`，225 providers / 8341 models，5,294,879 字节 |
| 目录内容 | 内嵌 `"swiftDriver"` ×16899、`"reasoningField"` ×8337、`"swiftSnippet"` ×8337 —— 即 **`import LingXiAgent` 的伪造示例被写进了数据协议本身**，随 8337 条模型分发 | 三类字段 0 命中 |
| `summary.json` | 仍在服务（HTTP 200，354,683 字节的第二套投影） | 已退役 |
| `publication.json` | 404（旧发布物没有发布标记） | 已生成，含 revision/hash/计数/字节 |
| `catalogRevision` / `sourceHash` | 线上文档不存在这两个字段 | 存在 |

补充事实：契约 §23 猜测的 `api.lingxifox.com` 全仓 0 命中、线上 0 命中；实际存在的是
`api.lingxifox.cn/v1`（在**页面**的旧示例里）。而 `import LingXiAgent` 的污染范围比契约写的更大——
不止网页示例，也在线上 `models.json` 的每条模型里。

本狐当时**没有**部署：发布与重启站点属于影响线上服务的动作，按约定要先取得主人许可。
当时现状是仓库已收敛，线上下一次同步（跑 `sync-models.py` 并 rsync 发布物 + 停用
`lingxi-registry.service`）才会对齐；在那之前 `catalog-drift-check.sh` 会持续报 DRIFT，这正是它该做的事。

> **2026-10-01 更新（主人授权上线）**：`/srv/lingxi-models-sync/sync-models.py` 已换成事务式 v2
> 发布器（旧文件留 `.v1.bak`，cron 命令行不变），当场以 cron 同权限发布成功：
> 8341 models / 225 providers、skipped 0、warnings 0、`catalogRevision a3582ac44a04`。
> 新 `index.html`（读 `/models.json`）已部署，`summary.json` 退役为 404（文件移入备份目录，未删除）。
> 服务器上 `lingxi-registry.service` 已为 `inactive`。仓库内 `Server/models-site/public/`
> 已回收与线上完全同源的发布物。唯一剩项是 ESA 边缘缓存刷新：
> `models.lingxifox.cn` 的 `/`、`/models.json`、`/publication.json` 仍命中 30 天旧缓存
> （源站已是新版，加查询串绕过缓存即拿到 v2），需主人在控制台刷新。
> 详见 `Docs/AC/SDK-Workspace-PluginSDK-Agent-Site-Report.md` 的 R 节。

## 9. 回归测试结果

### 静态门禁（全部可重复执行）

| 门禁 | 位置 | 结果 |
| --- | --- | --- |
| 旧 Registry 生产调用为 0（`/v1/catalog` / `ModelRegistryClient` / `registry-catalog.json` / `RegistryCatalog`） | `Tests/LingXiAgentTests/ModelCatalogConvergenceGateTests.swift` | 通过 |
| 旧 Registry 服务器组件已消失，schema 宿主仍在 | 同上 | 通过 |
| Caddyfile 无 `/v1/*` 反代、无 `summary.json`、静态块保留 | 同上 | 通过 |
| 网页只读 `/models.json`、无 `POPULAR_PROVIDERS`/`swiftDriver`/第二投影 | 同上 | 通过 |
| 公共示例无 `api.lingxifox.*`、无 `import LingXiAgent`、无 `processEnvironment`、无 env 拼接猜测 | 同上 | 通过 |
| 网页示例每个成员名都在 SDK 中真实声明 | 同上 | 通过 |
| 发布物为 v2 envelope、无运行时猜测字段、厂商键序等于 SDK 公开排序规则（从字节回读校验） | 同上 | 通过 |
| 同步脚本：无猜测函数、事务步骤齐、骤降保护、envelope 字段齐 | 同上 | 通过 |
| `LingXiModelSDK` 依赖闭包为空 / 只 import Foundation / Core 单向消费 | `ContractTests/LingXiPlatformContractTests/ModelSDKDependencyGateTests.swift` | 通过 |
| 环架构 gate（GUI 不触达 Core 等）未受影响 | `CoreDependencyGraphGateTests` | 通过 |

### 新增与改写测试

- 新增 `Tests/LingXiModelSDKTests`（独立 test target，依赖闭包只有 SDK）：
  解码 / envelope / 排序 / 查询过滤 / 缓存与 ETag / 磁盘往返 / 离线回退 / 网页示例编译门禁，共 28 个用例
- 新增 `ModelCatalogConvergenceGateTests` 9 个门禁用例、`ModelSDKDependencyGateTests` 3 个方向门禁
- 改写 `ProviderCatalogTests` 7 个用例（新的可连接语义、命名空间桥接、发布顺序即展示顺序）
- 改写 `ModelAvailabilityAndDiscoveryTests`：删除 5 个专测旧 client 的用例，同等保证（离线回退、ETag 再验证、
  缓存往返）改由 SDK 测试以更严的形式覆盖

### 管线回归

`bash Scripts/catalog-pipeline-check.sh` 全绿：正常发布、同源码重发布 revision 不变、
上游乱序输入发布结果不变、截断 / 结构漂移 / 骤降三种失败均保留 last-known-good、
`--allow-shrink` 生效、坏条目只丢该条、`--check` 离线校验。

### 真机验证（不只看代码）

1. `lingxiagent-ops auth models`（离线，无公共目录缓存）→ 正确回退到账号缓存，表结构与信息密度未退化
2. `lingxiagent-ops auth models sync` → SDK 直接读**线上仍是 v1 的 models.json**（223 providers / 8173 models）
   并成功解码，证明 §34 的向后兼容不是纸面承诺
3. `lingxiagent-ops auth models deepseek-api` → 命名空间桥接生效：`deepseek-api` 通过 `deepseek` 拿到 4 条真实
   roster（1000k 上下文 / 393k 输出），并且 `status` 现在来自公共目录（`deprecated` 被运行时正常抑制）
4. 用 Node 把 `index.html` 的数据层对着真实 5.2 MB 发布物跑了一遍：
   225 providers / 8341 models 读通，厂商序为 displayName 自然序（`302.AI, Abacus, abliteration.ai, above.dev, AgentRouter`），
   deepseek 内模型按发布日期倒序，筛选（工具 7292 / 视觉 5096）与搜索正常，
   渲染出的卡片含价格与上下文字段、**不含** `swiftDriver` 与 `LingXiAgent`；
   无 `baseURL` 的厂商（`aihubmix`）详情面板显示「由 Provider 配置决定（来源未发布端点）」，
   env 显示 `AIHUBMIX_API_KEY`（来源给出才显示），文档链接与最后同步时间正确

### 全量套件

`bash Scripts/ci-integration-tests.sh`（99 个 chunk，分块 + watchdog 的正式跑法）：

- 耗时 553s，chunks 99/99 全部执行
- 用例 1440 swift-testing + 5 XCTest，discovered 1442
- 失败 1：`LicenseMatrixDriftTests` —— 真实回归，新 target `LingXiModelSDK` / `LingXiModelSDKTests`
  没进 `LICENSE-MATRIX.md`；补入两行后该 chunk 复跑通过
- 超时（hang）0，残留进程 0
- 收敛后状态：全量绿

## 已知残留与后续（如实说明）

0. **许可已由主人拍板（2026-10-01）**：`LingXiModelSDK` 采用 **MIT**，新增 `LICENSE-SDK`，
   `LICENSE-MATRIX.md` 与总 `LICENSE`（新增 Part 3）同步登记。允许项即主人列出的七条：
   商业使用、第三方 Agent 集成、App 集成、修改、源码再分发、二进制再分发、闭源产品链接引用执行。
   范围只覆盖 SDK 自身：Core 仍是 LCSAL-1.1，前端仍是 PolyForm Noncommercial 1.0.0，
   「用 SDK 查元数据」不构成对运行时的任何授权。`Scripts/license-matrix.zsh` 与
   `LicenseMatrixDriftTests` 共同保证矩阵与 `Package.swift` 不再脱钩。

1. **已部署（2026-10-01 主人授权）**：线上发布物改由事务式 v2 发布器产出，`summary.json` 退役、
   旧 `lingxi-registry.service` 处于 `inactive`。剩余的 `catalog-drift-check.sh` DRIFT 只来自
   ESA 边缘仍缓存旧 `/` 与 `/models.json` —— 刷新缓存后即归零；在此之前该脚本报 DRIFT 是正确行为，
   不是回归。`lingxiagent.lingxifox.cn/v1/*` 返回 404 已生效：已安装的旧客户端读不到 catalog 时
   按既有逻辑降级到本地缓存 / 内置契约，不会崩。
2. **类型名残留**：`RegistryProduct` / `RegistryModelRecord` / `RegistryCapabilities` 仍带 `Registry` 前缀。
   它们属于 §4 保留的运行时 provider 契约，文件头已写明；改名会波及约 40 处调用点，本轮按最小化原则没做。
3. **缓存文件名换了**：`~/.lingxiagent/cache/models-site/lingxi-models-catalog.json` → 同目录下的
   `models.json` + `models.json.meta.json`。旧文件成为无人读取的死字节（可再生成的运行期状态，未替主人删除），
   首次联网启动会自动重建。
4. **模型站页面仍有两个无 SRI 的第三方引用**（`cdn.tailwindcss.com`、`fonts.googleapis.com`）。
   改造前即存在，不属于本契约条目，本狐没有擅自换构建方式；若要收口，建议本地化 Tailwind 产物并加 CSP。
5. `docs/`、`Docs/Research` 等历史记录里仍有旧 Registry 时代的描述，按「历史记录不改写」原则保留。

6. **「BAI 添加模型列表为空」已定位（2026-10-02），根因不在候选读取器**：`token.sensenova.cn/v1/models`
   实测返回 `{"data":[{"id":…,"name":…},…]}` 共 **9 个模型**，`providers.json` 里 `bai` 只配了
   `deepseek-v4-flash` 一个 —— 所以候选本该有 8 个，「配置只写了一个模型」这个猜测是错的。
   真正断掉的是凭据引用：`bai.options.apiKey` 是 `{env:SENSENOVA_API_KEY}`，该变量只存在于登录 shell
   （`.zshenv`，35 字节），`launchctl getenv` 读到 0 字节；GUI 从 Dock 启动时环境来自 launchd，
   `VNextStdioTransport.swift:110` 又把这份环境原样交给 Core 子进程，于是 `resolveProviderSecret`
   解析成 nil，请求以**无鉴权**发出并拿到 401。旧代码把 401 静默成 `[]`，再回退到公共索引
   （索引里没有 `bai`），最终呈现为一个没有任何解释的空列表。
   两处已改：读取器与连接测试合并为 `ProviderConnectivityProbe.modelIDs(in:)`（此前连接测试认
   `models`/裸数组、候选读取器只认 `data`，同一端点两处结论相反）；`provider.catalogModels` 的 payload
   改为 `ProviderModelRoster { models, note }`，空列表必须说明原因，且 `{env:X}` 解析不到时直接指名 X
   而不再发出这个注定被拒的请求。
   **配置方式本身已于同日整改**（见下条 7）。

7. **Credential Resolution 层收敛（2026-10-02）**：按「显式 env override → vault/keychain → missing」
   重建这一层，不再针对 BAI 打补丁。
   - 新增 `Sources/LingXiCore/Configuration/ProviderCredentialSource.swift`：一份 grammar
     （`{vault:}` / `{oauth:}` / `{env:}` / 兜底 literal）加一个 override 层
     `LINGXI_<PROVIDER_ID>_API_KEY`（id 大写、非 `[A-Za-z0-9]` 转 `_`，所以 `openai-codex` 与
     `Open AI` 不会拼出两个键）。`resolveProviderSecret` 与真正发请求的 `resolveRuntimeAssembly`
     都先过 override，两处口径一致。
   - **自愈迁移** `ProviderCredentialMigration.apply(configurationStore:credentialStore:environment:)`：
     `{env:X}` 且 X 当前有值 → 写入 `provider-<id>-key` 并把配置改写为 `{vault:…}`，改写前备份
     `providers.json.bak-pre-credential-migration`（已存在则不覆盖，保留最早的原文件）；X 无值 →
     一个字都不改，因为改写指针等于销毁密钥的唯一记录处。写入走设置窗口已在用的 `saveProviders`，
     没有引入新的形状转换。
   - **落点是产品入口，不是 `CoreHost.start()`**：`LingXiCoreHost/main.swift` 与
     `lingxiagent-ops/main.swift` 在 load 配置之前各调一次。本狐最初把它放在 `start()` 里，全量回归
     因此改写了主人的线上 `providers.json` —— `VNextProductionIntegrationTests` 会故意拿真实 data root
     起一个 host 做 skills/MCP 发现，测试二进制里几百个 host 都跑 `start()`，启动期写配置等于让测试
     改用户 profile。已改到入口层，并加了一条源码门禁测试
     （`migrationIsNotWiredIntoHostStartup`）盯住这件事，防止再被搬回 `start()`。
   - 没有采用 `zsh -l` 导入登录 shell 环境，也没有把 `launchctl setenv` 当解决方案（诊断文字里原先
     建议的那句已删）。`{env:}` 保留为开发 / CI / 命令行形态。
   - 顺带修掉一个死值 bug：`auth import-env` 会把值额外写进 vault 引用 `env:NAME`，而
     `RuntimeConfigurationResolver.credentialValue` 见到 `env:` 前缀去读**环境变量**、永不读 vault，
     那条记录存进去就再也读不出来；`auth set env:NAME` 同理，而 help 还在宣传这个写法。
     现在 `set` 拒绝 `env:` 前缀、`import-env` 只写一条、help 换成可用示例。
   - 全仓扫描：本机持久账户里只有 `bai` 用了 `{env:}`（`xiaomi` 已是 `{vault:}`），无其它命中。
   - 规范同步：`Docs/AA/P19.1-PROVIDER-TUI.md` 与 `README.md` 的凭据段已改写为三层口径。
   - 验收：`ProviderCredentialResolutionTests`（9 项，含"迁移后撤掉环境变量仍能解析"、"变量缺失时
     绝不改写"、"override 盖过 vault"、以及上面那条入口层门禁）。真实链路另跑过：`LingXiCoreHost`
     从终端启动一次，把主人线上 `bai` 从 `{env:SENSENOVA_API_KEY}` 迁成 `{vault:provider-bai-key}`；
     随后 `env -u SENSENOVA_API_KEY` 模拟 Dock 启动，干净退出、不再触发迁移；剥掉环境变量后
     `/v1/models` 仍返回 **9 个模型**、note 为空，候选面板因此有 8 项可勾。
     `LINGXI_BAI_API_KEY=sk-deliberately-wrong` 时读回 0 个并报 `HTTP 401`，证明 override 确实优先于
     vault。一次性验证代码用完即删，未留在测试里。
