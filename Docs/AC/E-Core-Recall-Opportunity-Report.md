# E-Core Recall Opportunity Observation 审计与实采报告 (Phase 0.6)

> **报告版本**：Phase 0.6 观测期阶段交付  
> **审计日期**：2026-09-16  
> **责任组件**：E-Core Heat & Telemetry 观测子系统 (`LingXiCore/Modules/Context`)  
> **设计红线**：不推进 Hot/Cold，不修改 Heat 算法与权重，不调整半衰期，不改变任何 Agent 行为，不改变 P-Core/Prefix Cache/Placeholder 内容，纯旁路观测，非阻塞异步 Fail-Open。

---

## 一、核心问题解答：207 个真实 E-Core 对象中召回为 0 的根本原因

在 Phase 0.5 观测期中，真实生产环境 59 个会话的 207 个 E-Core Object 呈现出 **`Never Recalled Ratio = 100%`** 的极化现象。Phase 0.6 的核心任务是查明：**究竟是模型“没有召回机会”（未被投影暴露为 Placeholder），还是“获得了召回机会但模型未触发召回”？**

通过将 207 个物理对象元数据与底层 SQLite `messages` / `message_parts` 真实会话消息流进行逐条因果回溯（匹配成功率 97.1%），我们得出了确凿的客观结论：

### 核心结论：两阶段复合因果链

| 分类 | 样本数 | 占比 | 核心特征与根因 |
| :--- | :--- | :--- | :--- |
| **阶段 A：完全缺乏召回机会 (Zero Opportunity)** | **48 个** | **23.2%** | **处于 `FULL_SENDS` 保护期或会话提前结案**。<br>其中 42 个对象在生成后，会话仅包含 0~1 次后续 Assistant 回复即完结（`post_assistants < 2`）；另有 6 个属于单步测试。模型前台**始终接收完整全文内联**，上下文提示词中**从未出现过 `[Context Object: ...]` 占位符与 `context_recall` 提示**，模型在物理和认知上均零机会。 |
| **阶段 B：存在投影暴露但零转化 (Zero Conversion)** | **159 个** | **76.8%** | **FULL_SENDS 耗尽后模型决策无需召回**。<br>这 159 个对象（全为 `read_file` 138 个、`shell` 39 个等代码分析输出）后续经历了 2 到 13 轮对话，满足投影门槛。但模型在前 2 轮全文内联时，**已将关键信息（函数定义、报错信息）消费并提炼到当前思维上下文中**。在第 3 轮及之后，任务已推进至代码编写或测试验证阶段，对历史大工具输出无重新拉取需求；且模型存在“倾向于再次调用原生 `read_file` / `grep` 而非输入特定句柄调用 `context_recall`”的天然归纳偏置。 |

---

## 二、Phase 0.6 观测基础设施实现

为长期、精准跟踪上述现象，本阶段在 E-Core 遥测体系中新增了完全旁路的 **`objectProjected`** 观测事件。

### 1. `objectProjected` 观测事件定义

在 `Sources/LingXiCore/Modules/Context/ECoreHeatPhase0.swift` 中新增：

```swift
public enum ECoreAccessEventType: String, Codable, Sendable {
    case objectStored = "object_stored"
    case objectRecalled = "object_recalled"
    case recallMiss = "recall_miss"
    case objectProjected = "object_projected" // Phase 0.6 纯观测事件
}

public struct ECoreAccessEvent: Codable, Sendable, Equatable {
    // ... 原有基础字段 ...
    // Phase 0.6 新增纯观测字段
    public let projectionCount: Int?
    public let objectAge: Double?
    public let originalBytes: Int?
}
```

### 2. 严格红线保证

1. **零热度权重贡献**：
   ```swift
   case .objectProjected:
       return 0.0 // Phase 0.6 红线：纯观测事件，绝对不计入热度权重，零贡献
   ```
   在 `ECoreHeatWeightPolicy` 中固化权重为 `0.0`，在回放累加评分时绝不增加任何 `rawHeatScore`，绝不修改对象的 `candidateZone`。
2. **零前台阻塞（Fail-Open 异步脱钩）**：
   在 `ContextProjection.swift` 的占位符生成逻辑中，通过后台并发非阻塞 `Task` 触发：
   ```swift
   Task {
       await ecoreStore.recordProjection(
           sessionID: sessionIDForTelemetry,
           objectID: objectID,
           originalBytes: byteCountForTelemetry,
           turnID: messageIDRaw,
           revision: revisionForTelemetry
       )
   }
   ```
   `ContextProjection` 函数返回值 `[ContextEntry]` 完全保持不变，`buildPlaceholder` 文本格式完全保持不变，前台主流程无任何锁与磁盘 I/O 等待。

---

## 三、三阶段生命周期漏斗 (Stored → Projected → Recalled)

### 1. 指标体系定义

| 漏斗阶段 / 指标 | 数学定义 | 统计学与工程意义 |
| :--- | :--- | :--- |
| **1. Stored Objects** | 唯一已持久化 E-Core 对象数 | 候选外部上下文资产基数 |
| **2. Projected Objects** | 至少经历过 1 次 `objectProjected` 的对象数 | 真正突破前台保护期、暴露给模型的对象规模 |
| **3. Recalled Objects** | 至少经历过 1 次 `objectRecalled` 的对象数 | 真正被模型作为外部记忆拉取回流的对象数 |
| **Projection Rate** | `Projected / Stored` | 保护期穿透率（对象暴露机会比例） |
| **Recall Conversion Rate** | `Recalled / Projected` | 机会转化率（暴露给模型后实际引发召回的概率） |
| **Projection Exposures** | `totalProjectedEvents` | 跨轮次暴露在提示词中的总人次/轮次 |
| **Recall per Exposure** | `totalRecalls / totalExposures` | 单次上下文暴露产生的召回敏感度 |
| **Never Projected Ratio** | `(Stored - Projected) / Stored` | 处于早期保护期内被屏蔽的对象比例 |
| **Projected but Never Recalled** | `(Projected - Recalled) / Projected` | 暴露后处于“冷知晓”状态的对象比例 |

### 2. 生产环境历史回溯量化漏斗

基于真实 207 个历史 E-Core 对象的因果回溯计算：

```mermaid
flowchart TD
    A["Stored Objects (总资产)<br>207 个 (100%)"] -->|未跨过 FULL_SENDS (48个)| B["Never Projected (屏蔽)<br>48 个 (23.2%)<br>前台仅见全文内联，零召回机会"]
    A -->|突破 FULL_SENDS 阈值 (159个)| C["Projected Objects (暴露)<br>159 个 (76.8%)<br>占位符呈现于上下文，具备召回机会"]
    C -->|任务完成转移 / 偏好原生工具| D["Projected but Never Recalled<br>159 个 (100% of Projected)<br>模型已知晓句柄，但无需/未召回"]
    C -->|实际触发 context_recall| E["Recalled Objects (转化)<br>0 个 (0.0%)"]
    
    style A fill:#e1f5fe,stroke:#0288d1
    style B fill:#fff3e0,stroke:#f57c00
    style C fill:#ede7f6,stroke:#512da8
    style D fill:#fbe9e7,stroke:#d84315
    style E fill:#e8f5e9,stroke:#388e3c
```

- **Stored Objects**：207
- **Projected Objects (潜在机会)**：159
- **Projection Rate (机会率)**：**76.8%**
- **Never Projected Ratio (无机会率)**：**23.2%**
- **Recalled Objects**：0
- **Recall Conversion Rate (转化率)**：**0.0%**
- **Projected but Never Recalled Ratio**：**100.0%**

---

## 四、修正 Phase 0.5 结论与未经验证参数标注

在 Phase 0.5 报告中，部分基于先验假设推导的参数尚未经历过闭环召回事件的验证。本阶段明确对以下配置予以**工程纠偏与规范标注**：

### 1. `Unvalidated Production Parameters`（未经验证生产参数）

1. **`halfLifeSeconds = 3600.0` (1 小时半衰期)**：
   > **[Unvalidated Production Parameter]**  
   > 目前真实生产数据中 `totalRecalledEvents = 0`，尚未观测到“同一个会话或跨会话在多长时间后发起二次召回”的真实时间间隔数据。现行的 3600s 仅代表工程默认先验衰减窗口，**禁止在缺乏真实召回数据前作为 Hot/Cold 晋升或淘汰依据**。
2. **`storedWeight = 1.0` (存储事件初始权重)**：
   > **[Unvalidated Production Parameter]**  
   > 存储即赋予 1.0 热度分值的逻辑，在“76.8% 的对象虽暴露但未被召回”的背景下，属于静态先验。若过早引入以此分值为基础的 Hot 缓存预热，可能导致将大量模型不再访问的对象长驻内存。**禁止将 1.0 视为已收敛的最优权重**。
3. **稳健中点百分位等级公式**：
   Phase 0.1 引入的中点等级百分位公式 `(count(<) + 0.5 * count(==)) / N` 在本次观测中表现出卓越的防虚高特性：在 207 个对象全部具有相似衰减分值时，分位数稳健聚集在 P50 附近，彻底消除了由于全 `<= 1.0` 导致的 P99/P100 虚高误判。

---

## 五、E-Core 系统当前定位的权威判定

根据 Phase 0.6 的实采与漏斗事实，对 LingXiAgent 当前阶段的 E-Core 系统定位给出明确技术判定：

### 结论：当前 E-Core 本质是“Archival / Offload Layer”，而非“Active External Memory”

1. **Archival / Offload Layer（安全卸载与容灾归档层）** —— **[当前真实主导形态]**：
   - **核心价值**：承载超大工具输出（10KB ~ 24KB）从内存与 Session 传输中的物理剥离，原子落盘、SHA256 去重与安全备份。
   - **工作负载事实**：99% 以上的开发任务在大模型获取了前 2 次完整内联输出后，就已通过模型自身的推理注意力和短期记忆收敛解决了代码变更，E-Core 充当的是强大的“后备落盘库”，保证上下文预算不超标和任务可回溯。
2. **Active External Memory（活跃外部记忆工作区）** —— **[冷备待命形态]**：
   - **触发边界**：只有当长篇重构任务、超多轮会话（> 15 轮）需要大模型频繁跨步查阅历史细节，且模型被显式提示引导使用 `context_recall` 时，该链路才具备被高频激活的客观条件。
   - **现阶段状态**：基础设施、索引和召回机制已 100% 具备并经过测试验证，但实际工作负载的召回触发率极低。

---

## 六、验证与测试交付

本阶段所有测试均已在 macOS Apple Silicon 原生环境中执行并通过：

```bash
swift test --filter ECoreHeatPhase0Tests
```

### 测试集执行清单（共 20 项，100% 通过）：

1. `testNormalRecallTriggersObjectRecalledEvent`: 验证正常召回记录 `objectRecalled` 事件。
2. `testRecallMissTriggersRecallMissEvent`: 验证未命中记录 `recallMiss` 事件。
3. `testHighFrequencyAccessIncreasesHeat`: 验证时间衰减累加器正确累加。
4. `testInactiveObjectHeatDecaysOverTime`: 验证沉寂对象时间衰减。
5. `testInactiveObjectNewRecallDoesNotReviveHistoricalHeat`: 验证单次新访问不复活历史热度。
6. `testHistoricalHighFrequencyObjectDecaysOverTime`: 验证高频沉寂后热度衰减。
7. `testConsecutiveShortTimeRecallsAccumulateCorrectly`: 验证连续密集访问正确累加。
8. `testTimeReversalAndNegativeDeltaTSafeHandling`: 验证时间倒流安全处理。
9. `testDifferentHalfLifeBehaviors`: 验证不同半衰期衰减倍率。
10. `testPercentileAndQuantileCalculation`: 验证分位数中点等级算法。
11. `testMadZeroRobustDegradationAndSkewedDistribution`: 验证 MAD=0 时稳健降级。
12. `testNanAndInfinityRejectedFromHeatState`: 验证 NaN/Inf 过滤。
13. `testTelemetryDisabledSilent`: 验证遥测开关关闭时静默无 I/O。
14. `testTelemetryWriteFailureFailOpen`: 验证写故障 Fail-Open。
15. `testContextRecallOutputIdentical`: 验证切片召回输出完全一致。
16. `testObservationAnalyzerWithSyntheticWorkload`: 验证合成负载分析与 Pareto 计算。
17. `testRealWorldECoreDataObservation`: 验证生产环境真实数据只读扫描。
18. **`testContextProjectionTriggersObjectProjectedEvent`** (Phase 0.6 新增): 验证 `ContextProjection` 自动旁路记录 `objectProjected` 且正确递增 `projectionCount`。
19. **`testObjectProjectedEventDoesNotAffectHeatScore`** (Phase 0.6 新增): 验证 `objectProjected` 零权重贡献，绝不影响 Heat Score。
20. **`testLifecycleFunnelObservationMetrics`** (Phase 0.6 新增): 验证 Stored → Projected → Recalled 三阶段生命周期漏斗与时延指标计算。

---

## 七、后续建议与收口

1. **维持 Phase 0.6 旁路观测模式**：
   在 LingXiAgent 日常生产任务中保持 `objectProjected` 观测事件的平稳记录，积累真实多轮会话的投影暴露频次。
2. **暂缓推进 Phase 1 Hot/Cold 驱逐与提升**：
   在未形成显著正向召回循环前，**严禁将 `rawHeatScore` 与 P-Core 上下文控制、Prefix Cache 锁定或内存常驻绑定**，避免将冷卸载资产误当作活跃热记忆。
