# LingXiAgent 后续开发任务规划

## Phase 1：基础架构

### 1. TUI 与 Core 解耦
进一步明确 Frontend、Application、Client、Protocol、Core 之间的边界。

- TUI 不直接依赖或启动 Core
- TUI 只通过 `LingXiApplication` 获取状态和提交 Action
- Core 生命周期和 Transport 由独立 Composition Root 管理
- 为未来 GUI、Web Client 等前端提供统一接口

### 2. 跨平台系统
将目前散落的 macOS / Darwin 专属实现集中到平台抽象层。

重点抽象：

- Process
- Shell
- Sandbox
- Browser
- Secure Storage
- Filesystem
- Terminal

目标支持：

- macOS
- Linux
- Windows

Linux 可优先适配，Windows 后续补齐专属实现。

### 3. 后台命令系统
建立统一的长期进程与后台任务管理能力。

主要能力：

- 启动后台进程
- 查询运行状态
- stdin 输入
- stdout / stderr 流式读取
- 停止 / 强制结束
- PID / Handle 管理
- 超时与资源清理

后续 LSP、ACP、Browser、Formatter 等功能都可以复用。

---

## Phase 2：扩展能力

### 4. 插件系统
建立正式的 LingXiAgent 扩展机制。

插件可扩展：

- Tool
- Command
- Provider
- Agent 行为
- Hook / Event

同时定义插件发现、加载、权限和生命周期机制。

### 5. 自定义命令
允许用户或插件注册自己的 `/command`。

支持：

- 全局命令
- 项目级命令
- 参数定义
- 命令描述
- 插件动态注册

可作为插件系统的第一批实际使用场景。

### 6. ACP 支持
增加 Agent Client Protocol 支持，使 LingXiAgent 可以和其他支持 ACP 的客户端或工具通信。

重点处理：

- Transport
- Session
- Streaming
- Tool Call
- 生命周期管理

### 7. LSP 服务器
集成 Language Server Protocol，为 Coding Agent 提供代码语义能力。

包括：

- Definition
- References
- Symbols
- Diagnostics
- Hover
- Completion

LSP Server 作为后台进程运行，由后台命令系统负责管理。

### 8. Formatter 格式化工具
参考 OpenCode Formatter 机制增加代码格式化支持。

根据语言自动调用：

- SwiftFormat
- Prettier
- Ruff
- gofmt
- clang-format
- 其他 Formatter

支持项目配置和插件扩展。

### 9. Codebase 代码图索引
建立代码结构和依赖关系索引，降低 Agent 每次重新搜索代码库的 Token 与时间消耗。

主要索引：

- 文件
- Symbol
- Definition
- Reference
- Import
- Dependency
- Call Graph

可以结合 LSP 提供的数据建立代码图。

---

## Phase 3：Agent 能力

### 10. `/goal` 系统
增加长期目标管理能力。

允许 Agent：

- 创建 Goal
- 拆分子目标
- 跟踪完成状态
- 与 Session / Task 关联
- 在多轮任务中持续推进目标

### 11. Chrome Browser Use
优先实现浏览器级 Computer Use。

主要能力：

- 页面导航
- DOM 读取
- 点击 / 输入
- Screenshot
- Tab 管理
- 下载 / 上传
- 浏览器状态读取

相比完整 Computer Use，浏览器环境更稳定，也更容易跨平台。

### 12. Computer Use
在 Browser Use 成熟后扩展到完整桌面控制。

包括：

- Screenshot
- 鼠标
- 键盘
- 窗口管理
- 应用切换
- 屏幕坐标与视觉定位

需要分别处理 macOS、Windows、Linux 的系统接口和权限模型。

---

## Phase 4：交互体验

### 13. 快捷键系统
建立统一快捷键配置和 Action 映射。

要求：

- 快捷键只触发 `ApplicationAction`
- 支持用户自定义
- 支持不同 Frontend 使用不同默认键位
- 避免 TUI 快捷键逻辑直接耦合 Core

### 14. 主题系统
完善 TUI 的主题与视觉配置。

支持：

- 颜色主题
- 状态颜色
- Component Style
- 用户自定义 Theme
- 内置多套主题

在整体 UI 和架构稳定后再进行细节优化。

---

## 推荐开发顺序

```text
TUI/Core 解耦 ─────┐
                   ├─→ 后台命令系统
跨平台系统 ────────┘
                         ↓
                      插件系统
                         ↓
                      自定义命令
                         ↓
                ACP / LSP / Formatter
                         ↓
                   Codebase Index
                         ↓
                     /goal 系统
                         ↓
                  Chrome Browser Use
                         ↓
                    Computer Use
                         ↓
                   快捷键 / 主题
```

其中 **TUI/Core 解耦** 和 **跨平台系统** 可以并行开发，两者完成后再集中推进后续基础能力。