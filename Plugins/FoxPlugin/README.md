# FoxPlugin — LingXiAgent 官方参考插件

> LingXi 插件 SDK 的第一方消费者与端到端参考实现：演示进程隔离的插件模型、Core 推送的只读运行时快照、弹出式 TUI 命令与模型自主工具。

它是「第三方怎么写插件」这条路径的活样本：与本仓库其它 target 不同，FoxPlugin **不链接
LingXiCore**，而是像任何外部作者一样，从公开 SwiftPM 包取依赖。

## 作为公共 SDK 的消费者

`Package.swift` 里 FoxPlugin 的依赖形态（与第三方 README 一字不差）：

```swift
.executableTarget(
    name: "FoxPlugin",
    dependencies: [
        .product(name: "LingXiPluginSDK", package: "LingXiPluginSDK")
    ]
)
```

```swift
import LingXiPluginSDK
```

SDK 本身住在 <https://github.com/LingXiFox/LingXiPluginSDK>（MIT）。本仓库通过
`.package(url: "https://github.com/LingXiFox/LingXiPluginSDK.git", from: "0.1.0")`
消费它 —— 没有仓库内副本，也没有 `path:` 依赖。SDK 一旦改坏公共 API，先在这里编译不过，
这正是它留作参考实现的意义。

## 目录结构

* `main.swift`：插件入口、清单声明、`/fox-info` 交互命令与 `fox_ping` 模型自主工具。

## 核心特性演示

1. **进程隔离**：插件是独立子进程，经 stdin/stdout 的 JSON Lines IPC 通信，不 `dlopen` 进宿主；
   子进程只拿到净化过的环境变量，不含 provider 凭据与保险箱口令。
   注意边界：这是进程隔离与能力审核，不是操作系统级沙箱 —— 声明能力（capability）是准入策略，
   不是内核强制。
2. **只读高维感知（`context.info`）**：所有值都来自 Core 推送的 `host.snapshot`，SDK 自己不测量、
   不猜测、不填默认值。Core 没发布的段落会抛 `PluginInfoUnavailable`，`/fox-info` 对应行显示
   「宿主未发布」。
   - `getWorkspaceInfo()`：工作区路径、Git 分支与未提交变更数、核心版本；
   - `getPECoreInfo()`：P-Core token 占用与 E-Core 对象/引用计数、思考深度、后台任务数；
   - `getContextState()`：会话消息数与上下文占用；
   - `getPerformanceInfo()`：耗时分解（Core 目前不发布该段落，因此它缺席，而不是 0 ms）。
3. **弹出式 TUI 呈现（`PluginPresentationStyle.modal`）**：`/fox-info` 以居中 Modal 呈现，
   支持键盘上下滚动与 <kbd>Esc</kbd> 退出。
4. **模型自主工具（`PluginTool`）**：`fox_ping` 供大模型在推理循环中自主调用。
   Tool 上下文只带 `sessionID` / `toolCallID` / `logger`；读宿主状态是 command 侧
   `CommandExecutionContext.info` 的职责。

## 编译与安装

在 LingXiAgent 仓库根目录下：

```bash
# 1. 编译 Release 产物
swift build -c release

# 2. 安装到插件目录（全局或工程级）
mkdir -p ~/.lingxiagent/plugins
cp .build/release/FoxPlugin ~/.lingxiagent/plugins/fox-plugin
chmod +x ~/.lingxiagent/plugins/fox-plugin

# 3. 启动客户端体验
lingxi
# 敲 /plugins 查看插件状态，输入 /fox-info 查看弹出浮层
```

Windows 下产物名为 `FoxPlugin.exe`，复制方式相同；插件目录同样支持工程级
`<project>/.lingxi/plugins`。
