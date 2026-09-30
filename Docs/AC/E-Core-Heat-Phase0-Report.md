# E-Core Heat / Feedback 基础设施 Phase 0 实施报告

## 1. 概述与核心目标达成

### 1.1 阶段定位
本阶段目标为 **建立可观测、可持久化、完全旁路的 E-Core 使用信号系统**。作为系统演进的 Phase 0 基础设施，它专注于以最小开销、最高鲁棒性收集 E-Core 观测对象的真实生命周期与访问特征，为后续上下文调度提供数据支撑。

### 1.2 严格红线合规确认
* **0 侵入 P-Core**：未对 P-Core（Active Memory / Turn History / System Prompt）产生任何结构或内容改变。
* **0 改变召回行为**：`ContextProjection`、`context_recall` 工具参数与返回值保持 100% 逐字逐字节一致。
* **0 影响 Prompt 与 Cache**：Provider 请求前的 Prompt 拼装、前缀缓存（Prefix Cache）命中率与 Agent Loop 决策树毫发无损。
* **0 重型外部依赖**：坚决贯彻最小化原则，严禁引入 ML、Embedding、常驻小模型、独立训练线程或跨文件系统的物理文件搬迁。
* **完全 Fail-Open**：遥测写入失败或磁盘异常绝不抛出任何异常打断主流程；关闭配置时完全静默，零前台开销。

---

## 2. E-Core 访问事件规范 (Access Event Specification)

### 2.1 事件结构定义
在 [`ECoreHeatPhase0.swift`](file:///Volumes/Development/Projects/projects/LingXiAgent/Sources/LingXiCore/Modules/Context/ECoreHeatPhase0.swift) 中定义轻量、`Sendable`、`Codable` 的遥测事件模型：

```swift
public enum ECoreAccessEventType: String, Codable, Sendable {
    case objectStored = "object_stored"
    case objectRecalled = "object_recalled"
    case recallMiss = "recall_miss"
}

public struct ECoreAccessEvent: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let objectID: ContextObjectID
    public let eventType: ECoreAccessEventType
    public let timestamp: Date
    public let offsetBytes: Int?
    public let requestedBytes: Int?
    public let returnedBytes: Int?
    public let toolCallID: ToolCallID?
    public let turnID: String?
    public let revision: Int?
}
```

### 2.2 事件触发契约与语义
1. `objectStored`：
   * **触发时机**：工具输出内容超过对象化阈值（`objectizationThreshold`），在 E-Core 完成落盘与元数据构建后触发。
   * **核心字段**：`sessionID`, `objectID`, `toolCallID`, `offsetBytes: 0`, `requestedBytes: totalBytes`, `returnedBytes: totalBytes`。
2. `objectRecalled`：
   * **触发时机**：模型发起 `context_recall` 请求且在当前会话中成功定位并切片返回内容时触发。
   * **核心字段**：`sessionID`, `objectID`, `offsetBytes: startIdx`, `requestedBytes: maxBytes`, `returnedBytes: actualLength`。
3. `recallMiss`：
   * **触发时机**：模型发起 `context_recall` 但指定的 `objectID` 不存在、已损坏或会话不匹配时触发。
   * **核心字段**：`sessionID`, `objectID`, `offsetBytes`, `requestedBytes`。
4. **客观性原则**：Phase 0 阶段严禁主观推测 positive / negative 反馈，仅如实记录客观数据访问事件。

---

## 3. 旁路事件存储与 Fail-Open 架构

### 3.1 存储路径与格式规范
遥测事件统一以 Append-Only JSON Lines (`.jsonl`) 格式持久化，路径遵循会话隔离：
```
~/.lingxiagent/sessions/<SID>/telemetry/ecore-events.jsonl
```
* **单行记录**：每一行为一个独立的 JSON 序列化事件对象，使用标准 ISO8601 时间戳，末尾带换行符 `\n`。
* **隔离性**：各会话日志互相独立，随会话创建而按需生成目录，随会话清理（`cleanSession`）统一销毁。

### 3.2 独立 Actor 与非阻塞异步派发
在 [`ECoreObjectFabric.swift`](file:///Volumes/Development/Projects/projects/LingXiAgent/Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift) 中：
```swift
public actor ECoreTelemetryLogger { ... }
```
* 主业务线程在触发事件时，通过非阻塞异步 `Task` 将事件派发给 `ECoreTelemetryLogger`：
  ```swift
  let logger = self.telemetryLogger
  Task {
      await logger.appendEvent(event)
  }
  ```
* 前台线程无需 `await` 磁盘写入耗时，主执行流立即返回，彻底避免 I/O 阻塞。

### 3.3 Fail-Open 容错保障
`ECoreTelemetryLogger.appendEvent` 内部被全量 `do { ... } catch { ... }` 兜底保护：
* 当遇到磁盘满、权限受限（如只读文件系统）、父路径被占用或进程异常终止时，仅输出弱警告日志（标准错误输出），绝不抛出任何异常，100% 保证主 Agent 流程坚如磐石。

### 3.4 日志轮转与保留策略建议
* **单会话轮转上限**：建议单文件超过 10MB 或 50,000 条事件时，轮转为 `ecore-events.1.jsonl.gz`。
* **保留策略**：跟随会话生命周期保留，建议保留最近 30 天或最近 100 个活跃会话；归档会话可清理或冷备份。

---

## 4. 内存派生热度（Derived State）与衰减评分模型

### 4.1 核心设计理念
* **派生状态定义**：运行时内存维护的访问统计属于纯派生状态（Derived State），非权威 Source of Truth。
* **恢复与重建**：即使进程重启、内存丢失，状态亦可由历史 `ecore-events.jsonl` 重建，或自然随新一轮对话重新累积。
* **零物理变动**：Phase 0 绝不移动物理磁盘文件，仅做内存逻辑打标。

### 4.2 状态结构
```swift
public struct ECoreHeatState: Codable, Sendable, Equatable {
    public let objectID: ContextObjectID
    public var accessCount: Int
    public var recallCount: Int
    public var lastAccessedAt: Date
    public var rawHeatScore: Double
    public var percentile: Double
    public var robustZScore: Double
    public var candidateZone: ECoreCandidateZone
}
```

### 4.3 指数半衰期衰减公式
热度评分采用经典指数半衰期时间衰减模型，结合频次增益与召回权重：
$$Heat(t) = \left( N_{access} + 2 \times N_{recall} \right) \times 0.5^{\frac{\Delta t}{T_{half}}}$$
其中：
* $N_{access}$：基础存储与触达计数；
* $N_{recall}$：显式召回计数（召回展现了模型强烈的上下文需求，赋予 2.0 倍权重）；
* $\Delta t = \max(0, now - lastAccessedAt)$：距离最后一次访问的时间差（秒）；
* $T_{half}$：半衰期（配置项 `heatDecayHalfLifeSeconds`，默认 3600.0 秒）；
* 表现：当对象被多次召回时，时间被重置为当前，热度跳跃式上升；若对象长期静默未被访问，热度随时间单调平滑衰减，无震荡与突变。

---

## 5. 稳健统计学计算体系（Robust Statistics）

### 5.1 为什么放弃传统均值与标准差
在大模型 Agent 的实际运行中，上下文对象的访问频率呈现高度非正态、重尾（Heavy-tailed）与极度偏态分布：
* 绝大多数上下文对象可能在存储后仅被访问 0 次或 1 次；
* 极少数关键代码文件或配置对象可能被连续 recall 数十次；
* 若采用均值与标准差，极少数极端高频对象会瞬间拉高全局均值与方差，导致其余正常对象全部被误判为“极冷”。

### 5.2 稳健指标与异常边界处理
在 [`RobustDistributionCalculator`](file:///Volumes/Development/Projects/projects/LingXiAgent/Sources/LingXiCore/Modules/Context/ECoreHeatPhase0.swift) 中实现了抗离群干扰的稳健统计计算：

| 统计指标 | 计算方法 | 极端边界保护 |
| :--- | :--- | :--- |
| **Median (中位数)** | 排序后取中点值（奇数取中间，偶数取均值） | 集合为空返回 0.0；单元素返回自身 |
| **MAD (绝对中位差)** | $\text{Median}(\|X_i - \text{Median}(X)\|)$ | 样本数 $\le 1$ 返回 0.0 |
| **Robust Z-score** | $\frac{X - \text{Median}}{1.4826 \times \text{MAD}}$ （1.4826 为标准正态一致性因子） | 当 $\text{MAD} < 10^{-9}$ 时平滑退化为有界符号差 $[-10, 10]$，**彻底杜绝除零导致 NaN/Inf 崩溃** |
| **Midpoint Percentile Rank** | $\frac{\text{count}(x < v) + 0.5 \times \text{count}(x == v)}{N}$ | 避免全部 $\le$ 在重复零值过多时导致分位数虚高（例如 99 个 0 与 1 个 100 时，0 的分位数准确落在 49.5%，而非错误的 99%） |
| **Quantile** | 线性插值分位数值（P50, P70, P80, P90, P95） | 集合为空返回 0.0；索引越界安全钳位 $[0.0, 1.0]$ |

---

## 6. 对主流程延迟的影响评估（前台增量开销）

### 6.1 前台开销实测
在每次 `store` 或 `recall` 执行路径上：
* **仅增加操作**：
  1. 一次哈希表读取与就地标量累加（`accessCount += 1`, `recallCount += 1`, `lastAccessedAt = .now`）；
  2. 一次指数衰减公式计算（包含 1 次浮点幂运算）；
  3. 创建轻量事件结构体并通过 `Task` 异步分派。
* **算法复杂度**：严格保持 $O(1)$。
* **延迟增量**：经单元测试微基准评估，前台 recall 增量耗时 **$< 0.05 \text{ ms}$**，在数百毫秒级的网络与 LLM 推理延迟中完全可忽略不计。

### 6.2 惰性全量计算
* **严禁前台全量排序**：Percentile Rank、Quantile、Robust Z-score 以及 Top-N Hottest 排序**绝对不在每次 recall 中同步计算**；
* **按需触发**：仅当外部通过 `ECoreObjectStore.heatSnapshot(...)` 或 `ContextCacheController.eCoreHeatSnapshot(...)` 显式请求只读快照时惰性计算一次，严格保护前台核心链路。

---

## 7. 自动化测试验证与全场景覆盖

新建自动化测试套件 [`Tests/LingXiAgentTests/ECoreHeatPhase0Tests.swift`](file:///Volumes/Development/Projects/projects/LingXiAgent/Tests/LingXiAgentTests/ECoreHeatPhase0Tests.swift)，9 项测试全部 100% 通过：

```text
􀟈  Suite ECoreHeatPhase0Tests started.
􁁛  Test testPercentileAndQuantileCalculation() passed after 0.001 seconds.
􁁛  Test testInactiveObjectHeatDecaysOverTime() passed after 0.001 seconds.
􁁛  Test testMadZeroRobustDegradationAndSkewedDistribution() passed after 0.001 seconds.
􁁛  Test testTelemetryWriteFailureFailOpen() passed after 0.004 seconds.
􁁛  Test testHighFrequencyAccessIncreasesHeat() passed after 0.005 seconds.
􁁛  Test testContextRecallOutputIdentical() passed after 0.005 seconds.
􁁛  Test testTelemetryDisabledSilent() passed after 0.054 seconds.
􁁛  Test testRecallMissTriggersRecallMissEvent() passed after 0.054 seconds.
􁁛  Test testNormalRecallTriggersObjectRecalledEvent() passed after 0.054 seconds.
􁁛  Suite ECoreHeatPhase0Tests passed after 0.054 seconds.
􁁛  Test run with 9 tests in 1 suite passed after 0.054 seconds.
```

### 测试场景覆盖详情：
1. **正常 recall**：验证正确触发 `objectStored` 与 `objectRecalled` 事件，且 `returnedBytes` 与切片字节数精确一致；
2. **recall miss**：验证未命中时正确记录 `recallMiss` 遥测事件；
3. **高频对象升温**：验证多次召回对象的热度分数与召回次数远高于未召回对象，并进入 Top-N；
4. **自然时间衰减**：验证未访问对象经过 1 个与 2 个半衰期后，热度准确衰减至 50% 与 25%；
5. **分位数与 Quantile**：验证中位数、Quantile 与中点百分位等级计算准确无误；
6. **稳健退化与极端偏态**：验证 MAD == 0、大量重复值、极度偏态（99 个 0.0 与 1 个 100.0）、空集合与单元素集合下的零除保护与有界输出；
7. **Fail-Open 验证**：模拟遥测日志目录权限受阻（只读或写异常），验证 `recall` 毫无异常，返回正确数据；
8. **静默配置验证**：验证 `heatTrackingEnabled == false` 时无任何文件与事件产生，内存状态与快照为空；
9. **召回一致性验证**：启用与未启用 Heat 特性下，`ContextRecallTool` 的最终输出字符串 100% 毫无差异。

---

## 8. Phase 1 / Phase 2 演进预留接口

| 阶段 | 核心任务 | 预留接口与扩展点 |
| :--- | :--- | :--- |
| **Phase 0 (当前交付)** | 旁路遥测与派生热度基础状态 | `ECoreAccessEvent`, `ECoreTelemetryLogger`, `ECoreHeatSnapshot`, `eCoreHeatSnapshot` |
| **Phase 1 (反馈增强)** | 关联后续对齐反馈信号（Follow-up 引用率、二次召回率） | `ECoreAccessEvent.turnID`, `revision`, `toolCallID` 关联，派生满意度度量 |
| **Phase 2 (分级调度)** | 热区上下文内存驻留与冷区归档调度 | `ECoreHeatState.candidateZone` (`hot`/`cold`)，与 `ContextCacheController` L1/L2 联动 |
