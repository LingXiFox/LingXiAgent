---
title: Provider / Model Catalog 语义冻结
date: 2026-10-01
status: landed
scope: models.json 唯一发布物、LingXiModelSDK、旧 Unified Model Registry 退役
supersedes: 双 Catalog（Unified Model Registry /v1/catalog + models.lingxifox.cn）
---

# 落地状态（本轮结束时）

| 契约条目 | 状态 | 落点 |
| --- | --- | --- |
| §1–§2 models.json 唯一公共模型数据源、元数据与 Runtime Provider 语义分离 | 已落地 | `Server/models-site/sync-models.py`、`Sources/LingXiModelSDK` |
| §3 旧 Unified Registry 生产路径清零 | 已落地 | 删除 `ModelRegistryClient.swift`；`CoreHost` / `AuthCLI` / `ModelCatalogDefaults` 全部改走公共目录 |
| §4 保留 `BuiltinProviderCatalog` 运行时契约 | 已落地 | `ProviderContractTypes.swift`（原 `ModelRegistryTypes.swift`）、`BuiltinProviderCatalog.swift` |
| §5 服务器端旧 Registry 清理 | 已落地 | 删除 `Server/lingxi-registry`、`Server/registry`、`lingxi-registry.service`；Caddyfile 摘掉 `/v1/*` |
| §7 models.json 唯一发布物、网页同读一份 | 已落地 | `Server/models-site/public/index.html` 读 `/models.json`；`summary.json` 退役 |
| §8–§9 事务化发布 + 上游 schema 防线 | 已落地 | `Scripts/catalog-pipeline-check.sh`（CI Stage 4b 执行） |
| §10–§11 不猜运行时信息、保留上游语义 | 已落地 | 删除 `determine_swift_driver` / `reasoningField` / `swiftSnippet`；上游字段透传 |
| §12 排序明确稳定可解释 | 已落地 | 发布端 `natural_key` ⇄ SDK `ModelCatalogOrdering.displayName` ⇄ 网页 `Intl.Collator(numeric)` |
| §13–§20 模型站产品定位、禁止私有中转端点、禁止猜 env | 已落地 | `index.html`（详见落地报告） |
| §17 删除死代码 `generate_swift_code()` | 已落地 | 同步脚本 |
| §21 正式 Catalog Schema | 已落地 | `schemaVersion 2.0` + `catalogRevision` / `catalogHash` / `sourceHash` / `sourceFetchedAt` |
| §22 同步可观测性与骤降保护 | 已落地 | 统计输出 + `--min-model-ratio` + `--allow-shrink` |
| §23 部署漂移检查 | 已落地 | `Scripts/catalog-drift-check.sh`（CI `catalog-drift` 作业，按需触发） |
| §25–§34 `LingXiModelSDK` | 已落地 | `Sources/LingXiModelSDK`（Foundation-only，MIT，见 `LICENSE-SDK`）+ `ContractTests/…/ModelSDKDependencyGateTests.swift` |
| §33 网页示例编译门禁 | 已落地 | `Tests/LingXiModelSDKTests/ModelSDKExampleCompileTests.swift` |
| §37 完成判据 | 已落地 | `Tests/LingXiAgentTests/ModelCatalogConvergenceGateTests.swift` |

本狐没有改动 P/E Core 语义（契约首部“本轮与 P/E Core 收敛互相独立”）。

下面正文是冻结原文，逐字保留，作为后续争议的唯一依据。

---

# LingXiAgent Provider / Model Catalog Semantic Convergence

> 本文档冻结 LingXiAgent 的 Provider / Model Catalog、`models.lingxifox.cn`、`LingXiModelSDK` 三者语义与整改方向。  
> 这是架构收敛文档，不是候选方案。  
> 本轮与 P/E Core 收敛互相独立，不允许借此修改 P/E Core 语义。

---

# 1. 目标

当前仓库存在明显的新旧架构混合：

- 新模型目录：`https://models.lingxifox.cn/models.json`
- 旧 Unified Model Registry：`https://lingxiagent.lingxifox.cn/v1/catalog`
- LingXiAgent Core 已经大量使用 `models.lingxifox.cn`
- 但旧 `ModelRegistryClient`、`/v1/catalog`、`registry-catalog.json`、Registry Server 仍有生产调用
- `models-site` 自身还存在数据源、排序、同步、Swift 示例、部署漂移等问题
- 模型站示例错误地绑定 `LingXiAgent` Runtime
- 第三方若要复用 LingXi Models，目前缺少稳定 SDK

本轮目标是：

```text
结束双 Catalog
结束旧 Unified Registry 生产路径
让 models.json 成为唯一公共模型数据源
建立独立 LingXiModelSDK
让 LingXiAgent 与第三方统一通过稳定 SDK 消费模型目录
让 models.lingxifox.cn 成为可信模型目录，而不是 Agent 附属页
```

---

# 2. 权威语义冻结

## 2.1 公共模型目录唯一权威源

公共模型列表和公共模型元数据唯一远程来源：

```text
https://models.lingxifox.cn/models.json
```

其上游数据源：

```text
https://models.dev/api.json
```

禁止继续存在第二套：

```text
https://lingxiagent.lingxifox.cn/v1/catalog
```

作为模型目录源。

`/v1/catalog` 属于废弃的 Unified Model Registry 架构。

---

## 2.2 模型元数据与 Runtime Provider 语义分离

`models.json` 权威负责：

```text
provider/model public identity
model roster
model display metadata
context limit
output limit
pricing
reasoning capability
attachment / modality capability
tool calling capability
structured output 等模型能力
release / update metadata
上游公开模型资料
```

LingXiAgent 自己的 Runtime Provider 层权威负责：

```text
authentication
OAuth / API Key
protocol family
runtime driver
endpoint override
account-specific discovery
provider-specific request adaptation
reasoning wire format
用户配置
```

禁止再次让公共模型目录自行决定 LingXi runtime 行为。

即：

```text
models.dev metadata
≠
LingXi runtime protocol definition
```

---

# 3. 删除旧 Unified Model Registry 生产路径

当前仓库已经确认仍存在：

```text
ModelRegistryClient
→ https://lingxiagent.lingxifox.cn/v1/catalog
```

并且仍有生产调用。

必须完整清理，不只替换 URL。

---

## 3.1 删除生产依赖

清理：

```text
ModelRegistryClient.shared.fetch()
ModelRegistryClient.shared.catalog()
registry-catalog.json
/v1/catalog production fetch
```

重点检查并修改：

```text
CoreHost.start()
scheduleRegistryRefresh()
ModelCatalogDefaults
AuthCLI
所有 ModelRegistryClient caller
```

---

## 3.2 CoreHost 启动

当前类似：

```text
ModelRegistryClient.shared.fetch()
+
LingXiModelsCatalogClient.shared.warmup()
```

改为唯一：

```text
LingXiModelsCatalogClient.shared.warmup()
```

启动不得再访问：

```text
lingxiagent.lingxifox.cn/v1/catalog
```

---

## 3.3 ModelCatalogDefaults

当前逻辑：

```text
Unified Registry 优先
models.lingxifox.cn 补缺
```

属于错误双源语义。

改为：

```text
models.lingxifox.cn/models.json
→ 唯一公共模型 metadata source
```

删除：

```text
registryRecord()
```

以及对应 Registry 优先逻辑。

---

## 3.4 AuthCLI / Model Listing

所有模型枚举不得再来自：

```text
ModelRegistryClient
```

统一走：

```text
LingXiModelsCatalogClient
```

或建立在其上方的统一 Catalog abstraction。

---

# 4. BuiltinProviderCatalog 保留

不要因为删除 Unified Model Registry 而错误删除 `BuiltinProviderCatalog`。

它承担的是 LingXi runtime/provider contract，而不是公共模型数据库。

正确结构：

```text
BuiltinProviderCatalog
    ↓
LingXi runtime semantics
auth / protocol / discovery / adapter

models.lingxifox.cn/models.json
    ↓
public model metadata
model roster / limits / pricing / capabilities

Account Discovery
    ↓
用户当前账号真正可用的模型集合
```

最终可选模型来自：

```text
Public Catalog
∩
Runtime Provider Capability
∩
Account Availability
```

三者职责不重叠。

---

# 5. 服务器端旧 Registry 清理

审计：

```text
Server/lingxi-registry/
Server/registry/
Server/deploy/lingxi-registry.service
Caddy /v1/catalog routes
```

如果它们只服务旧 Unified Model Registry，则删除。

不要继续部署一个已经没有客户端消费者的 Registry daemon。

但注意：

```text
lingxiagent.lingxifox.cn/schema/*.json
```

是另一件事。

JSON Schema URI 如果仍然有效，可以继续保留。

禁止为了删除 `/v1/catalog` 而全局删除 `lingxiagent.lingxifox.cn`。

---

# 6. models.lingxifox.cn 当前实现问题

当前主要代码：

```text
Server/models-site/sync-models.py
Server/models-site/public/index.html
Server/models-site/Caddyfile
```

目前存在以下问题：

1. `models.json` 与 `summary.json` 两套模型数据视图并存
2. Core 读 `models.json`，Web UI 读 `summary.json`
3. Provider 排序依赖手写 `POPULAR_PROVIDERS`
4. 模型列表没有明确稳定排序
5. `swiftDriver` 通过 provider id / npm 猜测
6. `reasoningField` 等 LingXi-specific 语义由同步脚本推断
7. 网页 Swift 示例使用不存在或未验证的 Public API
8. 网页示例 fallback 到私人 `api.lingxifox.*` endpoint
9. `generate_swift_code()` 为死代码
10. `processEnvironment[...]` 等示例并非真实 Public API
11. 仓库源码和线上页面可能存在部署漂移
12. 同步流程缺少强 schema 校验与原子发布
13. 上游异常时可能污染当前发布物
14. 模型站产品定位与 Agent Runtime 绑定过深

---

# 7. models.json 成为唯一 Published Catalog

当前：

```text
models.json
+
summary.json
```

而：

```text
LingXiAgent Core → models.json
Web UI          → summary.json
```

这形成了两个模型数据视图。

整改为：

```text
models.json
=
唯一模型数据发布物
```

网页也直接读取：

```text
/models.json
```

网页需要的：

```text
totalProviders
totalModels
updatedAt
provider counts
model list
```

全部从 `models.json` 推导。

---

## 7.1 summary.json 的处理

不要再维护包含完整模型投影的 `summary.json`。

如果因为性能确实需要 summary，只允许保存 manifest 信息，例如：

```text
catalogRevision
contentHash
updatedAt
totalProviders
totalModels
```

禁止再次复制完整模型字段形成第二套模型数据库。

---

# 8. 同步流程必须事务化

当前同步流程大致是：

```text
fetch
→ transform
→ write models.json
→ write summary.json
```

缺少完整发布事务。

整改后固定为：

```text
1. fetch models.dev
2. validate source shape
3. normalize
4. validate generated catalog
5. serialize to temporary file
6. reopen + decode generated file
7. compute SHA256 / revision
8. atomic rename → models.json
9. only then mark publication successful
```

任何一步失败：

```text
保留上一版 last-known-good models.json
```

禁止产生半写状态。

---

# 9. 同步输入 Schema 防线

不能默认：

```text
models.dev/api.json 永远保持当前 shape
```

同步时至少验证：

```text
provider must be object
provider models must be object
model entry must be object
ID must be non-empty
limit/cost 的类型必须合法
关键 capability 字段类型必须合法
```

单个异常 entry：

```text
记录 warning
根据错误等级 skip entry
```

整体结构损坏：

```text
abort publish
保留 last-known-good
```

禁止因为上游 schema 漂移发布一份被静默污染的 catalog。

---

# 10. 保留上游原始语义，不随意猜 Runtime 信息

当前 `sync-models.py` 存在：

```text
determine_swift_driver(provider_id, npm)
```

通过：

```text
anthropic → anthropicMessages
google/gemini → geminiNative
ollama → ollamaNative
其他 → openaiChat
```

猜测 LingXi runtime driver。

这必须删除。

公共 catalog 不应该通过 models.dev 的 npm 名字猜 LingXi Runtime Adapter。

同理审计：

```text
reasoningField
swiftDriver
```

等 LingXi-specific 字段。

如果这些信息属于 Runtime Contract：

```text
由 BuiltinProviderCatalog / runtime adapter 提供
```

如果确实需要在 catalog 中发布 LingXi augmentation，则必须明确放入独立 namespace：

```json
{
  "lingxi": {
    "..."
  }
}
```

而且只能来自 LingXi 自己的明确映射表，不能从上游字段猜。

---

# 11. models.dev 原始信息不能被无故丢失

当前 `models.json` 使用：

```text
**mdata
```

基本保留原模型对象。

但网页原先通过 `summary.json` 只读取少数字段，因此丢失大量上游信息。

新的 `models.json` 应尽量保持 models.dev 的公开模型字段。

需要 Normalize 时，应：

```text
保持 source semantics
+
增加稳定 LingXi schema
```

不要把未知字段无声删除。

建议记录：

```text
source = models.dev
sourceURL
sourceFetchedAt
catalogGeneratedAt
catalogRevision
sourceHash
```

用于定位同步问题。

---

# 12. 模型排序必须明确、稳定、可解释

当前模型列表没有明确排序：

```text
models.dev iteration order
→ allModels
→ render
```

这是不允许的。

Provider 也不再依赖一份随时间腐化的硬编码：

```text
POPULAR_PROVIDERS
```

作为主要排序机制。

---

## 12.1 Provider 默认排序

采用稳定规则：

```text
configured featured provider rank（可选、显式配置）
↓
provider displayName locale sort
↓
providerID stable tie-break
```

如果没有明确 featured 配置：

```text
全部按 displayName / providerID 稳定排序
```

不要默认：

```text
模型数量越多越靠前
```

模型数量不是“更重要”的语义。

---

## 12.2 模型默认排序

每个 Provider 内模型使用稳定排序：

```text
1. upstream release/update date DESC（存在时）
2. model family/name
3. modelID stable lexical tie-break
```

如果没有可靠时间字段：

```text
name
→ modelID
```

至少保证相同 catalog 每次渲染顺序完全一致。

---

# 13. 模型站产品定位

`models.lingxifox.cn` 定义为：

```text
LingXi 公共模型目录
+
模型元数据浏览界面
+
LingXiModelSDK 官方数据源
+
第三方模型元数据接入入口
```

它不是：

```text
LingXiAgent 专属附属页面
```

也不应该要求使用者先安装整个 LingXiAgent Runtime。

---

# 14. 模型站禁止依赖 LingXiAgent Runtime

当前网页 Swift 示例类似：

```swift
import LingXiAgent
```

这是错误产品边界。

模型目录不应该要求使用者安装完整 Agent Runtime 才能查询模型数据。

必须删除这一依赖。

---

# 15. 禁止公共示例使用 LingXiFox 私有 API 中转 endpoint

当前仓库网页存在 fallback：

```text
https://api.lingxifox.cn/v1
```

如果线上页面实际出现：

```text
api.lingxifox.com
```

也一并视为错误。

这些是私人代理 / sub2api 类 endpoint，不是模型厂商官方公共 endpoint。

公共模型站点禁止自动将未知 Provider fallback 到任何：

```text
api.lingxifox.*
```

地址。

规则固定：

```text
有上游明确 baseURL
→ 可以展示其来源 endpoint

没有可信 baseURL
→ 显示“由 Provider 配置决定”
```

绝对禁止：

```text
missing baseURL
→ 私人代理 endpoint
```

---

# 16. 网页 Swift 示例必须来自真实 Public API

当前仓库中：

```text
LingXiAgent.model(...)
LingXiProvider.openAICompatible(...)
processEnvironment[...]
```

只出现在网页或同步脚本示例中，没有对应稳定 Public SDK 证据。

因此当前示例不能作为正式 API 文档。

规则：

```text
没有真实 Public API
→ 不展示调用示例
```

禁止先写网页示例，再反过来让代码追着网页补 API。

---

# 17. 删除死代码 generate_swift_code()

当前：

```text
sync-models.py::generate_swift_code()
```

全仓无 caller。

同时它生成的也是未验证 Public API。

删除。

以后网页示例若恢复：

```text
来自单一真实模板
+
有编译 Contract Test
```

禁止 Python 和 HTML 各维护一份不同示例。

---

# 18. 环境变量不得由网页用 Provider ID 猜

当前网页类似：

```text
providerId.upper()
→ XXX_API_KEY
```

属于猜测。

而同步源本身可能已经具有：

```text
provider.env
```

因此：

```text
显示 env 信息
→ 使用 catalog 明确提供的 env metadata
```

否则不显示。

禁止自行构造：

```text
${PROVIDER_ID}_API_KEY
```

---

# 19. 网页卡片重新聚焦可信模型信息

每张模型卡至少明确展示：

```text
Provider
Model Name
Model ID

Context Window
Max Output
Input Price
Output Price

Reasoning
Vision / Attachments
Tool Calling
Structured Output（若源数据存在）

Release / Updated 信息（若存在）
```

不要在主卡片显眼位置展示内部：

```text
swiftDriver
```

这是 LingXi 内部 Runtime 实现细节。

---

# 20. Provider 页面信息

选择 Provider 后，可展示：

```text
Provider Name
Provider ID
Official API endpoint（仅上游明确提供时）
Official docs
Environment variable names
模型数量
最后同步时间
```

不要混入 LingXi 私人代理服务。

---

# 21. Catalog Schema 正式版本

当前：

```text
version = "1.0"
```

只是固定字符串，不足以表达真实 Catalog 生命周期。

建立正式 Catalog Schema：

```text
schemaVersion
catalogRevision
generatedAt
sourceFetchedAt
source
sourceHash
catalogHash
```

区分：

```text
Schema Version
≠
Catalog Revision
```

每次 source 内容改变：

```text
catalogRevision 改变
```

Schema 没改变：

```text
schemaVersion 不变
```

---

# 22. 同步可观测性

同步输出至少包含：

```text
source provider count
source model count

published provider count
published model count

skipped providers
skipped models
validation warnings

source hash
catalog hash
generated size
duration
```

并设置异常阈值。

例如模型数量突然大幅下降时：

```text
拒绝自动覆盖 last-known-good
```

除非明确 override。

避免上游临时异常把公开目录清空或大幅缩水。

---

# 23. 部署版本漂移检查

仓库当前没有搜索到：

```text
api.lingxifox.com
```

但存在：

```text
api.lingxifox.cn/v1
```

如果线上页面实际出现 `.com`：

说明可能存在：

```text
deployed artifact
!=
repository source
```

或服务器存在手工修改。

增加部署检查：

```text
published index.html hash
published models.json hash
repository/build artifact hash
```

至少能判断线上是否来自当前构建。

禁止继续手工在服务器修改网页源码而不回写仓库。

---

# 24. models.json 是数据协议，不是最终开发者接口

`https://models.lingxifox.cn/models.json` 定义为：

> LingXi 公共模型目录的数据协议与唯一发布源。

它负责提供：

```text
Provider metadata
Model metadata
Capability metadata
Pricing
Context / Output limits
Upstream public metadata
Catalog revision
```

但第三方开发者不应该被要求直接依赖 JSON 字段细节。

因此：

```text
models.json
=
Data Contract

LingXiModelSDK
=
Developer Contract
```

---

# 25. 建立独立 LingXiModelSDK

新增独立 Swift SDK：

```text
LingXiModelSDK
```

它是独立于 LingXiAgent Runtime 的底层模型目录 SDK。

职责固定为：

```text
Catalog fetch
Catalog cache
Catalog schema decode
Provider metadata
Model metadata
Model lookup
Provider lookup
Capability query
Pricing query
Context/output limit query
Catalog revision / freshness
Filtering / search
```

第一阶段不要加入：

```text
Agent Loop
Tool Runtime
P/E Core
Session
Permission
Computer Use
Workflow
Subagent
```

这些都属于 LingXiAgent，而不是 LingXiModelSDK。

---

# 26. 依赖方向固定

依赖关系必须单向：

```text
models.dev
    ↓
models.lingxifox.cn/models.json
    ↓
LingXiModelSDK
    ↓
LingXiCore / LingXiAgent
```

第三方：

```text
models.lingxifox.cn/models.json
    ↓
LingXiModelSDK
    ↓
Third-party Agent / App / Tool
```

禁止出现：

```text
LingXiModelSDK
→ LingXiAgent
```

或：

```text
models-site
→ LingXiAgent runtime
```

LingXiAgent 可以依赖 LingXiModelSDK。

LingXiModelSDK 不得依赖 LingXiAgent。

---

# 27. LingXiAgent 后续统一通过 LingXiModelSDK 消费 Catalog

当前 LingXiAgent 已经直接使用：

```text
models.lingxifox.cn/models.json
```

本轮可以先保证数据源唯一。

但最终架构应收敛为：

```text
LingXiAgent
→ LingXiModelSDK
→ models.json
```

而不是让 LingXiAgent 自己长期维护第二套：

```text
JSON decode
cache
schema compatibility
lookup
filtering
```

这样 Catalog Schema 未来升级时，只由 LingXiModelSDK 负责兼容。

目标：

```text
只有 LingXiModelSDK 理解 models.json 的底层 schema
```

上层消费者只使用 SDK Public API。

---

# 28. 第三方 Agent 官方接入方式

第三方 Agent / App 如果希望使用 LingXi Models：

推荐：

```swift
import LingXiModelSDK
```

而不是：

```swift
import LingXiAgent
```

更不能要求第三方安装整个 LingXiAgent Runtime。

模型站的产品定位应为：

```text
公共模型目录
+
LingXiModelSDK 官方数据源
+
第三方模型元数据接入入口
```

---

# 29. 模型站禁止继续展示 import LingXiAgent

当前网页类似：

```swift
import LingXiAgent
```

必须删除。

模型站以后若展示 Swift 示例，只允许：

```swift
import LingXiModelSDK
```

但前提是：

> LingXiModelSDK 中对应 Public API 已真实存在，并有 Compile Test。

禁止把：

```swift
import LingXiAgent
```

简单机械替换成：

```swift
import LingXiModelSDK
```

却不真正实现 SDK。

---

# 30. LingXiModelSDK 第一阶段 Public API

第一阶段 SDK 只做模型目录查询，不承担推理 Runtime。

建议 Public API 语义类似：

```swift
import LingXiModelSDK

let catalog = try await LingXiModelCatalog.load()

let model = catalog.model(
    provider: "deepseek",
    id: "deepseek-v4"
)

print(model?.contextWindow)
print(model?.maxOutputTokens)
print(model?.capabilities.reasoning)
print(model?.capabilities.toolCalling)
print(model?.pricing.input)
print(model?.pricing.output)
```

实际命名可根据仓库 Swift 风格调整，但语义必须保持：

```text
Catalog
Provider
Model
Capabilities
Pricing
Limits
```

不要把第一阶段 SDK 设计成 Agent Runtime。

---

# 31. Inference 暂不混入 Catalog SDK 核心

第一阶段：

```text
LingXiModelSDK
=
Catalog / Metadata SDK
```

不要求直接完成模型推理。

如果未来需要提供通用推理能力，可以另开：

```text
LingXiInferenceSDK
```

或：

```text
LingXiModelSDK.Inference
```

但必须是后续独立设计。

当前不要为了让网页看起来“能一行调用模型”而把：

```text
OpenAI-compatible runtime
Provider auth
Streaming
Reasoning adaptation
```

强塞进 LingXiModelSDK。

---

# 32. 网页 Swift 示例第一阶段建议

在 LingXiModelSDK 真正落地后，网页“Swift 示例”首先展示模型目录使用方式。

例如：

```swift
import LingXiModelSDK

let catalog = try await LingXiModelCatalog.load()

if let model = catalog.model(
    provider: "openai",
    id: "gpt-5.6"
) {
    print(model.name)
    print(model.contextWindow)
    print(model.capabilities)
}
```

这类示例和 `models.lingxifox.cn` 的产品职责一致。

不要展示：

```text
私人 API 中转
Agent Runtime
不存在的推理 API
伪造的 Provider factory
```

---

# 33. SDK 必须有 Compile Contract Test

模型站展示的所有 Swift 示例必须来自真实 SDK Public API。

增加：

```text
LingXiModelSDKExampleCompileTests
```

至少验证：

```text
import LingXiModelSDK
Catalog load
Provider lookup
Model lookup
Capability access
Pricing access
Limit access
```

网页模板不得维护一套与真实 SDK 脱节的 Swift API。

如果示例无法通过编译：

```text
CI fail
```

---

# 34. SDK Schema Compatibility

LingXiModelSDK 负责处理：

```text
models.json schema version
missing optional fields
新增字段
旧字段兼容
catalog revision
cache invalidation
```

上层：

```text
LingXiAgent
Third-party Agent
Third-party App
```

不应该直接处理这些兼容细节。

因此未来 `models.json` 从：

```text
schema v1
→ schema v2
```

时：

```text
LingXiModelSDK
```

负责兼容。

消费者 Public API 尽量保持稳定。

---

# 35. 最终产品关系

最终固定为：

```text
models.dev
    ↓
LingXi Sync Pipeline
    ↓
models.lingxifox.cn/models.json
    ↓
LingXiModelSDK
    ├── LingXiAgent
    ├── Third-party Agent
    ├── Third-party App
    └── Other Swift Tools
```

其中：

```text
models.lingxifox.cn
=
公开数据源 + 浏览界面

LingXiModelSDK
=
稳定开发者接口

LingXiAgent
=
SDK 的一个上层消费者
```

禁止再次把：

```text
LingXiAgent
```

定义成使用模型目录的前置依赖。

---

# 36. 最终数据流

整改完成后只允许：

```text
models.dev
    │
    │ validated sync
    ▼
models.lingxifox.cn/models.json
    │
    ├──────────────→ LingXiModelSDK
    │                    │
    │                    ├── LingXiAgent
    │                    └── Third-party consumers
    │
    └──────────────→ models.lingxifox.cn Web UI
```

Runtime Provider 语义：

```text
BuiltinProviderCatalog
+
User Provider Configuration
+
Account Discovery
```

最终模型选择：

```text
models.json public metadata
+
LingXi runtime provider contract
+
account availability
```

禁止重新出现：

```text
Unified Registry
+
models.json
```

两个公共模型 Catalog 并行。

---

# 37. 最终完成标准

完成后全仓生产代码搜索：

```text
/v1/catalog
ModelRegistryClient
registry-catalog.json
```

不得再存在 production caller。

允许历史 Migration Test / Decision Doc 明确以 legacy 名义引用，但不能影响运行时。

全仓搜索：

```text
api.lingxifox.cn/v1
api.lingxifox.com
```

不得再出现在公共模型调用示例中。

网页模型数据必须来自：

```text
/models.json
```

网页不得再维护另一份完整 model projection。

模型排序必须 deterministic。

同步必须：

```text
validate
→ transform
→ validate
→ atomic publish
→ last-known-good fallback
```

模型站 Public Swift 示例：

```text
不得 import LingXiAgent
```

只能在真实 SDK 落地后：

```text
import LingXiModelSDK
```

`LingXiModelSDK` 不得依赖：

```text
LingXiCore Agent Runtime
Session
Tool
P/E Core
GUI
CLI
```

LingXiAgent 最终应逐步通过：

```text
LingXiModelSDK
```

消费：

```text
models.lingxifox.cn/models.json
```

第三方也通过同一 SDK 消费相同 Catalog。

---

# 38. 执行原则

不要在实现过程中重新提出架构分支。

先取证所有旧 Registry caller，再按本文语义逐一收敛。

发现旧代码与本文冲突：

```text
整改旧代码
```

而不是为了兼容旧代码保留第二套 Catalog。

不要顺手修改 P/E Core。

最后必须给出：

```text
1. 删除的旧 Registry production paths
2. 新唯一 Catalog 数据流
3. models-site 同步修复
4. Web UI 排序与数据源修复
5. 删除/替换的错误 Swift 示例
6. LingXiModelSDK 新增边界与 Public API
7. LingXiAgent 接入 LingXiModelSDK 的迁移状态
8. 部署版本漂移检查结果
9. 回归测试结果
```

---

# 39. 一句话架构总结

```text
models.json 是数据协议
LingXiModelSDK 是开发者接口
LingXiAgent 是上层消费者之一
models.lingxifox.cn 是公开数据源与浏览界面
```

这四个角色不得再次混用。
