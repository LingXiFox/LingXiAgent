# FoxPlugin — 灵犀官方参考插件

> LingXiAgent 官方 Native Swift 插件范例，演示物理进程隔离、双核只读高维感知、弹出式 TUI 命令与模型自主工具扩展。

## 目录结构

* `main.swift`：完整的插件入口、清单声明、`/fox-info` 交互命令实现与 `fox_ping` 模型自主工具实现。

## 核心特性演示

1. **零共享内存的安全物理沙箱**：基于标准 IPC 管道通信，杜绝 `dlopen`，保障主进程凭据安全；
2. **只读高维系统感知 (`PluginInfoHub`)**：
   - `context.info.getPECoreInfo()`：获取 P-Core 与 E-Core 双核分工与耗时比；
   - `context.info.getContextState()`：获取当前会话的上下文容量与 Token 预算；
   - `context.info.getWorkspaceInfo()`：获取工作区与 Git 元数据；
   - `context.info.getPerformanceInfo()`：获取首字延迟（TTFT）与耗时分解；
3. **弹出式 TUI 呈现 (`PluginPresentationStyle.modal`)**：
   - 执行 `/fox-info` 时以独立居中 Modal 窗口呈现，支持键盘上下滚动与 <kbd>Esc</kbd> 退出；
4. **模型自主工具 (`PluginTool`)**：
   - 提供 `fox_ping` 工具，大模型在 ReAct 循环中可自主调用。

## 编译与安装

在 LingXiAgent 仓库根目录下：

```bash
# 1. 编译 Release 产物
swift build -c release

# 2. 安装到插件目录（全局或工程级）
mkdir -p ~/.lingxiagent/plugins
cp .build/release/FoxPlugin ~/.lingxiagent/plugins/fox-plugin
chmod +x ~/.lingxiagent/plugins/fox-plugin

# 3. 在终端中启动灵犀客户端体验
lingxi
# 敲击 /plugins 查看插件状态，输入 /fox-info 查看弹出浮层
```
