# LingXiAgent 2.0 插件系统设计与 `.lxap` 契约

依据：项目书 §3.2（插件系统）、§3.3（官方插件生态）、§五.3–4、§七第 2–5 条。
运行载体已由主人拍板：**子进程 / IPC 隔离**。本文不讨论 dlopen 与编译期注册方案。

## 一、插件是什么

插件是运行在独立子进程、通过 `.lxap` 包分发、向内核注册能力的组件。官方插件与社区插件遵循完全相同的契约（项目书 §3.2）。

一个插件可以注册四类能力，缺省为零：

| 类别 | 含义 | 内核如何使用 |
|---|---|---|
| `provider` | 模型提供商与模型清单 | Agent Loop 的模型请求端口路由到它 |
| `tool` | 工具及其 JSON Schema | 进入工具清单，模型可调用 |
| `service` | 供其他插件或前端调用的服务 | 内核只做寻址与权限校验，不解释语义 |
| `hook` / `event` | 参与生命周期节点、发布事件 | 内核在指定节点调用，接受其类型化返回 |

内核侧**不允许**存在任何只有官方插件能用的注册面。1.x 的缺口正好在这里：插件注册面只有 tool/command/hook，provider 与 service 完全没有注册通道，且 `executePluginTool` 无调用方导致插件工具永不被模型调用（PLG-007）。2.0 阶段 2 的验收要求"不修改、不重编内核即可安装并切换 Provider"，因此 provider 注册面必须是第一批实现的内容。

## 二、`.lxap` 包格式

`.lxap` 是一个可校验归档，固定布局：

```
LingXiProviderAnthropic-1.2.0.lxap
├── plugin.json            必需，manifest（唯一身份与声明来源）
├── LICENSE                必需
├── README.md              必需，含安装后使用说明
├── bin/
│   └── arm64-apple-macos/<executable>   入口可执行文件
├── share/                 可选，静态资源、schema、图标
└── METADATA/
    ├── checksum           包内文件摘要清单
    └── signature           detached 签名
```

约束：

- 现阶段只接受 `arm64-apple-macos` 一个入口目录；出现其他平台目录视为打包错误（项目书 §四不做跨平台）。
- 入口必须是自包含可执行文件或带完整依赖的 bundle，不假设插件运行环境里有解释器。**官方插件统一用 Swift 编写**（与内核同工具链，无额外运行时）；社区插件按契约实现，语言不限——这是选择 JSON-RPC over stdio 的直接回报。
- 禁止在包内放置安装脚本或让包触发任何网络安装动作。

### 2.1 manifest 字段

```jsonc
{
  "id": "site.lingxi.provider.anthropic",     // 反向域名，全局唯一，注册面命名空间前缀
  "name": "Anthropic Provider",
  "author": "LingXiFox",
  "version": "1.2.0",
  "homepage": "...",
  "description": "...",
  "ipc": { "major": 1, "minor": 0 },          // 插件实现的协议版本
  "minimumCoreVersion": "2.0.0",              // 仅人类提示，不参与判定
  "entrypoint": "bin/arm64-apple-macos/anthropic-provider",
  "capabilities": {                           // 必须显式声明，无默认值（PLG-009）
    "providers": [{ "id": "anthropic", "models": ["...", "..."] }],
    "tools":     [{ "id": "read_file", "schema": "share/read_file.json" }],
    "services":  [],
    "hooks":     [{ "point": "beforeModelRequest", "mode": "observe" }]
  },
  "permissions": {                            // 见第八章
    "network": ["api.anthropic.com"],
    "filesystem": [{ "scope": "workspace", "access": "read" }],
    "credentials": ["anthropic-api-key"],
    "subprocess": false
  },
  "depends":   [{ "id": "site.lingxi.core", "ipc": ">=1.0 <2.0" }],
  "conflicts": [{ "id": "site.lingxi.provider.anthropic-beta", "reason": "重复注册 anthropic" }]
}
```

- `id` 一旦发布不可更改；变更等于发布新插件。所有注册到内核的能力 id 一律带插件 `id` 前缀，防碰撞。
- **能力必须挣得**：`capabilities` 与 `permissions` 都无默认值，声明结构缺少字段时解码失败而不是补默认。1.x 的 `RuntimeCapabilities`  initializer 去掉默认参数使"不显式声明就不编译"，这条纪律要在插件 manifest 上用等价手段（严格解码 + 契约测试）复现（PLG-009）。
- 声明与实际行为的可核对性：内核在运行期记录插件实际发起的网络目的地、文件访问与凭据读取，与声明比对；越界即按权限违规处理。没有这一条，manifest 就退化成 1.x 的 quirk 字符串表——35 种 quirk 里运行时只读 1 条，其余只是文档（E-06）。

## 三、生命周期状态机

```
uninstalled → installed → enabling → running(ready)
                                   ↘ degraded(部分能力不可用)
                                   ↘ failed(熔断打开)
        running → disabling → disabled → uninstalled
```

- **registry 是唯一真相源**（PLG-001、E-12）。启停、故障、版本、授权决定全部落在 registry；插件目录扫描只用于发现未注册包。1.x 的 `discoverAndStartAll` 纯扫目录可执行文件且完全不查 `registry.enabled`，`configureExtension` 是硬编码 `enabled:true` 的假接口，前端命令表只增不减——三处各管一半，结果是禁用后命令残留、进程照拉起。这条必须在设计期闭环。
- `disabled` 必须是零残留状态：进程被杀、路由表被清、租约被撤、前端注册被通知撤销（第五章流程）。
- `failed` 与 `disabled` 严格区分：前者由内核因故障判定并保留恢复可能，后者由用户判定。

## 四、进程模型

每个插件一个常驻子进程实例（D-P1），由宿主监管者拉起与回收。

- **启动前**：构造严格 allow-list 的环境（第八章），准备 stdout/stdin 管道，stderr 接有界环形缓冲。
- **握手**：`initialize` 必须返回身份、实现的协议版本、能力清单。握手有独立超时（短）。**握手失败必须命名到底哪个能力不可用**，不得只报裸 transport 错误（IPC-009）。
- **就绪**：能力进入路由表，前端可见。
- **运行**：请求-响应与事件流复用同一对管道（不新开第二条管）。
- **退出**：`shutdown` 通知 → 宽限期 → 终止进程树。

必须内建的工程纪律（全部来自 1.x 实修记录，实现期再补代价极高）：

| 项 | 要求 | 证据 |
|---|---|---|
| 管道读取 | 专用线程/专用调度，不占协作线程池 worker；非阻塞逐行读 | IPC-008 |
| EOF 判定 | 关闭父端写柄使 EOF 成立；且**只有进程确实退出后才算 EOF**，否则子进程写完即退会丢最后一行 stdout | IPC-001、010 |
| stderr | 必须持续排空进有界环形缓冲（默认 256KB，丢最旧），不排空会死锁子进程 | IPC-002 |
| 帧大小 | 上行帧有硬上限（32MB），超限拒收并计入故障 | IPC-006 |
| 事件采集 | 单条长驻 pump 做路由，取值处轮询采集；禁止对流的 `next()` 逐次 cancel 轮询（会吞事件） | IPC-005 |
| 进程回收 | 统一进程树级联杀，父进程退出时不得遗留插件进程 | IPC-007 |
| 挂起请求 | 看门狗断开时 `deinit` 必须 resume 全部 pending | IPC-004 |

1.x 的 `PluginProcessHost` 是**同步串行一问一答**（非 JSON-RPC，无并发路由、无流式、无心跳、无重启退避，崩溃检测靠下次调用 `isRunning`），已判定应废弃重设计，只保留其握手语义。底座改用 1.x `LingXiPlatform/IPC` 那套分层实现（`ManagedProcess` + `StdioTransport` + `StderrRingBuffer` + `LineDelimitedJSONFramer` + `JSONRPCPeer`），它是 1.x 唯一真做过 JSON-RPC 2.0 的栈；`Sidecars/browser-host` 的长连接 sidecar 是最合适的模板（协议版本与模式强校验、per-method 超时、stderr 尾部诊断、环境白名单）。

## 五、能力注册、增量变更与撤销

- 握手只回身份与版本；能力通过独立方法 `capability.list` 获取，并允许运行期通过 `capability.changed` 通知**增量声明或撤回**（PLG-002）。1.x 只在握手一次性上报，导致插件无法动态失效——这条是设计期就要定的差异。
- 内核维护三张路由表：provider 路由、tool 路由、service 路由，加一张 hook 表。
- schema 变更等价于一次"撤回 + 重新声明"，且必须与内核的 epoch 规则联动（`Kernel-Design.md` 第八章第 2 条）：同一 epoch 内工具清单只单调追加，因此插件的 schema 变更要显式推进 epoch，否则请求被拒。
- **撤销用租约模型**：每个已声明的能力持有租约，状态 `armed / used / expired / revoked`。这是 1.x 唯一做对的撤销样板（MCP 侧），照抄语义。
- 禁用流程（顺序固定，一步失败都要继续走完并记录）：

```
1. registry 标记 disabling（前端立即可见"正在关闭"）
2. 撤下三张路由表中的该插件条目 → 新的模型请求不再看到其工具/Provider
3. 等待在途请求收敛（宽限期），未收敛者按取消处理
4. 撤销租约为 revoked
5. 关闭其持有的事件流与 Hook 挂载
6. 终止进程树，回收归属它的后台子进程
7. 通知前端 unregister（前端命令表必须可减）
8. registry 标记 disabled，落盘
```

判定标准即项目书 §七第 3 条后半句："禁用后对应能力正确消失"，可验证为：禁用后模型请求的工具清单不含该工具、调用该工具的请求返回明确未注册错误、`ps` 无残留进程、前端命令面板无残留项。

## 六、故障分类与隔离

插件侧错误必须落进封闭分类，内核据此决定恢复动作。**"慢"与"死"必须可区分**（IPC-004、PLG-004）：

| 分类 | 判定 | 恢复动作 |
|---|---|---|
| `unresponsive` | 空闲沉默超阈值，但进程存活 | 发取消 → 仍沉默则升级 |
| `crashed` | `terminationHandler` 触发，携带退出码/信号/stderr 尾部 | 结构化故障上报 + 熔断计数 |
| `protocolViolation` | 帧超限、JSON 非法、未知方法、能力越界、声明外访问 | 立即隔离并标 `failed`，不重启重试 |
| `capabilityFailed` | 单次调用返回业务失败 | 原样回传给该 Run，Turn 按内核规则终止 |
| `timeout` | 单次调用超其声明的 per-method 超时 | 取消 + 记故障 |
| `permissionViolation` | 越出 manifest 声明的权限 | 终止进程 + 标 `failed` + 前端告警 |

隔离要求：

- 崩溃检测必须靠 `terminationHandler`，不是"下次调用时看 `isRunning`"。1.x 无 `terminationHandler`、无重启退避、无熔断计数，一次超时即 `terminate()` 判死整个 host，且此后静默失能（PLG-005）。
- 熔断 + 指数退避重启：连续故障累计超阈值即标 `failed` 并从 registry 撤销路由，重启退避有上限；恢复由用户显式触发或下一次能力清单变更触发。
- 单插件故障**不得**导致内核、前端或其他插件崩溃：故障在宿主侧合成后，以明确的 `capabilityFailed`/`crashed` 错误回传给受影响的那个 Run，让任务收到可预期错误并走恢复流程（项目书 §3.2、§七第 5 条）。
- 崩溃发生在批次中间 → 走内核恢复矩阵（`Kernel-Design.md` 第六章）：只读项可重跑，可变项记 `executionStateUnknown`，绝不自动重放写操作。
- L2 契约层必须有"假插件子进程"的六种异常注入：崩溃、超时、坏 JSON、无应答、泄漏凭据、继承 env——这一层是项目书"插件异常"验收的家（QA-005 关联）。1.x 已有 643 行的 `FaultInjectingTransport`，做插件版时以其为蓝本。

## 七、Hook 与生命周期扩展点

这是项目书 §七第 4 条"Hook 真正有效"的落点，也是 1.x 的完整死路（E-09）：`PluginHookEvent`、`ExtensionHookEvent`、SDK 的 `PluginContext.on`、握手 `supportedHooks`、`executeHooks` 全套类型都在，但 `broadcastHook` 与 `ExtensionPlatform.emit` 在生产代码**零调用方**，且 `emit` 只回收诊断结构、handler 无返回值，因此即便接线也只能监听、不能改写执行流（PLG-006）。

2.0 的设计约束：

1. **每个 Hook 点必须有类型化返回**，且返回能改变执行：可注入内容、可改写请求或结果、可否决（veto）并给出原因、可要求人工确认。只有诊断返回值的 Hook 不算扩展点。
2. 节点清单（首发只开这五个，宁少勿多）：

| 节点 | 时机 | 可做的动作 |
|---|---|---|
| `onContextPrepare` | 上下文装配完成、发请求前 | 追加数据通道内容（禁改指令通道）、否决请求 |
| `beforeModelRequest` | 单次模型请求发出前 | 改写允许字段（采样参数等）、注入标签、否决 |
| `afterModelEvent` | 流事件转发给内核状态机前 | 观察、标注；不得吞掉终态事件 |
| `beforeToolExecute` | 工具批次内单调用执行前 | 批准/否决/改写参数/要求人工确认 |
| `afterToolExecute` | 结果定型并落盘前 | 补充证据字段、标注失败上下文；不得替换载荷真值 |

3. `mode` 区分 `observe` 与 `intercept`；只有声明 `intercept` 的 Hook 才被等待返回。
4. 每个 Hook 有独立超时与失败策略（`failOpen` / `failClosed`，由挂载方在声明时选定，缺省 `failOpen`）；Hook 插件超时或崩溃时降级为跳过 + 诊断，**永不带崩 Run**，也不得让取消被挂住。
5. 顺序与优先级显式声明，同优先级按插件 id 稳定排序，禁止依赖注册先后这类不可复现顺序。
6. Hook 注入的一切文本走数据通道，进不了指令位置（`Kernel-Design.md` 第八章第 1 条）。
7. 事件（`event`）是单向广播，与 Hook 分开；事件不参与终止判定，不能改写执行。

## 八、权限模型与凭据

- **凭据由内核保管**。Provider 插件不持有 API key 本体：插件在需要时以内核授予的受限引用取用，内核记录取用行为并与 manifest 声明比对（PLG-008）。
- 子进程环境是**严格 allow-list**，不是"从继承环境里剔除敏感项"。必须有 sentinel 探针测试证明 passphrase 与 `*_API_KEY` 进不了子进程，同时 `PATH`/`HOME` 仍存活。1.x 的做法正确但收口不完整——MCP 侧当时明确留手未收，成为遗留泄漏点（E-07）。
- 权限声明在包内（manifest）、授权在运行期（用户确认 + 内核 `PermissionEngine` 预审）、审计在事后（实际行为比对）。
- **不承诺"沙箱"**。在真正把 macOS 沙箱机制接到插件进程之前，只说"进程隔离 + 权限声明 + 行为审计"。1.x 插件 SDK 的 README 已就此诚实说明，2.0 继承这句实话。
- 敏感操作确认与执行边界由内核保留，不因插件开放而稀释（项目书 §3.2 末段）。

## 九、协议契约（IPC）

- 传输：stdio，换行分隔 JSON（`LineDelimitedJSONFramer`），UTF-8，帧上限 32MB。
- 语义：JSON-RPC 2.0 子集 + 约定扩展。带 `id` 为请求、无 `id` 为通知；响应按 `id` 路由回挂起请求，因此**必须支持并发多路**，不得退回串行。
- 流式：一次长任务的事件流用 `streamId` 多路复用，靠通知推送，`$/streamEnd` 或终态事件收尾；背压由内核侧消费速率决定，插件侧缓冲区有界，溢出报 `unresponsive` 而不是无限增长。
- 取消：内核发 `$/cancel(streamId|requestId)`，插件必须在宽限期内停手并结束流；未停则升级 kill 进程树。**取消不得被伪装成业务失败**（`Kernel-Design.md` 第七章）。
- 心跳：内核可发 `$/ping`；心跳只刷空闲看门狗，不进入模型与前端可见事件。
- 超时：握手超时（短、固定）、per-method 调用超时（插件声明能力时可带默认值，内核可收紧）、空闲沉默超时。全部 silence-bound。
- 前向兼容：上游/插件送回内核**不认识**的枚举值必须降级为 `.unknown` 而不抛异常；不认识的可选字段忽略；不认识的必选方法报 `methodNotFound` 并计入协议违规（PLG-010）。1.x 的 `EnumDecoderRobustnessTests` 是现成门禁。
- 版本协商：`initialize` 交换整数 `major` + `minor`（1.x `PluginIPC.supportedVersions` 的思路可保留）。major 不匹配直接拒绝加载并报明确错误；minor 按能力位取交集。**未知协议一律硬失败，绝不静默 fallback**（E-06）。`minimumCoreVersion` 字符串永远只做人类提示。
- 契约完整性：协议公开类型若无生产者或消费者，CI 失败（QA-006）。这条是防 2.0 重演"hook 全套类型都在但无人调用"的唯一有效手段。

## 十、发现、安装与更新

- 安装：校验签名与 checksum → 解析 manifest → 冲突检测（同 `id` 不同版本、同 provider id 重复注册）→ 写入 registry（默认 `installed` 且未启用）→ 首次启用时才展示权限确认。
- 更新：新进程新实例，旧实例按第五章禁用流程彻底下线后再拉起新版；不允许同一 `id` 两个版本同时持有路由。
- 卸载：先禁用流程，再删包与 registry 条目；插件产生的持久化数据归属内核存储域，卸载不自动清除，需显式操作。
- 启停、故障、权限、版本信息必须在前端可见可管理（项目书 §3.5、§3.2），协议面阶段 2 就准备好，不等阶段 4。

## 十一、官方插件质量标准

社区按同一规则开发，因此标准要写成可核对清单（详细 Provider 侧清单见 `Provider-Plugin-Contract.md` 第六章）：

1. manifest 完整、无默认值兜底、能力与实际行为一致。
2. 所有 IPC 异常路径自己先测过：崩溃、挂死、坏帧、越权、泄漏 env。
3. 禁用后零残留（第五章判定四条件全过）。
4. 不参与终止判定、不写指令通道、不伪造终态。
5. 有 README（安装、权限说明、故障排查）与 LICENSE。
6. 版本语义遵守兼容规则；破坏性变更改 `id` 或提 major。

## 十二、决策与待决

| ID | 决定 | 理由 | 可逆性 |
|---|---|---|---|
| D-P1 | 每插件单常驻进程 | 撤销语义可证；避免多实例路由与租约爆炸 | 中 |
| D-P2 | JSON-RPC 2.0 over 换行分隔 JSON，单管双工多路复用 | 并发与流式无法后补，必须设计期定（E-08） | 低 |
| D-P3 | 官方插件用 Swift，契约语言不限 | 同工具链零额外运行时；JSON-RPC 保证第三方自由 | 高 |
| D-P4 | 凭据由内核保管，插件取受限引用 | 消除"sidecar 继承全部 key"这类泄漏面 | 中 |
| Q-P1 | 签名机制用什么（自签 + 本机信任链，还是接入系统签名） | 涉及发布流程，需主人定 | — |
| Q-P2 | 是否首发就把 macOS 沙箱接到插件进程 | 若承诺隔离则需要；工作量与风险都要单独评估 | — |
| Q-P3 | `service` 注册面的首批具体服务（除 provider/tool/hook 外是否真有需要） | 避免造无消费者的通道（QA-006） | — |
