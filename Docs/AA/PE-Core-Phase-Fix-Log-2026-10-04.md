# P/E-Core 修复执行记录

- 基线：HEAD `4914c1b`
- 依据：`Docs/AA/PE-Core-ToolLoop-Audit-2026-10-04.md`
- 执行方式：按 Phase 顺序，每 Phase 先让测试复现 → 确认修复前失败 → 改生产代码 → focused tests → 相关回归 → 记录前后数据
- 未触碰：frozen eviction scoring、Branch Prediction steering（保持 observation-only）、provider wire 协议形状、GUI 布局、工具 schema、benchmark expectation

---

## Phase 1 — 统一 Tool Artifact Truth / Identity

### STATUS

`COMPLETE`

```
AUTHORITATIVE_TOOL_ARTIFACT_IDENTITY      = PASS
MODEL_FACING_REF_POINTS_TO_FULL_PAYLOAD   = PASS
NO_DUPLICATE_RECALL_TRUTH                 = PASS
```

Gate 测试：`Tests/LingXiAgentTests/ToolArtifactTruthTests.swift`
（真实 shell → ToolOutputPolicy → ToolOutputArchive → SessionStore → E-Core → page-out → ref → recall → 断言；全程无手工 `ToolResult(content:)`）

### ROOT CAUSE

同一个 ToolResult 的"召回真值"由四条互不相干的路径各自决定，最强的一份反而没有任何模型入口：

| 路径 | 产物 | 身份 | 有无 ref |
|---|---|---|---|
| ToolOutputArchive | 完整 raw | SQLite blob key | — |
| SessionRuntime sidecar | 完整 raw（≥32,768 才写） | `generate(tool,callID,content)` FNV | **无** |
| ContextProjection | bounded preview 的再拷贝 | `generate(tool,callID,preview)` | 有 |
| Compaction page-out | `"[Historical tool evidence]\n" + JSON(preview)` | `identify(envelope)` SHA256 | 有 |

模型看到的 ref 指向第 3/4 类，两者都是从 preview 二次导出的弱真值；唯一持有完整字节的路径（sidecar/archive）没有 occurrence-facing ref。加上 `store()` 与 `pageOut()` 用两套 ID 派生，同一 payload 落两个文件。

结果：`refs.first { objectID == identify(raw) }` 为 nil，recall 永远回不到完整载荷。

### ARCHITECTURE DECISION

**一个 occurrence 只有一个 payload 身份，由唯一权威函数决定，投影与 page-out 共用它。**

```swift
// ECoreObjectFabric（新增，唯一的真值定义）
authoritativeToolPayload(sessionID:toolCallID:toolName:content:artifactObjectID:) -> ContextObjectID?
```

规则：

1. `ToolOutputMetadata.artifactObjectID`（新增字段）= 完整 pre-truncation payload 的内容寻址身份，由 `ToolOutputArchive` 在真正存下 blob 时写入。它存在 ⟺ canonical `content` 只是 preview。
2. truncated → 身份就是 `artifactObjectID`，`ContextProjection` 与 `pageOut` 都只**绑定引用**，不再写第二份字节。
3. 从未 truncated → canonical 内容本身就是完整真值，身份为 `identify(toolArtifactRecord(result))`。
4. `toolArtifactRecord(result)` = `JSONEncoder(sortedKeys)` 序列化，保留结构化失败证据（code / exitCode / diagnostics），冻结测试 `structuredFailureSurvivesToolBatchArchive` 的语义不变。
5. sidecar 的入库条件从"preview 大小 ≥ objectizationThreshold"（对 ASCII 恒不成立、且按 preview 度量是循环论证）改为"存在 artifactObjectID"。
6. page-out 粒度从"每 batch 一份 envelope"改为"每 artifact 一份引用"；`contextOccurrenceID = "<batchID>#<callID>"`。`ContextUnitDebugSnapshot.derivedPageID` 只能放一个，因此新增 `occurrenceMessageIDs[session][refID] = Set<MessageID>` 保存反向映射。
7. `store()` 改用 `identify()`，消灭两套 ID。`legacyToolScoped` 保留用于解析改动前落盘的对象。

**Migration / compatibility boundary（明确）**

- 兼容读：`ECoreReference` 自带 `objectID`，旧 `.json` 引用继续按旧 ID 解析，`fetch` 按给定 ID 取文件 → 改动前落盘的对象与引用照常可读，无需数据迁移。
- 新写入：一律 `identify()`；`generate()` 在新路径中不再出现（仅 `legacyToolScoped` 与测试引用）。
- 遗留孤儿：改动前 sidecar 写的 `obj_<tool>_<call>_<fnv>` 对象无引用、不可达。本 Phase **未做**破坏性清理，列为待决项。

### FILES CHANGED

生产：

- `Sources/LingXiProtocol/ToolTypes.swift` — `ToolOutputMetadata.artifactObjectID: String?`（additive optional，Codable 走 `decodeIfPresent`，旧记录可读）
- `Sources/LingXiCore/Modules/Tool/ToolOutputArchive.swift` — 归档时计算内容寻址身份
- `Sources/LingXiCore/Modules/Model/ModelDomain.swift` — `projectToolResult` 重建 metadata 时不再丢失 `artifactObjectID`
- `Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift` — `store()` 内容寻址；`writePayload` 对 `.meta.json` first-writer-wins；`referenceForStoredObject` 支持 evictionEpoch / createdTurn / pageOutReason；新增 `authoritativeToolPayload` + `toolArtifactRecord`
- `Sources/LingXiCore/Modules/Session/SessionRuntime.swift` — sidecar 改为按身份入库并校验 blob 与 ID 一致
- `Sources/LingXiCore/Modules/Context/ContextProjection.swift` — 不再 store preview；引用绑定 authoritative payload；修正文件头那段"C 注释本身讲错了"的原则描述
- `Sources/LingXiCore/Modules/Context/ContextCompaction.swift` — `pageOutToolBatch`（每 artifact 一个引用）；`evictedReferences` 改 `[ECoreReference]`；`occurrenceMessageIDs`；`admitRequestedRecalls` 用反向映射

测试：

- 新增 `Tests/LingXiAgentTests/ToolArtifactTruthTests.swift`（Phase 1 gate）
- 改写 `Tests/LingXiAgentTests/ContextProjectionTests.swift`（`prune...` 的 kept/foreign 身份改为内容寻址——该测试写死了旧 ID 公式）
- 改写 `Tests/LingXiAgentTests/ECorePhysicalCensusTests.swift` 两条：该文件的原注释明确写着"两套 id 派生若被统一，这条断言就该随之改写而不是删掉"，本处照其指示改写为"一 payload 两独立引用"，并保留"去重不得合并生命周期"的断言；restart 基线 2 → 1

### BEFORE

`swift test --filter ToolArtifactTruthTests`（同一测试，修复前）：

```
✗ Expectation failed: refs.first { $0.objectID == artifactID } → nil
```

审计实机数据（51,090B shell 输出）：

```
raw                          = 51,090B
archive blob                 = 51,090B
durable ToolResult.content   = 16,384B (truncated=true)
E-Core objects               = 6 个 46,290–51,090B
E-Core references            = 0            ← 完整载荷无模型入口
model-facing ref → object    = 68,586B（evidence JSON，非 raw）
marker 可达偏移              = 57,344（envelope 内），raw 内真实偏移约 37,600
marker in Chat/Responses/Anthropic wire = false / false / false
```

### AFTER

Gate 测试连跑三次稳定通过（0.5s）。断言覆盖：

1. `preview.output.truncated == true`，`artifactObjectID == identify(raw)`
2. `∃ ref.objectID == artifactID` 且 `restore(ref).utf8.count == raw.utf8.count`
3. `recall(ref.objectID, offset = marker 在 raw 中的真实字节偏移)` 返回含 marker 的 slice
4. `hasObject(generate(tool, callID, preview)) == false` 且无引用指向 preview 派生对象
5. E-Core 中同字节数的对象恰好 1 个
6. canonical 历史未被改写（durable preview 仍是原对象）

Phase 1 后的实机数据（probe01，6 次真 shell 调用）：

```
raw                          = 60,690B
durable ToolResult.content   = 16,384B (truncated=true)
E-Core objects               = 6 个，字节数逐一对应各自 raw（60,690 / 55,890…）
                               → 一 artifact 一对象，无 preview 二次对象
```

### 相关回归

绿：`PEContextIntegrityTests`、`PERecallContractTests`、`ContextProjectionTests`、`ECoreObjectFabricTests`、`ECoreHeatPhase0Tests`、`ECoreRecallDiscoveryTests`、`ECorePhysicalCensusTests`、`SecondaryMemoryHygieneTests`、`PECoreRealWorldValidationTests`

全量 `swift test` 中与本 Phase 无关的隔离复验：`UXAndStreamingFixesTests` / `ProviderRateSchedulerTests` / `TUIRenderingTests` / `CancellationRaceTests` 单独运行全绿（全量并发下的计时抖动）。

仍然红（本 Phase 未触碰，属后续 Phase）：

- `ToolLoopRecoveryTests` 3 条 → Phase 6
- `ContextCompactionTests.eightStepToolLoop...` → **已验证为 HEAD 既有失败**，数字完全相同（`estimated 4948, hardLimit 4552, mandatory 4948`），非本 Phase 引入

### REMAINING RISKS

1. **入库量上升**：sidecar 现在为每个 truncated 结果写一个 E-Core 对象（此前 ≥32,768B 才写）。SQLite archive blob 与 E-Core payload 存在同字节双份。若要消重，需要让 E-Core object 直接以 archive blob 为后端，属独立设计决策。
2. **遗留孤儿对象**：改动前 `generate` 命名的无引用 sidecar 对象仍在磁盘上，普查会计入。未做破坏性清理，等主人决定（可用"无引用即回收"的一次性 sweep，需先备份）。
3. **同 batch 多引用**：`derivedPageID` 只保存主引用，完整映射在内存 `occurrenceMessageIDs`。跨进程恢复目前依赖 `derivedPageID` 回退——多 artifact batch 的第 2+ 个引用在重启后无法反查所属 unit。**这正是 Phase 3 的持久化范围**。
4. `eightStepToolLoop` 的预算前置失败虽与本轮无关，但它会让 P/E 相关的 loop 级测试在此机器上不可判定，建议单独处理。
