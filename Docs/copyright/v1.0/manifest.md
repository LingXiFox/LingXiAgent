# LingXiAgent 本地自主智能体软件 V1.0 - 软件著作权源程序清单

## 1. 基本信息

| 属性 | 内容 |
| :--- | :--- |
| **软件全称** | LingXiAgent 本地自主智能体软件 |
| **软件简称** | LingXiAgent |
| **目标版本** | V1.0 |
| **开发语言** | Swift 6.0 |
| **Git 分支** | `main` |
| **Git Commit SHA** | `b0c883f22b01c2359f9fb62e103463f3db5bd2d4` |
| **Git Tag** | 无（未打标签） |
| **工作区状态** | Clean（工作区整洁，无未提交修改，已完全冻结） |
| **生成日期** | 2026-09-14 |
| **纳入文件总数** | 53 个文件 |
| **纳入总行数** | 18631 行 |
| **版权归属** | 本项目第一方团队自主研发，不含任何未经许可的第三方商业或开源库代码 |

---

## 2. 模块代码统计汇总

| 架构模块 | 文件数量 | 代码总行数 | 核心职能概述 |
| :--- | :---: | :---: | :--- |
| **Agent Runtime** | 5 | 1506 | 智能体决策主循环、工作流推进、System Prompt 装配与子智能体派发 |
| **Context Engine** | 14 | 3932 | P-Core/E-Core 异构双核、L1/L2/L3 三级上下文流控、高水位智能压缩与缓存感知调度 |
| **Session Runtime** | 6 | 2921 | 会话生命周期状态机、轮次独占锁协调、历史快照与防并发竞争保障 |
| **Tool Runtime** | 6 | 2838 | 内置核心文件/命令/检索工具集、沙箱安全看门狗与大产物旁路归档 |
| **MCP Runtime** | 3 | 1356 | 原生 Model Context Protocol 协议引擎（Stdio / HTTP 双通道）与 OAuth 2.1 鉴权 |
| **Persistence** | 3 | 980 | 基于 SQLite 的持久化数据引擎与版本化数据迁移保障 |
| **EventLog** | 2 | 671 | 细粒度审计事件日志追加流与预写日志（WAL）异常崩溃恢复机制 |
| **Model Gateway** | 14 | 4427 | 统一多模型协议网关、速率智能退避、错误智能分类与 Prompt Cache 结构构建 |
| **合计** | **53** | **18631** | **完整覆盖 LingXiAgent 本地自主智能体软件全部核心底层与核心算法** |

---

## 3. 纳入材料的源码文件详细清单

> 说明：以下文件排列顺序即为最终源程序文档（`source.tex` / `LingXiAgent-V1.0-source-full.pdf`）中的实际装配顺序。所有文件保持内容完整、内部代码顺序完全不变，代码正文直接从原始仓库文件读取。

| 序号 | 源码文件相对路径 | 所属模块 | 代码行数 | 核心用途说明 | 第一方原创 |
| :---: | :--- | :---: | :---: | :--- | :---: |
| 1 | `Sources/LingXiCore/Modules/Agent/AgentRuntime.swift` | Agent Runtime | 817 | Agent 核心编排调度器，驱动推理决策、工具调用执行与多轮状态流转 | 是（100% 自主研发） |
| 2 | `Sources/LingXiCore/Modules/Agent/WorkflowRuntime.swift` | Agent Runtime | 224 | 工作流执行运行时，支持多阶段步骤调度与状态同频推进 | 是（100% 自主研发） |
| 3 | `Sources/LingXiCore/Modules/Agent/AgentInstructions.swift` | Agent Runtime | 183 | 动态指令构建器，装配系统提示词与上下文环境指引规范 | 是（100% 自主研发） |
| 4 | `Sources/LingXiCore/Modules/Agent/AgentRunRuntime.swift` | Agent Runtime | 142 | 单次执行运行期状态控制，管理运行状态机生命周期与异常恢复 | 是（100% 自主研发） |
| 5 | `Sources/LingXiCore/Modules/Agent/SubagentToolService.swift` | Agent Runtime | 140 | 子智能体调度服务，实现任务分发委托与子智能体协同调度 | 是（100% 自主研发） |
| 6 | `Sources/LingXiCore/Modules/Context/L1ContextEngine.swift` | Context Engine | 279 | L1 Hot Working Set 物理推理工作集引擎，负责活跃上下文预算与软限制防爆 | 是（100% 自主研发） |
| 7 | `Sources/LingXiCore/Modules/Context/L2WorkingSetPolicy.swift` | Context Engine | 48 | L2 Warm Cache 内存待命池管理与置换淘汰策略 | 是（100% 自主研发） |
| 8 | `Sources/LingXiCore/Modules/Context/ContextCacheController.swift` | Context Engine | 940 | 上下文缓存控制器，实现服务端 Prompt Cache 命中率最优化调度 | 是（100% 自主研发） |
| 9 | `Sources/LingXiCore/Modules/Context/CacheAwareContextScheduler.swift` | Context Engine | 177 | 缓存感知上下文调度器，动态平衡模型推理命中率与上下文配额 | 是（100% 自主研发） |
| 10 | `Sources/LingXiCore/Modules/Context/ContextCompaction.swift` | Context Engine | 508 | 高水位上下文智能压缩摘要引擎，防止上下文爆炸与注意力迷航 | 是（100% 自主研发） |
| 11 | `Sources/LingXiCore/Modules/Context/ContextPager.swift` | Context Engine | 414 | 上下文页面切片与多级分页器，实现细粒度上下文动态装卸 | 是（100% 自主研发） |
| 12 | `Sources/LingXiCore/Modules/Context/ContextPageRankingPolicy.swift` | Context Engine | 95 | 上下文页面热度评分与加权召回优先级排序算法 | 是（100% 自主研发） |
| 13 | `Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift` | Context Engine | 404 | E-Core 异构执行存储对象池总线，旁路沉淀 >10KB 大工具产物 | 是（100% 自主研发） |
| 14 | `Sources/LingXiCore/Modules/Context/ProjectContextDomain.swift` | Context Engine | 345 | 工作区项目级上下文实体与领域数据模型 | 是（100% 自主研发） |
| 15 | `Sources/LingXiCore/Modules/Context/ProjectPageStore.swift` | Context Engine | 322 | 项目级代码页缓存存储与局部热索引 | 是（100% 自主研发） |
| 16 | `Sources/LingXiCore/Modules/Context/ProjectScanner.swift` | Context Engine | 155 | 工作区目录结构智能扫描与关键上下文发现 | 是（100% 自主研发） |
| 17 | `Sources/LingXiCore/Modules/Context/ContextProjection.swift` | Context Engine | 152 | 上下文领域模型向大模型原生请求帧的投影转换 | 是（100% 自主研发） |
| 18 | `Sources/LingXiCore/Modules/Context/ContextQuery.swift` | Context Engine | 59 | 上下文多维检索查询定义与过滤语法支持 | 是（100% 自主研发） |
| 19 | `Sources/LingXiCore/Modules/Context/SensitivePathPolicy.swift` | Context Engine | 34 | 敏感文件与路径过滤策略，防止工程凭据与私有信息外泄 | 是（100% 自主研发） |
| 20 | `Sources/LingXiCore/Modules/Session/SessionRuntime.swift` | Session Runtime | 1637 | 会话权威生命周期管理、事件日志投递与状态机调度 | 是（100% 自主研发） |
| 21 | `Sources/LingXiCore/Modules/Session/SessionTurnCoordinator.swift` | Session Runtime | 777 | 会话轮次协调器，保证消息有序派发与端到端流式同步 | 是（100% 自主研发） |
| 22 | `Sources/LingXiCore/Modules/Session/SessionStore.swift` | Session Runtime | 259 | 会话历史持久化读写抽象与快照同步 | 是（100% 自主研发） |
| 23 | `Sources/LingXiCore/Modules/Session/SessionDomain.swift` | Session Runtime | 149 | 会话领域模型定义（Session、Turn、Item 实体契约） | 是（100% 自主研发） |
| 24 | `Sources/LingXiCore/Modules/Session/RunLease.swift` | Session Runtime | 66 | 轮次独占租约机制，防止并发会话写入冲突与状态污染 | 是（100% 自主研发） |
| 25 | `Sources/LingXiCore/Modules/Session/SessionMutationLock.swift` | Session Runtime | 33 | 会话状态原子读写锁，保障多任务访问一致性 | 是（100% 自主研发） |
| 26 | `Sources/LingXiCore/Modules/Tool/ToolRuntime.swift` | Tool Runtime | 928 | 工具执行核心运行时，负责沙箱环境适配、超时看门狗与输入安全过滤 | 是（100% 自主研发） |
| 27 | `Sources/LingXiCore/Modules/Tool/BuiltinTools.swift` | Tool Runtime | 1654 | 核心内置工具集（文件查看、编辑、Shell 隔离执行、代码检索等） | 是（100% 自主研发） |
| 28 | `Sources/LingXiCore/Modules/Tool/WebTools.swift` | Tool Runtime | 160 | 网络检索与网页内容安全提取工具实现 | 是（100% 自主研发） |
| 29 | `Sources/LingXiCore/Modules/Tool/ToolMutationCoordinator.swift` | Tool Runtime | 54 | 工具副作用协调器，统一文件修改、备份与快照隔离 | 是（100% 自主研发） |
| 30 | `Sources/LingXiCore/Modules/Tool/ToolOutputArchive.swift` | Tool Runtime | 22 | 大工具执行结果归档元数据契约 | 是（100% 自主研发） |
| 31 | `Sources/LingXiCore/Modules/Tool/ToolOutputPolicy.swift` | Tool Runtime | 20 | 工具输出截断策略与体积限制约束 | 是（100% 自主研发） |
| 32 | `Sources/LingXiCore/Modules/MCP/MCPRuntime.swift` | MCP Runtime | 526 | Model Context Protocol 协议运行时，负责外部工具自发现与动态绑定 | 是（100% 自主研发） |
| 33 | `Sources/LingXiCore/Modules/MCP/MCPTransport.swift` | MCP Runtime | 430 | MCP 通信传输层，支持 Stdio 管道与 Streamable HTTP 协议双通道 | 是（100% 自主研发） |
| 34 | `Sources/LingXiCore/Modules/MCP/MCPOAuthClient.swift` | MCP Runtime | 400 | MCP 服务的 RFC 9728 & RFC 8414 OAuth 2.1 浏览器本地回送授权客户端 | 是（100% 自主研发） |
| 35 | `Sources/LingXiCore/Infrastructure/Persistence/SQLitePersistenceStore.swift` | Persistence | 805 | 基于 SQLite 的权威数据持久化底层实现与事务并发隔离 | 是（100% 自主研发） |
| 36 | `Sources/LingXiCore/Infrastructure/Persistence/ProjectPersistenceDomain.swift` | Persistence | 129 | 工作区持久化领域数据模型与序列化映射 | 是（100% 自主研发） |
| 37 | `Sources/LingXiCore/Infrastructure/Persistence/MigrationRunner.swift` | Persistence | 46 | 数据库表结构版本迁移执行器与平滑升级 | 是（100% 自主研发） |
| 38 | `Sources/LingXiCore/Infrastructure/EventLog/EventLogStore.swift` | EventLog | 482 | 统一事件日志追加存储，提供细粒度可审计追踪流 | 是（100% 自主研发） |
| 39 | `Sources/LingXiCore/Infrastructure/EventLog/DurableCommandWAL.swift` | EventLog | 189 | 预写日志（Write-Ahead Logging）持久化存储，保障异常崩溃快速恢复 | 是（100% 自主研发） |
| 40 | `Sources/LingXiCore/Modules/Model/ModelGateway.swift` | Model Gateway | 433 | 多模型统一网关总线，负责模型路由寻址、能力降级与健康检查 | 是（100% 自主研发） |
| 41 | `Sources/LingXiCore/Modules/Model/ModelDomain.swift` | Model Gateway | 503 | 模型层领域实体契约（请求/响应模型、Token 计量体系） | 是（100% 自主研发） |
| 42 | `Sources/LingXiCore/Modules/Model/ModelProvider.swift` | Model Gateway | 16 | 模型服务提供商标准协议接口定义 | 是（100% 自主研发） |
| 43 | `Sources/LingXiCore/Modules/Model/OpenAICompatibleProvider.swift` | Model Gateway | 859 | 通用 OpenAI 兼容协议适配提供商实现 | 是（100% 自主研发） |
| 44 | `Sources/LingXiCore/Modules/Model/OpenAIResponsesProvider.swift` | Model Gateway | 725 | OpenAI Responses 原生协议适配驱动实现 | 是（100% 自主研发） |
| 45 | `Sources/LingXiCore/Modules/Model/AnthropicMessagesProvider.swift` | Model Gateway | 387 | Anthropic Messages 协议适配驱动实现 | 是（100% 自主研发） |
| 46 | `Sources/LingXiCore/Modules/Model/ProviderRateScheduler.swift` | Model Gateway | 265 | 上游 API 速率限制（Rate Limit）智能退避与队列调度器 | 是（100% 自主研发） |
| 47 | `Sources/LingXiCore/Modules/Model/ProviderErrorClassifier.swift` | Model Gateway | 609 | 大模型网络错误与重试熔断分类器 | 是（100% 自主研发） |
| 48 | `Sources/LingXiCore/Modules/Model/ProviderConfig.swift` | Model Gateway | 166 | 模型端点与网络连接配置实体 | 是（100% 自主研发） |
| 49 | `Sources/LingXiCore/Modules/Model/ProviderHTTPTransport.swift` | Model Gateway | 112 | 原生 HTTP 通信底层传输与流式数据流通道 | 是（100% 自主研发） |
| 50 | `Sources/LingXiCore/Modules/Model/ProviderActivityRegistry.swift` | Model Gateway | 111 | 模型推理活跃度指标遥测与性能统计 | 是（100% 自主研发） |
| 51 | `Sources/LingXiCore/Modules/Model/ProviderProvenance.swift` | Model Gateway | 108 | 模型推理来源指纹与链路追踪 | 是（100% 自主研发） |
| 52 | `Sources/LingXiCore/Modules/Model/CanonicalCachePlan.swift` | Model Gateway | 85 | 模型服务侧 Prompt Cache 结构规范化构建方案 | 是（100% 自主研发） |
| 53 | `Sources/LingXiCore/Modules/Model/SSEDecoder.swift` | Model Gateway | 48 | Server-Sent Events 流式事件增量解码器 | 是（100% 自主研发） |

---

## 4. 筛选原则与合规声明

1. **第一方原创性**：本清单所列全部 53 个源码文件，均为项目团队自主架构设计与编写的原生 Swift 源码，完全属于第一方原创代码，不存在侵犯第三方知识产权的情形。
2. **排除非核心与派生内容**：已严格排除单元测试代码（`Tests/`）、构建缓存（`.build/`）、外部包依赖、自动生成文件、JSON 纯配置/数据、模板代码及第三方 Shim 代码。
3. **架构代表性**：优先纳入能够体现 LingXiAgent 异构双核（P-Core/E-Core）、三级上下文缓存（L1/L2/L3）、自主决策闭环、沙箱安全防护与统一网关的核心技术实现。
4. **机密与隐私安全**：经代码静态安全性审查，全部纳入源码中均不含任何硬编码 API Key、访问令牌（Token）、密码私钥或用户私人绝对路径。
