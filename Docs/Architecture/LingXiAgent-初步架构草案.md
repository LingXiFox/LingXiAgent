# LingXiAgent 初步完整架构草案

> 状态：0.2 初稿 / 架构方向讨论稿  
> 目标：先确定系统边界、模块职责与基本原则，不讨论具体代码实现、语言细节、数据库表结构或最终协议格式。  
> 说明：本文使用中文表达架构概念；MCP、Provider、Tool、API、SDK、IPC、SwiftUI、AppKit、PWA、Git、PTY、LSP 等专业名词保留英文。

---

## 1. 总体目标

LingXiAgent 不再以 OpenChamber 或 OpenCode 作为产品运行基础，而是从第一天起原生实现自己的 Core。

OpenChamber、OpenCode、Codex、Claude Code 等项目以后只作为：

- 架构参考
- 行为参考
- 设计取舍参考
- 已有实现经验参考

它们不进入 LingXiAgent 的运行依赖。

核心原则：

- **前端可以限定平台，后端 Core 必须跨平台**
- **macOS 前端优先使用 SwiftUI / AppKit，充分发挥 Apple 平台能力**
- **客户端与 Core 通过统一 LingXi Protocol 通信**
- **本地与远程只更换 Transport，不更换业务协议**
- **本地客户端不需要通过 localhost HTTP 访问 Core**
- **Core 从第一天起原生实现，不建立 OpenCode Adapter**
- **Core 内部永远不以 OpenAI API 格式作为领域模型**
- **Agent、上下文、Provider、Tool、MCP、会话等核心能力由 LingXi 自己拥有**
- **客户端负责表现与平台交互，Core 负责业务能力与状态权威**

---

## 2. 总体架构

```text
                    ┌──────────────────────┐
                    │ LingXiAgent macOS    │
                    │ SwiftUI / AppKit     │
                    └──────────┬───────────┘
                               │
                     LingXi ClientKit
                               │
                     本地 IPC Transport
                               │
                               ▼
┌─────────────────────────────────────────────────────┐
│                 LingXiAgent Core                    │
│                                                     │
│  会话引擎            Agent 编排器                    │
│  上下文引擎          模型网关                        │
│  Tool 运行时         权限引擎                        │
│  MCP 运行时          工作流引擎                      │
│  Usage 引擎          事件总线                        │
│  持久化层            Remote Gateway                 │
│  平台适配层                                         │
└─────────────────────────────────────────────────────┘
```

远程客户端：

```text
iPhone / iPad / Browser
        │
     Web / PWA
        │
   Remote Transport
        │
   LingXi Protocol
        │
   LingXiAgent Core
```

本地与远程使用相同业务协议。

区别只在 Transport：

```text
macOS
→ 本地 IPC Transport

Web / PWA
→ Remote Transport
```

---

## 3. LingXi Protocol

LingXi Protocol 是 Core 与所有客户端之间的统一业务协议。

它不绑定：

- SwiftUI
- HTTP
- WebSocket
- XPC
- Unix Socket
- Windows Named Pipe
- 任何特定 UI 框架

它只描述 LingXiAgent 的业务语义。

主要领域包括：

```text
Session
Message
Part
AgentState
ToolCall
Permission
Provider
Model
Usage
MCP
Workflow
Project
File
Git
Terminal
Remote
Event
```

以后：

- macOS
- Web / PWA
- Windows
- Linux
- CLI
- TUI

都可以建立在同一套 LingXi Protocol 上。

---

## 4. 会话引擎

会话引擎负责 LingXi 自己的会话模型与权威状态。

主要职责：

- Session 生命周期
- Message / Part 管理
- Agent 运行状态
- Tool 调用记录
- Reasoning / Streaming 状态
- Usage 关联
- Project / Workspace 绑定
- 会话恢复
- 会话事件
- 会话与工作流关联

原则：

```text
LingXi Session
就是 LingXi 自己的权威 Session
```

不存在：

```text
LingXi Session
↔
OpenCode Session
```

这样的长期映射关系。

OpenCode 的 Session / Message / Part 只作为研究参考，不进入 LingXiAgent 的产品数据模型。

---

## 5. Agent 编排器

Agent 编排器负责真正的 Agent 生命周期。

基本主链：

```text
Prompt
  ↓
上下文准备
  ↓
模型调用
  ↓
Tool Call
  ↓
权限判断
  ↓
Tool 执行
  ↓
结果回写
  ↓
继续推理 / 完成
```

主要职责：

- Agent step
- turn continuation
- stop / cancel
- retry
- error handling
- subagent
- Tool settlement
- Agent state
- 并发控制
- 可恢复执行
- 崩溃后的恢复策略

Agent 编排器只消费 LingXi 自己定义的：

```text
上下文
模型事件
Tool Call
Tool Result
权限结果
会话状态
```

不直接依赖具体 Provider 协议，也不直接依赖 UI。

---

## 6. 上下文引擎

运行时只有 P-Core 和 E-Core。

- P-Core：当前模型请求的活跃上下文，分为 stable prefix、growing context 和 E-Core index。
- E-Core：保存 page-out 的完整 Context Object；引用与载荷分离，按 referenceID 精确取回。
- 项目索引与查询缓存：帮助定位当前源码事实；不是额外的上下文核心，也不计入模型输入占用。

```text
真实 runtime context window
        ↓
唯一 EffectiveContextPolicy
        ↓
P-Core pressure → E-Core page-out
        ↑              ↓
        └── bounded reference restore
```

预算、请求规划、缓存控制器与前端快照必须来自同一个 runtime generation。
重复 native discovery 在输入不变时 NO-OP，不修改 cache epoch 和 stable prefix。
窗口缩小时复用现有 compaction / page-out 路径；增大时不主动展开全部历史。

---

## 7. 模型网关

模型网关不是“把所有 Provider 转成 OpenAI-compatible”。

LingXi 自己开发 Agent 后，需要真正理解和支持不同 Provider 的原生协议。

总体关系：

```text
                    Agent 编排器
                         │
                         ▼
                  LingXi 模型请求
                         │
                         ▼
                     模型网关
        ┌────────────────┼────────────────┐
        │                │                │
   OpenAI Adapter   Anthropic Adapter   Gemini Adapter
        │                │                │
        ▼                ▼                ▼
   原生请求格式       原生请求格式       原生请求格式
        │                │                │
        ▼                ▼                ▼
   原生 Streaming     原生 Streaming     原生 Streaming
        │                │                │
        └────────────────┼────────────────┘
                         ▼
                LingXi 标准模型事件流
                         │
                         ▼
                    Agent 编排器
```

### 模型网关主要职责

#### 1. 模型能力注册

描述：

- 文本
- 图像
- Tool Calling
- 并行 Tool Calling
- Reasoning
- Structured Output
- Prompt Cache
- System / Developer Message
- 文件输入
- Streaming
- Context Window
- Max Output

同时允许 Provider 保留独有能力。

#### 2. 请求转换

LingXi 内部拥有自己的模型请求模型，例如：

```text
System Context
Messages
Tools
Reasoning Policy
Generation Policy
Cache Policy
Attachments
```

Provider Adapter 再把它转换成各自原生协议。

#### 3. Streaming 归一化

不同 Provider 的 Streaming 事件统一转换为 LingXi 模型事件，例如：

```text
模型开始
文本增量
Reasoning 增量
Tool Call 开始
Tool 参数增量
Tool Call 完成
Usage
模型结束
Provider Error
```

Agent 编排器不直接消费 Provider 原生 Streaming。

#### 4. Tool 协议转换

模型网关负责：

- 将 LingXi Tool Definition 转成 Provider 原生 Tool Schema
- 将 Provider Tool Call 转成 LingXi Tool Call
- 将 LingXi Tool Result 转成 Provider 原生 Tool Result

Tool 如何真正执行，不属于模型网关。

#### 5. Provider 差异处理

包括：

- reasoning effort
- thinking budget
- cache control
- tool choice
- parallel tool calling
- structured output
- multimodal
- usage
- error
- retry
- authentication
- 模型列表
- Provider 特有参数

### 核心原则

- Agent 编排器不直接判断具体 Provider
- Core 内部不以 OpenAI API 格式作为领域模型
- 公共能力统一抽象
- Provider 独有能力允许扩展
- 不为了统一而削掉模型特性
- “支持一个 Provider”必须以完整 Agent 能力为标准，而不是仅能发起文本请求

后续需要单独制定 Provider 支持矩阵，再决定第一版正式支持哪些 Provider。

---

## 8. Tool 运行时

Tool 运行时负责：

> “这个 Tool 实际怎么执行。”

它不负责：

> “某个 Provider 如何表达 Tool。”

后者属于模型网关。

主要 Tool 类型可能包括：

```text
File
Shell
Git
Search
Edit
Patch
Task
LSP
Web
MCP Tool
未来自定义 Tool
```

主要职责：

- Tool Registry
- Tool Schema
- Executor
- Result
- Error
- Cancellation
- Lifecycle
- Durable Invocation
- 与权限引擎协作
- MCP Tool 接入

统一领域对象：

```text
LingXi Tool Definition
LingXi Tool Call
LingXi Tool Result
```

完整关系：

```text
Tool 运行时
      │
LingXi Tool Definition
      │
      ▼
模型网关
      │
Provider 原生 Tool Schema
      │
      ▼
Model
      │
Provider 原生 Tool Call
      │
      ▼
模型网关
      │
LingXi Tool Call
      │
      ▼
权限引擎
      │
      ▼
Tool 运行时
      │
LingXi Tool Result
      │
      ▼
模型网关
      │
Provider 原生 Tool Result
      │
      ▼
Model
```

核心原则：

> 模型网关负责“模型怎么看 Tool、怎么表达 Tool Call”。

> Tool 运行时负责“Tool 实际如何执行”。

---

## 9. 权限引擎

权限引擎独立于 Tool 运行时。

主要状态：

```text
allow
ask
deny
```

负责：

- per-agent policy
- per-tool policy
- resource / path rule
- 用户审批
- 持久化授权
- pending approval
- remote approval
- timeout / revoke
- crash recovery

目标是让权限成为 Core 的正式业务状态，而不是纯内存临时状态。

---

## 10. MCP 运行时

MCP 由 Core 管理 catalog、schema store、连接与工具 lease。
Session 和 project 的使用计数只是检索排序信号，不构成上下文分层。
只有当前 lease 所需的工具 schema 才进入模型请求；大载荷与历史工具观测进入 E-Core。
认证与权限属于正式运行时状态，沿用已有权限路径。

---

## 11. 工作流引擎

工作流引擎负责 LingXi 自己的开发与任务组织能力。

可以逐步承接：

- version lifecycle
- patch tree
- task graph
- plan
- workflow state
- merge / delete policy
- release lifecycle

以后 CLI、macOS UI、Web UI 都通过同一个工作流引擎。

---

## 12. Usage 引擎

Usage 不只是 UI 展示数据。

Core 应统一处理：

- input tokens
- output tokens
- reasoning tokens
- cache read
- cache write
- cost
- Provider quota
- Model / Provider / Session 维度统计

目标：

```text
Provider 原始 Usage
        ↓
Usage Normalize
        ↓
LingXi Usage Ledger
        ↓
Session / Provider / Model / 时间统计
```

失败请求、重试、partial usage 也应有明确处理语义。

---

## 13. 事件总线

Core 内部所有重要状态变化统一产生事件。

例如：

```text
session.created
session.updated

agent.running
agent.idle
agent.failed

message.updated
part.delta

tool.called
tool.completed
tool.failed

permission.asked
permission.replied

provider.error
usage.updated

mcp.connected
mcp.failed
```

事件总线服务于：

- Core 内部模块
- ClientKit
- Remote
- 状态恢复
- UI 实时更新

客户端不应直接观察内部对象，而应消费稳定状态与事件。

---

## 14. 持久化层

持久化层保存 Core 的权威状态。

主要包含：

- Session
- Message
- Part
- Event
- Agent state
- Tool invocation
- Permission
- Context metadata
- Workflow
- Usage
- Project
- Remote identity

目标是明确区分：

```text
Durable State
Ephemeral State
Client-only State
Platform State
```

外观、窗口位置、侧边栏展开状态等不应污染 Core 业务数据。

---

## 15. 平台适配层

Core 必须跨平台，因此 OS 能力通过平台适配层进入。

例如：

```text
Credential Store
├─ macOS Keychain
├─ Windows Credential Manager
└─ Linux Secret Service

Notification
├─ macOS
├─ Windows
└─ Linux

Process / PTY
Filesystem
Shell
Open URL
Native File Picker
```

Core 只依赖统一接口，不直接依赖 AppKit / SwiftUI / WinUI。

---

## 16. macOS Client

macOS 是当前唯一重点维护的桌面前端。

主要负责：

- SwiftUI / AppKit UI
- Liquid Glass 风格
- Window
- Sidebar
- Toolbar
- Settings
- Native Notification
- File Picker
- Menu
- Shortcut
- Keychain UI
- Updater UI
- 平台专用交互

原则：

> macOS Client 只负责“怎么展示与交互”，不负责 Agent 业务逻辑。

既然前端限定平台，就应尽量发挥 macOS 原生能力，而不是继续为了跨平台 UI 做妥协。

---

## 17. Web / PWA Client

Web / PWA 主要服务于：

- iPhone / iPad
- 远程控制
- 浏览器访问
- 未来跨平台轻客户端

优先能力：

- Session
- Chat
- Agent State
- Tool
- Diff
- Permission
- Workflow
- Usage
- MCP
- Git / Files
- Remote Control

它不要求完全复刻 macOS UI，而应针对移动与远程场景重新设计。

---

## 18. Remote Gateway

Remote Gateway 属于 Core 的远程访问边界。

主要负责：

- Host Identity
- Pairing
- Trusted Devices
- Token / Credential
- Revoke
- Discovery
- Reconnect
- Event Resume
- Secure Transport
- Remote Authorization

未来可选：

- LAN
- VPN
- Tunnel
- Relay
- E2EE

Remote Gateway 不改变 LingXi Protocol，只负责远程 Transport。

---

## 19. 原生实现原则

LingXiAgent 不建立 OpenCode Adapter，也不以 OpenCode Server 作为过渡运行时。

从第一版开始，核心链路直接属于 LingXi：

```text
创建 Session
    ↓
发送 Prompt
    ↓
构建 Context
    ↓
调用 Provider
    ↓
Streaming
    ↓
Tool Call
    ↓
Permission
    ↓
Tool Result
    ↓
继续推理
    ↓
完成
    ↓
持久化
```

OpenChamber、OpenCode、Codex、Claude Code 等只用于：

```text
研究已有实现
      ↓
理解设计取舍
      ↓
吸收值得借鉴的思想
      ↓
按 LingXi 自己的领域模型重新实现
```

不做：

```text
包装 OpenCode
兼容 OpenCode 数据结构
复制 OpenCode 生命周期
建立双重 Session
建立双重 Event
建立双重 Provider 状态
```

目标是避免为了过渡方案制造未来必须再次拆除的技术债。

---

## 20. 最终目标

最终架构：

```text
                   LingXiAgent macOS
                         │
                    ClientKit
                         │
                    本地 IPC
                         │
                         ▼
                 LingXiAgent Core
        ┌──────────────────────────────┐
        │ 会话引擎                     │
        │ Agent 编排器                 │
        │ 上下文引擎                   │
        │   PCore 会话活跃上下文          │
        │   RecallCache 项目热区缓存            │
        │   ProjectIndex 项目完整上下文          │
        │ 模型网关                     │
        │ Tool 运行时                  │
        │ 权限引擎                     │
        │ MCP 运行时                   │
        │   PCore 活跃 MCP                │
        │   RecallCache 会话常用 MCP            │
        │   ProjectIndex 静态 MCP                │
        │ 工作流引擎                   │
        │ Usage 引擎                   │
        │ 事件总线                     │
        │ 持久化层                     │
        │ Remote Gateway               │
        │ 平台适配层                   │
        └──────────────────────────────┘
                         ▲
                         │
                   Remote Transport
                         │
                    Web / PWA
```

在最终状态下：

```text
OpenChamber 仅作为历史与参考项目
OpenCode    仅作为参考实现
Electron    不再需要
```

---

## 21. 当前建议的架构边界

现阶段可把 LingXiAgent 看成几个顶层领域：

```text
LingXiAgent

Core
├─ 会话
├─ Agent
├─ 上下文
├─ 模型
├─ Tool
├─ 权限
├─ MCP
├─ 工作流
├─ Usage
├─ 事件
├─ 持久化
├─ Remote
└─ 平台适配

Protocol
└─ LingXi Protocol / SDK

Clients
├─ macOS
└─ Web / PWA

Provider Adapters
├─ 各 Provider 原生协议
└─ 后续按支持矩阵确定
```

这只是概念组织，不代表最终仓库目录。

---

## 22. 许可证方向

当前讨论方向：

```text
LingXiAgent Core
→ AGPL-3.0

LingXi Protocol / SDK
→ Apache-2.0

LingXiAgent macOS
→ Apache-2.0

LingXi Web / PWA
→ Apache-2.0
```

Core 保持强 copyleft，客户端与协议保持宽松，便于未来生态扩展。

---

## 23. 当前阶段

目前已经完成：

```text
OpenChamber 架构抽象
        ✓

OpenCode 架构抽象
        ✓

关键 Runtime UNKNOWN 补充验证
        ✓

LingXiAgent 初步架构
        ← 当前持续打磨
```

下一阶段不急于一次性进入完整实现。

优先继续打磨：

```text
1. Core 一级领域边界
2. 会话领域模型
3. Agent 生命周期
4. 上下文P/E-Core context
5. Provider 支持矩阵与模型网关
6. Tool / Permission / MCP
7. 事件与持久化
8. LingXi Protocol
9. 本地 IPC
10. Remote
11. macOS Client
```

这份文档目前只用于确定：

> “LingXiAgent 由哪些层组成，谁负责什么，以及哪些原则不能被后续实现破坏。”

具体实现方案后续逐章确定。
