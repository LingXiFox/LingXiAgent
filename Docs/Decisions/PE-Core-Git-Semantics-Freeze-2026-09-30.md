# LingXiAgent P/E Core + Git 工作区语义冻结

> **性质**：架构契约（Architecture Contract），本轮实现的唯一权威语义，不是候选方案。
> **确立时间**：2026-09-30。基线 commit `d21e79d`（PR #4 合并后）。
> **配套取证**：`Docs/AC/GUI-Core-Integration-Audit.md`（现状审计，含执行中被本文取代的 §6/§9 条目）。
> **第 23 节执行顺序为强制顺序**，实现进度以该节条目对照。

以下内容是本轮实现的**架构契约**，不是候选方案。

不要再提出 A/B/C 分支，也不要在执行过程中重新解释 P/E Core、Git RPC、Tool Budget 或 Git Badge 的语义。

如果现有实现与本文冲突，以本文为目标语义进行收敛。

只有在发现以下情况时才暂停：
1. 会造成不可逆数据损坏；
2. 现有持久化格式无法兼容迁移；
3. 本文两个明确约束之间存在无法同时满足的矛盾。

普通实现复杂度、旧代码存在另一套设计、测试需要修改，都不是暂停理由。

---

# 一、P-Core / E-Core 最终语义

LingXiAgent 只有两个上下文核心：

```text
P-Core
E-Core
```

L1/L2/L3 不再具有架构语义。

## 1. P-Core

P-Core 是每轮真正进入模型上下文的常驻核心。

P-Core 由三部分组成：

```text
P-Core
├── Stable Prefix
├── Growing Context
└── E-Core Index Projection
```

### Stable Prefix

稳定前缀，包括当前 Session 中应该长期保持稳定的内容，例如：

```text
system / developer constraints
核心任务目标
稳定工作状态
必要的长期上下文
```

### Growing Context

当前正在增长、模型当前阶段直接需要的上下文：

```text
用户消息
Assistant 消息
Tool Call
Tool Result
当前 Observation
当前文件内容
当前测试结果
当前任务因果链
其他 active context
```

Growing Context 会持续增长。

当 P-Core 达到水位后，ContextCompaction 从 Growing Context 中选择低保留价值对象移出。

### E-Core Index Projection

P-Core 中始终保留一个轻量的 E-Core 索引投影。

逻辑上包括：

```text
Hot Index
Code Index
```

它告诉模型：

```text
之前有哪些内容已经被移出
这些内容是什么
与当前任务有什么关系
如何重新找到它们
```

这里保存的是轻量 metadata / summary / object reference，不保存已经 page-out 的完整 payload。

---

# 二、E-Core

E-Core 保存：

> 从 P-Core 中移出的完整 Context Object。

例如：

```text
历史 Tool Result
历史 Message
大块 read_file 内容
测试日志
Browser Observation
Computer Use Observation
历史搜索结果
其他被 ContextCompaction 移出的完整上下文
```

核心关系固定为：

```text
P-Core
   │
   │ page-out
   ▼
E-Core

E-Core
   │
   │ recall / page-in
   ▼
P-Core
```

因此不要再把 E-Core 定义成单纯 Cache、Warm Layer 或 L2/L3。

---

# 三、P → E 的唯一生命周期

正常状态：

```text
P-Core
├── Stable Prefix
├── Growing Context
└── E-Core Index
```

当：

```text
currentPCoreTokens > highWater
```

触发 ContextCompaction。

ContextCompaction：

```text
1. 找出所有可淘汰 Context Object
2. 排除 pinned / non-evictable
3. 计算 retention value
4. 选择最低保留价值对象
5. 将完整 payload 写入 E-Core
6. 得到稳定 ECoreObjectID
7. 从 P-Core 删除完整 payload
8. 在 P-Core 的 E-Core Index 中留下轻量索引
9. 重复直到 currentPCoreTokens <= lowWater
```

因此严格的数据流是：

```text
P-Core Full Object
        │
        ▼
ECoreObjectFabric
        │
        ├── Full Payload → E-Core
        │
        └── Object Metadata / ID
                    │
                    ▼
             P-Core E-Core Index
```

---

# 四、Context Value Eviction：量化公式冻结

P-Core 的 Context Eviction 使用以下确定性量化规则。

这不是候选公式，也不是建议值。

本轮实现直接按本文公式落地，不再提出：

- A/B/C 评分方案
- 是否使用 valueDensity
- 权重怎么分
- tokenCost 应该怎么惩罚
- recency 应该怎么衰减
- 同分时怎么选

后续可以基于真实 trace 离线校准权重，但当前版本先固定实现。

---

## 4.1 基本原则

P-Core 淘汰对象时：

> 上下文价值是主导因素，Token 成本只是次级成本因素。

因此禁止：

```text
token 最大的优先淘汰
固定淘汰 N%
固定保留前 70%
RetentionValue / rawTokenCost
```

尤其禁止直接：

```text
valueDensity = retentionValue / tokenCost
```

因为这会过度偏爱极小对象。

最终原则保持：

> 大块内容不一定应该扔，小块内容也不一定应该留下。

---

## 4.2 Pinned Object

首先过滤：

```text
pinned == true
```

Pinned Object 完全不参与评分和排序。

不是给 pinned 一个“大分数”，而是直接从 eviction candidate set 中排除。

默认 pinned 内容包括：

```text
当前用户指令
当前未完成 Agent Loop 的关键因果链
pending Tool Call
当前任务强依赖状态
当前编辑对象的必要上下文
安全 / 权限状态
中断恢复必需状态
当前 Tool 执行状态
当前任务进度关键状态
```

即：

```text
if object.isPinned {
    object 不进入 eviction scoring
}
```

---

## 4.3 Retention Value 特征

每个可淘汰 Context Object 计算以下归一化特征。

所有特征最终必须 clamp 到：

```text
[0.0, 1.0]
```

定义：

```text
T   = taskAffinity
D   = dependencyWeight
Rec = recency
Rel = relevance
F   = frequency
A   = activeFileAffinity
U   = explicitReuse
I   = irreplaceability
```

其中：

```text
I = 1 - reconstructability
```

最终基础保留价值：

```text
R =
    0.24 * T
  + 0.18 * D
  + 0.16 * Rec
  + 0.12 * Rel
  + 0.10 * F
  + 0.10 * A
  + 0.06 * U
  + 0.04 * I
```

权重总和必须保持：

```text
1.00
```

即：

```text
taskAffinity          0.24
dependencyWeight      0.18
recency               0.16
relevance             0.12
frequency             0.10
activeFileAffinity    0.10
explicitReuse         0.06
irreplaceability      0.04
```

不要在实现过程中自行重新分配权重。

---

## 4.4 Task Affinity

`taskAffinity` 表示对象与当前主任务的直接相关程度。

优先复用现有 task affinity / query relevance 能力。

输出统一归一化为：

```text
0.0 ... 1.0
```

大致语义：

```text
1.0 = 当前任务核心内容
0.7 = 当前任务明显相关
0.4 = 间接相关
0.1 = 很弱的历史关联
0.0 = 与当前任务无关
```

如果现有 scorer 已能稳定输出连续值，则不要再人为离散化。

---

## 4.5 Dependency Weight

`dependencyWeight` 表示该 Context Object 是否属于当前未完成任务的因果依赖。

固定定义：

```text
1.0 = 当前未完成因果链直接依赖
0.6 = 当前任务的间接依赖
0.2 = 只有历史依赖关系
0.0 = 当前任务不存在依赖
```

例如：

```text
当前 edit_file 依赖的 read_file
→ 1.0

当前测试依赖的构建结果
→ 1.0

当前任务可能仍需要的旧搜索
→ 0.6

已经完成子任务留下的记录
→ 0.2 或 0.0
```

---

## 4.6 Recency

Recency 使用 turn-based exponential decay。

定义：

```text
deltaTurn = currentTurn - lastUsedTurn
```

计算：

```text
Rec = exp(-deltaTurn / 8)
```

最后：

```text
Rec = clamp(Rec, 0, 1)
```

含义：

```text
刚使用过
→ 接近 1

约 8 turn 未使用
→ 明显衰减

长时间未使用
→ 接近 0
```

不要使用 wall-clock 时间作为主要 recency，因为 Agent Loop 的有效上下文变化以 turn 为主要单位。

---

## 4.7 Frequency

访问频率采用对数归一化，避免访问次数线性膨胀。

定义：

```text
F =
    log(1 + accessCount)
    /
    log(1 + 8)
```

然后：

```text
F = clamp(F, 0, 1)
```

即：

```text
accessCount >= 8
→ F = 1.0
```

重复访问超过 8 次不再继续增加 retention 权重。

---

## 4.8 Relevance

`relevance` 表示内容本身与当前 query / task 的语义相关程度。

优先复用现有：

```text
calculatePriority()
content relevance
task query match
```

统一归一化至：

```text
0.0 ... 1.0
```

不要新建第二套独立 relevance engine。

---

## 4.9 Active File Affinity

`activeFileAffinity` 固定定义为：

```text
1.0 = 当前正在编辑的文件
0.7 = 当前活跃 / 已打开文件
0.3 = 同模块 / 同目标相关文件
0.0 = 无文件关系或完全无关
```

例如：

```text
当前正在修改 A.swift
A.swift 的 read_file
→ 1.0

A.swift 当前依赖的同模块文件
→ 0.3 ~ 0.7
```

现有 `activeFiles` 数据流必须真正维护。

如果目前 `activeFiles == []` 导致该评分永远失效，必须修复数据流，不能保留一个实际恒为 0 的假特征。

---

## 4.10 Explicit Reuse

`explicitReuse` 固定定义：

```text
1.0 = 当前 turn 明确再次引用
0.6 = 最近 4 turn 内被再次使用
0.0 = 没有显式 reuse
```

例如：

```text
Tool Result 被另一个 Tool Call 直接引用
→ 1.0

之前读取的文件刚被再次访问
→ 0.6 或 1.0
```

---

## 4.11 Reconstructability / Irreplaceability

新增：

```text
reconstructability
```

取值：

```text
0.0 = 无法可靠重建
0.3 = 可以重建，但代价很高或结果可能变化
0.7 = 可以较稳定重新读取 / 重新执行
1.0 = 完全确定且廉价重建
```

然后：

```text
irreplaceability =
    1 - reconstructability
```

例如：

```text
用户原始指令
→ reconstructability = 0.0

关键推理决策
→ 0.0 ~ 0.3

read_file 的本地静态文件内容
→ 0.7

廉价、确定性的 git status
→ 1.0

高成本测试输出
→ 0.3 ~ 0.7

外部实时网页 Observation
→ 0.0 ~ 0.3
```

注意：

Pinned Context 已经不进入评分，所以该字段主要服务于普通可淘汰对象之间的比较。

---

## 4.12 Token Cost

Token Cost 不使用裸 token 数作为线性惩罚。

先进行对数归一化。

定义：

```text
C =
    log2(1 + tokenCost)
    /
    log2(1 + pCoreTarget)
```

然后：

```text
C = clamp(C, 0, 1)
```

这样：

```text
200 tokens
和
800 tokens
```

不会因为绝对大小产生过强差距；

同时：

```text
10K / 20K tokens
```

的大对象仍然会体现较高上下文成本。

---

## 4.13 最终 Retention Score

最终评分公式固定为：

```text
RetentionScore =
    R
    /
    (1 + 0.35 * C)
```

展开为：

```text
RetentionScore =
(
    0.24 * taskAffinity
  + 0.18 * dependencyWeight
  + 0.16 * recency
  + 0.12 * relevance
  + 0.10 * frequency
  + 0.10 * activeFileAffinity
  + 0.06 * explicitReuse
  + 0.04 * (1 - reconstructability)
)
/
(
    1 + 0.35 * normalizedTokenCost
)
```

其中：

```text
normalizedTokenCost =
clamp(
    log2(1 + tokenCost)
    /
    log2(1 + pCoreTarget),
    0,
    1
)
```

成本惩罚系数固定：

```text
0.35
```

本轮不要自行调整。

---

## 4.14 Score 解释

RetentionScore：

```text
越高
→ 越应该继续留在 P-Core

越低
→ 越优先 page-out 到 E-Core
```

例如：

### 当前正在编辑的大源码

```text
tokenCost = 8000

taskAffinity       高
dependencyWeight   高
recency            高
activeFileAffinity 1.0
```

即使 token 很大：

```text
RetentionScore 仍然较高
```

因此继续留在 P-Core。

### 已完成阶段的大测试日志

```text
tokenCost = 12000

taskAffinity       低
dependencyWeight   低
recency            低
activeFileAffinity 低
reconstructability 较高
```

因此：

```text
RetentionScore 很低
```

优先 P → E。

### 300 Token 的无关旧状态

虽然：

```text
tokenCost 很低
```

但如果：

```text
taskAffinity = 0
dependencyWeight = 0
relevance 很低
recency 很低
```

其 RetentionScore 仍然很低。

因此：

> 小对象不会因为“小”自动留下。

---

## 4.15 Watermark 触发规则

只有：

```text
currentPCoreTokens > highWater
```

才开始 Context Eviction。

没有超过 highWater：

```text
不要主动淘汰
```

触发后：

```text
1. 排除所有 pinned object
2. 计算所有 candidate 的 RetentionScore
3. 按 RetentionScore 从低到高排序
4. 逐个 page-out 到 E-Core
5. 每移出一个对象重新计算 currentPCoreTokens
6. currentPCoreTokens <= lowWater 后立即停止
```

不要按照百分比预先决定要淘汰多少对象。

淘汰量完全由：

```text
highWater
lowWater
当前实际 P-Core token 使用量
```

决定。

---

## 4.16 Tie-Break 规则

为了保证 deterministic behavior，同分时固定排序规则。

排序优先级：

```text
1. RetentionScore 更低
2. tokenCost 更大
3. lastUsedTurn 更早
4. createdTurn 更早
5. objectID lexical order
```

即：

```text
RetentionScore ASC
tokenCost DESC
lastUsedTurn ASC
createdTurn ASC
objectID ASC
```

禁止依赖：

```text
Dictionary iteration order
Set iteration order
random
```

确保相同输入产生相同 eviction 结果。

---

## 4.17 与 E-Core 的关系

该评分器只属于：

```text
P-Core ContextCompaction
```

它回答的问题只有：

> 当前哪些 Context Object 最应该离开 P-Core？

它不负责：

```text
E-Core 内部热度
E-Core object lifecycle
E-Core recall ranking
Code Index ranking
```

E-Core Heat 不得作为该公式输入。

因此继续保持：

```text
E-Core Hot/Cold
≠
P-Core eviction signal
```

---

## 4.18 Branch Prediction

当前版本：

```text
Branch Prediction
```

完全不进入上述公式。

即：

```text
PredictionWeight = 不存在
```

未来只有在：

```text
真实 trajectory 已验证
+
能够稳定映射到 path / object / context dependency
```

以后，才允许增加一个弱预测项。

本轮不得因为“顺手可以接”而加入。

---

## 4.19 Fail-Open

Context Value Scoring 必须 Fail-Open。

如果某个普通特征不可用，例如：

```text
relevance scorer failure
active file metadata missing
access metadata missing
```

使用对应特征的中性或安全默认值继续运行。

不能因为某个评分子系统失败导致：

```text
Agent Loop 失败
ContextCompaction 失败
Session 失败
```

如果整个 scorer 无法得到可靠结果，则 fallback 到现有稳定 eviction policy。

Fallback 本身必须 deterministic。

但不得 fallback 到：

```text
随机 eviction
删除最大对象
删除最新对象
```

---

## 4.20 可观测性

每次发生 P → E eviction，Debug / Runtime Inspector 应能够看到：

```text
objectID
objectType
tokenCost

taskAffinity
dependencyWeight
recency
relevance
frequency
activeFileAffinity
explicitReuse
reconstructability

normalizedTokenCost
retentionValue
RetentionScore

evictionRank
evictionReason
```

这样以后可以利用真实 Agent trace 校准公式，而不是凭感觉调整权重。

正式用户界面不需要展示全部数值，但 Debug / Inspector 必须可观测。

---

## 4.21 本轮冻结参数

当前版本固定：

```text
taskAffinityWeight       = 0.24
dependencyWeight         = 0.18
recencyWeight            = 0.16
relevanceWeight          = 0.12
frequencyWeight          = 0.10
activeFileAffinityWeight = 0.10
explicitReuseWeight      = 0.06
irreplaceabilityWeight   = 0.04

tokenCostPenalty         = 0.35
recencyTurnDecay         = 8
frequencySaturation      = 8
```

本轮实现不得重新选择这些参数。

如果测试或现有实现与这些值冲突：

> 修改测试和旧实现以适配新的权威公式。

不要因为旧代码已有另一套权重，就重新提出架构分支。

后续如果需要调参，只允许基于真实 trace / benchmark 单独提交校准变更，不和本轮架构收敛混在一起。

---

# 五、Pinned Context

以下内容默认不可被普通 eviction 移出：

```text
当前用户指令
当前未完成 Agent Loop 的关键因果链
pending Tool Call
当前任务强依赖状态
当前编辑对象的必要上下文
安全 / 权限状态
中断恢复必需状态
当前 Tool 执行状态
当前任务进度关键状态
```

除非存在专门的降级策略，否则不得因为 token 较大而直接移出。

---

# 六、E-Core Heat 不控制 P-Core Eviction

保留现有边界：

> E-Core Hot/Cold 不反向控制 P-Core 生命周期。

P-Core eviction 只根据 P-Core 自己掌握的上下文信息进行。

禁止：

```text
ECoreHeatState
→ 直接决定 P-Core eviction

ECoreHeatScorer
→ 直接决定谁从 P-Core 被踢出
```

E-Core Heat 如果保留，只用于 E-Core 内部：

```text
召回排序
Hot Index 构建
对象热度观测
```

不能成为 P-Core ContextCompaction 的控制信号。

---

# 七、Branch Prediction 暂不进入 ContextCompaction

当前 Branch Prediction Fabric 暂时不进入 retention scoring。

原因已经取证明确：

```text
当前主要预测 toolID
真实 trajectory accuracy 尚未形成可靠证据
大量 turn 会 abstain
无法稳定映射到具体 path / context object
```

因此当前：

```text
Branch Prediction
≠
Context Eviction Signal
```

未来当预测能够稳定关联：

```text
file
path
ECoreObject
context dependency
```

以后再作为弱权重加入。

本轮不接。

同时修复 per-session prediction state 的生命周期清理问题，Session 结束后必须释放对应 state，避免长驻进程内存持续增长。

---

# 八、DerivedContextStore 的最终定位

最终架构不允许同时存在两套独立的 P→E payload store。

即不能长期保持：

```text
ContextCompaction
    → DerivedContextStore

context_recall
    → ECoreObjectFabric
```

E-Core 的唯一权威对象存储是：

```text
ECoreObjectFabric
```

因此：

```text
新产生的 page-out
→ ECoreObjectFabric
```

`DerivedContextStore` 进入 Legacy Compatibility 状态。

迁移规则固定：

```text
新写入：
只写 ECoreObjectFabric

新读取：
优先 ECoreObjectFabric

旧数据：
允许 fallback DerivedContextStore
```

完成兼容迁移验证后删除 DerivedContextStore。

不要让两套 Store 长期并行写入。

---

# 九、Exact Restore 与 Semantic Recall 必须分开

P-Core 主动 page-out 一个对象时，必须得到稳定：

```text
ECoreObjectID
```

之后 ContextCompaction 的 page-in 必须支持：

```text
ECoreObjectID
→ exact object
```

这是 Exact Restore。

不能依赖：

```text
best-effort lexical search
semantic search
```

去猜原来的对象是什么。

Semantic Recall 是另一条能力：

```text
query
→ E-Core Index
→ Top-K candidate objects
→ fetch payload
```

因此明确区分：

```text
Exact Restore
objectID → exact object
```

和：

```text
Semantic Recall
query → relevant objects
```

ContextCompaction 的 page-in 使用 Exact Restore。

`context_recall` 使用 Semantic Recall。

---

# 十、L1/L2/L3 彻底退出架构语义

权威字段已经是：

```text
pCoreTarget
pCoreSoftLimit
pCoreHardLimit
eCoreStorageBudget
eCoreRecallBudget
```

继续以这些字段为唯一真实模型。

以下内容全部视为 Legacy terminology：

```text
l1Target
l2Max
l3Capacity

L1ContextEngine
L1ResidentPage
WarmL2Entry
L2WorkingSetPolicy

l2Hits
l3Hits
l2Promotions
```

在 P/E 生命周期和 Store 收敛后，对它们进行清理或按真实职责重命名。

不要再创造新的 L1/L2/L3 类型。

---

# 十一、旧配置键兼容

旧用户配置不能静默失效。

例如：

```text
.agent.l1ProjectMaxCharacters
.agent.l2MaxCharacters
```

新增 P/E 命名配置。

读取优先级固定：

```text
new P/E key
↓
legacy L1/L2 key
↓
default
```

旧键仍然可读取，但标记 deprecated。

GUI 只显示新的 P/E 术语。

旧配置键至少保留一个正式兼容周期。

---

# 十二、Tool Schema Budget

`2000` 不具有运行时架构意义。

当前：

```text
toolSchemaTokens ≈ 2072
```

直接接受。

不要为了压回 2000 缩短 schema 或损失 Tool 参数语义。

`toolSchemaTokens` 是每轮根据当前实际 Tool Schema 动态测量得到的 Context Cost。

真实预算每轮动态计算：

```text
hardInputLimit =
    modelContextCapacity
  - outputReserve
  - systemTokens
  - toolSchemaTokens
  - attachmentTokens
  - protocolOverhead
  - safetyMargin
```

然后：

```text
highWater = min(hardInputLimit, preferred * 1.15)
lowWater  = preferred * 0.8
```

`2000` 如果是测试哨兵，不再解释为运行时预算。

测试回归门槛统一调整为：

```text
2500 tokens
```

它只是防止 Tool Schema 无意识膨胀的测试保护，不参与运行时 ContextCompaction。

同时检查 `fixedOverheadTokens` 与 `toolSchemaTokens` 是否重复扣减。

如果重复，修正。

---

# 十三、Git RPC 最终语义

Git 不建立第二套执行引擎。

现有 `GitAction` 是 Git 操作的权威动作模型：

```text
status
diff
log
show
branch

add
restore
checkout
switch
commit
```

继续复用现有：

```text
GitAction
argv construction
risk classification
ToolMutationCoordinator
PermissionEngine
```

禁止新增：

```text
git.exec(rawArguments)
```

禁止允许调用方注入：

```text
-C
--git-dir
--work-tree
```

---

# 十四、Git RPC Surface

新增正式的 Git RPC namespace。

Read RPC：

```text
git.status
git.diff
git.log
git.show
git.branch
```

Mutation RPC：

```text
git.add
git.restore
git.checkout
git.switch
git.commit
```

RPC 只接受结构化参数。

RPC handler 将结构化参数转换为现有 `GitAction`。

不要建立第二套 argv parser。

---

# 十五、Git 写操作统一走 Mutation Coordinator

所有 Git mutation：

```text
git.add
git.restore
git.checkout
git.switch
git.commit
```

必须进入：

```text
ToolMutationCoordinator
```

不能由 GUI、Agent、RPC handler 各自直接执行 Git。

目标是保证：

```text
Agent mutation
GUI mutation
RPC mutation
```

共享同一个写操作串行化机制。

避免：

```text
GUI git add
与
Agent git commit
```

同时修改同一 repository index。

---

# 十六、Git Permission Identity

身份语义固定，不再选择。

## Agent 发起的 Git mutation

必须使用真实：

```text
sessionID
toolCallID
```

走现有 PermissionEngine。

## GUI 用户主动点击产生的 Git mutation

GUI 的明确点击本身视为用户主动操作，不伪装成 Agent Tool Call。

但仍创建：

```text
sessionID = 当前 GUI Session（如果存在）
toolCallID = "gui:" + UUID
```

用于：

```text
审计
cancelPending
mutation coordination
日志关联
```

GUI 不复用某个 Agent 的 toolCallID。

高风险动作仍可由 GUI 做额外确认，例如：

```text
restore destructive mode
checkout causing overwrite
switch causing overwrite
```

---

# 十七、Git Capability 宣告

RPC、Runtime Capability、Protocol Feature 必须保持一致。

不能再出现：

```text
协议声明了 feature
但 RPC 不存在
```

或者：

```text
RPC 已存在
但 knownFeatures 没广播
```

新增 Git RPC 后同步修正：

```text
ProtocolVersion
RuntimeCapabilities
knownFeatures
RPC schema
ContractTests
```

所有 Git RPC 必须有 capability coverage。

---

# 十八、Transport 缺口

已经确认的四个写命令：

```text
CoreHost + Worktree
```

必须统一经过 transport override。

修复：

```text
InProcessTransport
```

不能因为 protocol method 有默认实现，就让编译通过但运行时绕过 transport。

增加覆盖测试，验证：

```text
CLI
GUI
Agent
InProcessTransport
```

最终进入同一 Git execution path。

---

# 十九、Git Worktree Root

修复当前 main checkout root 推导错误。

不能使用：

```text
git rev-parse --show-toplevel
```

去推 main checkout root，因为在 linked worktree 中它返回当前 linked worktree root。

权威来源使用：

```text
git rev-parse --git-common-dir
```

归一化到 common Git directory 后推导 main checkout root。

要求同时支持：

```text
main worktree
linked worktree
```

不要依赖当前 process cwd 判断 main checkout。

---

# 二十、Git Badge 最终语义

GUI 用户可见徽标使用：

```text
dirtyPathCount
```

定义：

> 当前 Workspace 中存在 Git 工作区变化的唯一文件路径数量。

包含：

```text
tracked modified
tracked added
tracked deleted
renamed
untracked
conflicted
```

不包含：

```text
ignored
```

同一路径无论同时出现：

```text
staged
unstaged
```

都只能计：

```text
1
```

---

# 二十一、Git Status 必须展开全部 Untracked Files

Git status 调用改为：

```text
--untracked-files=all
```

或等价：

```text
-uall
```

禁止让：

```text
new-directory/
```

整体只计作一个变化。

例如目录内存在：

```text
a.swift
b.swift
c.swift
```

则：

```text
untrackedFileCount = 3
```

而不是：

```text
1
```

---

# 二十二、Git Badge 数据模型

新增并正式输出：

```text
dirtyPathCount
trackedChangeCount
untrackedFileCount
conflictedFileCount
```

其中所有 Count 的路径统计必须基于统一解析后的 porcelain records。

`dirtyPathCount` 使用 path 去重。

现有：

```text
changedFileCount
```

暂时保留一个兼容周期，并定义为：

```text
changedFileCount == dirtyPathCount
```

标记 deprecated。

不要让两个字段具有不同用户语义。

GUI 从本轮开始只读取：

```text
dirtyPathCount
```

---

# 二十三、本轮执行顺序固定

不要重新询问顺序。

按以下顺序执行：

```text
1. 固化 P/E 类型与生命周期语义
2. 修复 Tool Schema 动态预算/重复扣减问题
3. 收敛 page-out → ECoreObjectFabric
4. 建立 ECoreObjectID Exact Restore
5. DerivedContextStore 转 Legacy read fallback
6. 将现有 calculatePriority 接入 P-Core Context Eviction
7. 修复 activeFileAffinity 数据流
8. 增加 reconstructability 信号
9. 修复 BranchPrediction per-session state 清理，但不接 eviction
10. 清理内部 L1/L2/L3 生命周期语义
11. 增加旧配置键兼容读取
12. 实现 Git RPC Surface
13. Git mutation 全部接入 ToolMutationCoordinator
14. 修复 Git Permission Identity
15. 修复 Transport override 缺口
16. 修复 main worktree root
17. 实现 dirtyPathCount + -uall + 分项计数
18. 更新 GUI
19. 更新 capability/schema/contract tests
20. 跑完整回归
```

---

# 二十四、完成标准

完成后仓库必须满足以下架构描述：

```text
P-Core
=
Stable Prefix
+
Growing Context
+
E-Core Index Projection
```

```text
E-Core
=
从 P-Core page-out 的完整 Context Objects
```

```text
P-Core ContextCompaction
=
负责什么时候移出、移出谁
```

```text
ECoreObjectFabric
=
负责 E-Core 对象存储、ID、读取、召回
```

```text
E-Core Heat
=
不控制 P-Core eviction
```

```text
L1/L2/L3
=
不再具有运行时架构意义
```

Git 必须满足：

```text
GitAction
=
唯一动作模型

Git RPC
=
结构化公开接口

ToolMutationCoordinator
=
唯一写操作协调路径

PermissionEngine
=
Agent 写操作权限路径

dirtyPathCount
=
GUI 唯一工作区变化徽标语义
```

不要再在实现过程中重新设计这些语义。

如果旧代码与这些语义冲突，整改旧代码，而不是为了迁就旧代码重新引入第三套概念。

---

# 补充冻结（2026-09-30 本轮追加）：E-Core 持久化配置语义

`ecoreStorageEnabled == false` 时，**不允许**把新的 page-out 回退写入 `DerivedContextStore`。

E-Core 是 P/E 架构的**必选逻辑核心**，不存在「关闭 E-Core 后继续正常 compaction」的状态。可关闭的只能是 E-Core 的**持久化能力**。

该配置语义调整为 `eCorePersistenceEnabled`：

| 取值 | 行为 |
|---|---|
| `true` | `ECoreObjectFabric` 使用持久化 backend |
| `false` | `ECoreObjectFabric` 使用 session-scoped in-memory backend |

约束：

1. 两种情况下 `store()` 都**必须正常返回稳定的 `ECoreObjectID`**。
2. `page-out → ECoreObjectFabric → Exact Restore` 的生命周期**不因持久化开关改变**。
3. `persistence=false` 时允许 Session 结束后 E-Core payload 消失 —— 这是关闭持久化的明确语义，**不属于运行期数据丢失**。
4. `DerivedContextStore` 仅允许作为 Legacy Read Fallback，**不允许承接任何新的 page-out 写入**。
5. 因此**不要实现**「E-Core disabled → DerivedContextStore write fallback」。

现有 `ecoreStorageEnabled` 的命名 / 配置兼容迁移纳入第十、十一节的 P/E 术语清理：旧键可以兼容读取，但内部权威语义为 `eCorePersistenceEnabled`。
---

# 落地记录（第十、十一节）

已收敛：

- P→E 唯一入口：`ContextCompactor` 只调用 `ECoreObjectStore.pageOut(...)`；`DerivedContextStore` 的写入 API 改名为 `insertLegacyPage`，生产路径无调用者，因此不存在两套 store 并行写入。
- P-Core 的 E-Core Index Projection 由引用重建，只携带 `referenceID / origin / turn / summary`，不再内联完整 payload；索引自身受预算约束（≤ min(512 tokens, hardInput/8)，且不超过 hardInputLimit）。
- Exact Restore：`referenceID → ECoreReference → objectID → payload`；`context_recall` 走 summary 命中后再按 referenceID 精确取回。
- Context Value Eviction 按第四节冻结公式实现（`ContextValueEviction.swift`），pinned 直接从候选集排除，同分按 4.16 五级 tie-break，scorer 不可用时 Fail-Open 退回确定性旧顺序。
- L 命名类型退出架构语义：`L1ContextEngine→PCoreContextEngine`、`L1ContextSnapshot→PCoreSnapshot`、`L1ContextPolicy→PCorePolicy`、`L1ResidentPage→PCoreResidentPage`、`WarmL2Entry→WarmRecallEntry`、`L2WorkingSet*→WorkingSet*/RecallWorkingSet`。门禁测试 `PCoreTerminologyGateTests` 阻止再新增 L 类型。
- 旧配置键兼容：`agent.l1ProjectMaxCharacters`/`agent.l2MaxCharacters`/`context.fabric.ecoreStorageEnabled` 仍可读，优先级固定为 新键 → 旧键 → 默认；写入与重置只作用于新键；GUI 只显示 P/E 术语。

仍在一个正式兼容周期内、按第十一节保留（不参与生命周期语义，随周期结束删除）：

- `ContextCacheL1/L2/L3Configuration`：旧配置文件键的解码垫片。
- `EffectiveContextPolicy` 上的 `l1Target/l1SoftLimit/l1HardLimit/l2Max/l3Capacity/l3Enabled` 只读别名。
- Debug / 协议 observability 字段名（`l2Hits`、`l3Hits`、`l2Promotions`、`l1ResidentCount` 等）。它们统计的是 Legacy DerivedContextStore 的只读回退命中，本身已随 store 一起进入 legacy 状态；改名涉及线上协议字段，与能力/模式/契约测试同步处理，不单独半改。

---

# 补充冻结（2026-10-01 第二轮）：远程同步与前端 raw git 清零

第一项：权威 `GitAction` 由 10 个动作扩为 13 个 —— 新增 `fetch` / `pull` / `push`，
对应 RPC `git.fetch` / `git.pull` / `git.push` 与 feature `git.remote.sync`。仍然禁止
`git.exec(rawArguments)`、裸 argv、任意 refspec；远程动作同样只接受结构化参数。

固定语义：

- `fetch = repositoryWrite + network`（会更新 remote refs / FETCH_HEAD / 仓库元数据，不是纯只读）。
- `pull` 只有 fast-forward；分叉返回结构化 `nonFastForward`，Core 不 merge、不 rebase、不 auto stash、不 force。
- `push = repositoryRemoteWrite + network`；没有 upstream 时不得猜目标，`setUpstream` 只接受已配置 remote 名。
- Force push 本阶段不支持，将来必须作为独立高风险动作设计。
- 三者与本地写操作一样全部进 `ToolMutationCoordinator`。

第二项：`git.status` / `git.diff` 扩为结构化响应，取代前端 raw git：
`status` 给 `branchName / headSHA / upstreamRemote / upstreamBranch / ahead / behind / files[]`，
`diff` 给 `patch + files[]`（`additions / deletions / binary / status / oldPath`，范围支持
`worktree / staged / head` 以及 `baseReference / commitReference`）。不新增 `git.numstat`。
GUI / TUI / CLI 生产代码不得再启动 git；唯一允许的位置是 Core 的 Git executor。
架构门禁的白名单长度必须保持为 1（只有 `GitRunner.swift`）。


未跟踪文件的 file stats 固定语义（本阶段最后一条）：

```text
tracked file          → additions / deletions 来自 git diff numstat
untracked text file   → additions = 文件行数，deletions = 0，binary = false
untracked binary file → additions = nil，deletions = nil，binary = true
超大 / 读不到 / 编码无法可靠判定 → stats = nil，且不得让整次 git.diff 失败
```

该逻辑只存在于 Core 的 Git service / executor 层。`git.diff` 的结构化 `files[]` 仍是唯一的
file-stat 输出：前端不得为统计读文件、不得用 `git diff --no-index`、不得新增 raw git 白名单。
未跟踪文件仅出现在 `worktree` / `head` 口径；`staged` 口径不含未跟踪。
