# Windows 运行时依赖打包与 MSI 安装链路 ruling — 2026-10-02

状态：**已定论，代码未改**（主人指令：「你不修代码，你写文档」）。本文是后续修复打包 / CI / CD 的输入。

结论先放最前面：**1.1.0 的 Windows 产物在没有任何 Swift 环境的机器上根本起不来**，而 CI 的门全绿。这不是某个文件忘了拷，是**打包模型和验证模型同时错了**。下面三段分别对应：依赖从哪来、包怎么打、环境变量为什么"装了不生效"。

---

## 一、Swift 运行时是动态依赖，不是链接期细节

### 症状与判定方法

`C:\Users\hands\Desktop\lingxiagent-windows-x86_64` 里只有 4 个 exe + `sqlite3.dll`。用 `dumpbin` 对 4 个 exe 做递归依赖分析（工具：VS 18 Community 的 `VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\dumpbin.exe`）：

- 每个节点跑 `/dependents` 取直接导入，再跑 `/imports` 收 `DLL Name:` 以覆盖延迟加载表；
- **每个 exe 独立 BFS**，只共享 dumpbin 结果缓存。共享 visited 集合会把后几个 exe 的闭包人为压平（本狐第一版就这么错过，`LingXiTUI.exe` 的 maxdepth 被压成 1）；
- 按 Windows 实际搜索序解析名字：app 目录 → System32 → SysWOW64 → PATH，并区分 `APP_LOCAL / SYSTEM / PATH / MISSING`。

四个 exe 的 depth-1 依赖完全同构，其中 **9 个是 Swift for Windows 运行时**，包里一个都没有：

| DLL | 需要者 | 状态 |
|---|---|---|
| `swiftCore` `swiftCRT` `swiftWinSDK` `swiftDispatch` `swift_Concurrency` `BlocksRuntime` `Foundation` `FoundationEssentials` | 4/4 | MISSING |
| `FoundationNetworking` | LingXiCoreHost、lingxiagent-ops（2/4） | MISSING |
| `sqlite3.dll` | LingXiCoreHost、lingxiagent-ops | 已在包内 |
| `KERNEL32` `bcrypt` `WS2_32` `KERNELBASE` `ntdll` `RPCRT4` | 4/4 | OS 提供 |
| `VCRUNTIME140` | 4/4 | ⚠️ 见下 |

补全运行时后闭包节点数从 **45 涨到 256–259**，说明 Swift 那层此前根本没有展开。**延迟加载为 0 条**——所有节点都没有 delay-load 表。

### 三个别报错的误判

- **83 个 `api-ms-win-* / ext-ms-*` 不是缺失。** 它们是 API Set 虚拟名，Win11 上 System32 里本就没有实体文件，加载器按 API set schema 解析。只有部分被 PATH 上的 `Windows Kits\10\Windows Performance Toolkit` redist 副本命中，属机器状态巧合。
- **`AzureAttest*` / `HvsiFileTrust` / `PdmUtilities` / `wpaxholder` 不是本包问题。** 它们分别由 `dmcmnutils.dll`、`shell32.dll`、打印支持、`urlmon.dll` 按需引用，是 OS 自身的可选组件，任何 Win11 都一样。
- **`VCRUNTIME140.dll` 命中 System32 是假安全。** 那是本机装过 VC++ 运行库。纯净 Windows 不保证有，必须显式处理（随包带 / 装 vc_redist / 写进系统要求）。

### 正确的运行时来源

**不要拷工具链 bin**，那里有 `libclang.dll`(77MB)、`liblldb.dll`(146MB)、`sourcekitdInProc.dll`(134MB)、`LTO.dll`(61MB) 等编译器 DLL，几百 MB 且一个都用不上。

权威来源是安装器自带的**运行时可再分发目录**：

```text
%LocalAppData%\Programs\Swift\Runtimes\6.0.3\usr\bin\*.dll      ← 拷这个（32 个，约 17MB）
%LocalAppData%\Programs\Swift\Redistributables\6.0.3\rtl.amd64.msm  ← 同一套东西，17.8MB
```

**整目录拷，不要按闭包裁剪。** 理由：`_FoundationICU.dll`、`FoundationInternationalization.dll` 这类是 Foundation 按需加载的，**不在任何导入表里**，纯静态闭包会漏，症状是装完能跑、一进日期格式化或多语言就炸。整目录 17MB，代价可忽略。

分三组，都必需：

- Swift 运行时：`swiftCore` `swiftCRT` `swiftWinSDK` `swiftDispatch` `dispatch` `swift_Concurrency` `swift_StringProcessing` `swift_RegexParser` `swiftRegexBuilder` `swift_Differentiation` `swiftDistributed` `swiftObservation` `swiftSynchronization` `swiftSwiftOnoneSupport` `swiftRemoteMirror` `BlocksRuntime`
- Foundation：`Foundation` `FoundationEssentials` `FoundationNetworking` `FoundationXML` `FoundationInternationalization` `_FoundationICU`
- VC++ 运行库（微软允许随包再分发）：`vcruntime140` `vcruntime140_1` `vcruntime140_threads` `msvcp140` `msvcp140_1` `msvcp140_2` `msvcp140_atomic_wait` `msvcp140_codecvt_ids` `vccorlib140` `concrt140`

VC++ 那组一起带，顺带免掉目标机装 `vc_redist` 的要求。

版本必须配对：这批 exe 由 `Toolchains\6.0.3+Asserts` 构建（`build-win.log` 可查），运行时就必须同为 6.0.3。

### 为什么 CI 拦不住（结构性根因）

```text
release.yml:187 的注释已经写对了一半——
  "sqlite3 is a runtime DLL dependency here, not a link-time one:
   without it beside the executables the package fails to start on a clean machine."
release.yml:198  "$PWD/staging/lingxiagent.exe --version"
Scripts/ci-artifact-smoke.sh  解压后跑 lingxiagent --version/--help/ops --smoke
```

**验证环境与故障域同源**：runner 上 `compnerd/gha-setup-swift` 已经把 Swift 加进了 PATH，于是 exe 从 PATH 就能捞到 `swiftCore.dll`，smoke 全绿，残缺包出厂。本机以前同理，直到 Swift 被移除才暴露。

比漏拷更该修的是这条：**artifact smoke 必须在拿不到工具链的环境里跑**。否则同类回归永远拦不住。

`release.yml:279-280` 那句「Windows：解压 zip 后直接运行，sqlite3.dll 与资源包已随包放在同一目录」是错误前提，需订正。

---

## 二、install.ps1 会让修好的包重新变坏

`install.ps1`（与 `Server/agent-site/public/install.ps1` 内容完全相同）的落盘约定：

```text
%USERPROFILE%\.lingxiagent\           InstallRoot
  bin\                                4 个 exe + *.resources/*.bundle + Sidecars\browser-host
  sidecars\browser-host\              与 bin 内那份重复部署（脚本刻意两份）
  logs\  sessions\  providers.json
PATH                                  [Environment]::SetEnvironmentVariable("Path", …, "User")
```

问题：**脚本按名字逐个拷那 4 个 exe，从来不理任何散落的 `*.dll`**（`Install-Sidecars-And-Bundles` 只拷目录）。所以就算把运行时塞进 `lingxiagent-windows-x86_64.zip`，走 `install.ps1` 装到干净机器**依然是坏的**——DLL 在解压目录里躺平，一个都不会进 `bin`。

这是本次调查最容易被忽略的一环：修 zip 不等于修安装。

---

## 三、MSI 打包实录（WiX v7）与全部踩坑

成品：`LingXiAgent-1.1.0-x86_64.msi`，59.95MB，每用户安装、不需管理员、内嵌 CAB、含开始菜单快捷方式。
`sha256 = 333cc4172a5cec2b0400e2c60c9501f38ea75809bc0b5854251a0e750c827e15`
UpgradeCode = `{D408CA13-2C0E-4EE6-AADB-6F751433CFA7}` —— **后续重打包必须沿用**，否则 MajorUpgrade 认不出旧版本。组件 GUID 用 `UUIDv5(UpgradeCode, payload 相对路径)` 派生，稳定且与打包顺序无关。

工具链：`dotnet tool install --global wix` → 7.0.0（本机已有 .NET 10 SDK）；`.wixproj` + `dotnet build`，扩展 `WixToolset.UI.wixext`（`WixUI_Minimal`）。

### OSMF 需要主人决策

WiX v4+ 参与 Open Source Maintenance Fee：**年营收超过 $10,000（OSMF 定义）的组织必须资助 wixtoolset**。v7 在构建期强制要求接受 EULA（`error WIX7015`），方式：`wix eula accept wix7` / `<AcceptEula>wix7</AcceptEula>` / `wix build -acceptEula wix7`。**接受 EULA 属于合规判断，不能让 agent 代点。**

### v3 → v7 的写法变化（全是实测报错）

| 旧写法 | v7 结果 |
|---|---|
| `Package/@InstallPrivileges` | WIX0004 移除；per-user 用 `Scope="perUser"` 即可 |
| `Package/@Platform="x64"` | WIX0004 不存在该属性 |
| `SummaryInformation/@Author`、`/@Template` | 都被拒；`Bitness="always64"` 可用但触发 **ICE80**（Template Summary 缺 x64），64 位包声明的官方写法**待查**，本次退回中性包（后果仅：组件 keypath 注册表值落在 `Wow6432Node` 视图，`HKCU\Environment` 不在重定向范围，PATH 读写不受影响） |
| `<Directory Id="TARGETDIR" Name="SourceDir">` | WIX7009 virtual symbol 冲突 → 必须 `<StandardDirectory Id="TARGETDIR">` |
| `<Fragment>` 嵌在 `<Package>` 里 | WIX0005 → `Fragment` 必须是 `<Wix>` 的直接子元素 |
| `Feature/@Absent` | WIX0004 移除 |
| `SetDirectory/@Ref`、`/Sequence="none"`、`/Before` | 属性名是 `@Id`；`Sequence ∈ execute\|ui\|both`；无 Before/After |
| `<Custom><![CDATA[条件]]></Custom>` | WIX0400 → 条件走 `@Condition` 属性 |
| `util:EnvironmentVariable` / 核心 `EnvironmentVariable` | **v7 根本没有这个元素**，PATH 只能靠自定义动作 |
| VBScript 内联 CA | WIX1163 明确弃用 + 要求 `@ScriptSourceFile`，产品安装器不要用 |
| `Guid="auto"` | WIX0009 非法。`Guid="*"` 仅在"标准目录 + 单文件/注册表 keypath"下允许；**非标准目录、目录 keypath、注册表 keypath+文件、多文件未版本化 keypath 都必须给字面 GUID** |

另两个纯 PowerShell 侧的坑：`New-Object Some.Type()` 末尾那对括号是语法错误（`()` 不该跟在类型名后）；**PS 5.1 读无 BOM 的 UTF-8 脚本时按系统 ANSI（GBK）解码，脚本里放中文会把紧随其后的引号当双字节尾字节吞掉**，表现为"字符串缺少终止符"这类完全对不上位置的报错。构建脚本一律保持纯 ASCII。

### ICE 规则要按它的建议做，不是压制

- **ICE38**（组件装在用户目录里，keypath 必须是 HKCU 注册表值而非文件）：给每个组件加
  `<RegistryValue Root="HKCU" Key="Software\LingXiFox\LingXiAgent\Components" Name="…" Type="integer" Value="1" KeyPath="yes"/>`。
  这条对 per-user 安装是真建议，不只是洁癖——keypath 与 profile 实际位置解耦，repair/uninstall 检测更稳。
- **ICE64**（用户目录树里每个目录都要在 RemoveFile 表有登记）：一个集中的 `FolderCleanup` 组件，带全部目录的 `<RemoveFolder On="uninstall"/>`。
- **ICE77**（in-script CA 必须排在 InstallInitialize 与 InstallFinalize 之间）：`add` 用 `Before="InstallFinalize"`（此时文件已就位），`remove` 用 `Before="RemoveFiles"`（否则脚本已被删掉）。
- **ICE91**（per-user 目录不随 ALLUSERS 变化）只是提示，per-user 包正常现象。

### 卸载必须真的干净

`RemoveFolder` **只能删空目录**。第一版把自定义动作日志写在安装目录（`install-ca.log`），结果卸载后 `%LOCALAPPDATA%\LingXiAgent` 因为这一个非 MSI 管辖的文件永远残留。改成写 `%TEMP%\LingXiAgent-install.log` 之后，实测卸载项全清：app dir / 开始菜单 / PATH / ARP / keypath 注册表 全部 absent。

规则：**诊断输出不要落在安装目录**。

---

## 四、环境变量"装了不生效"——三层原因要分清

这是最容易被误判成"安装失败"的部分，实际上是三件不同的事。

### 1. MSI 的 Environment 表只写机器作用域

per-user 安装要写的是 `HKCU\Environment`，MSI 原生 `Environment` 表动的是 HKLM、需要提权，且 `install.ps1` 本来也写用户作用域 → 只能走自定义动作：`Execute="deferred" Impersonate="yes"` 调 powershell 写 `HKCU\Environment`。

### 2. 两个命令行解析陷阱（本狐各踩一次）

**(a) exefromdirectory 会把 Source 目录拼到 Target 前面。**
`CustomAction/@Directory="WPS10"` + `ExeCommand` 的语义是"程序相对该目录"。ExeCommand 里写绝对路径会被拼成
`C:\Windows\…\v1.0\"C:\Windows\…\v1.0\powershell.exe" -NoProfile …` → 静默失败。
正确写法：`ExeCommand="powershell.exe -NoProfile … "`。
另注：32 位中性包里 `[System64Folder]` 解析成 **SysWOW64**（本狐实测 log 里 `WPS10 = C:\WINDOWS\SysWOW64\WindowsPowerShell\v1.0\`）。

**(b) MSI 属性自带的尾反斜杠会吃掉引号。**
`[BIN]` 展开时以 `\` 结尾，所以 `-Dir "[BIN]"` 变成 `-Dir "C:\…\bin\"`，Windows C 运行时分词把 `\"` 当**转义引号**，闭合引号被吞，脚本收到的参数是 `C:\…\bin"`。后果是 PATH 里写进一个带尾巴的废值，**而自定义动作返回"成功"**——`Return="ignore"` 把失败全吞了。

对策（本狐最终采用的）：**别把这个值当参数传**，脚本从 `$PSCommandPath` 自己推导 bin；并且 remove 端比较时 `TrimEnd('\','"',' ')`，以便把历史脏值也清掉。

**关键 CA 一律用 `Return="check"`**，否则失败会以绿色的"exit=0"呈现。

### 3. 广播到不了别的会话（主人问的那个问题）

注册表写对 ≠ 终端能看到。进程的环境块在**创建那一刻**固定，且 `SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, "Environment")` **只能到达同一窗口站/会话的顶层窗口**。

| 安装发起位置 | 广播是否有效 | 用户需要做什么 |
|---|---|---|
| 自己桌面双击 msi（含提权窗口，Session 1） | ✅ 有效 | **新开一个终端**即可，无需注销 |
| SSH / PsExec -s / SCCM / CI / 服务（Session 0） | ❌ 送不到 Session 1 | 重启 Explorer 或重新登录一次 |

本狐第一台机器上"装完 cmd 找不到命令"就是第二种：实测 `(Get-Process -Id $PID).SessionId = 0` 而 `explorer` 在 `SessionId = 1`。

**已验证的正常路径**：主人本机双击安装后什么都不动，新开 cmd 敲 `lingxiagent` 直接进 TUI 并连上 Core。

另外必须接受的事实：**任何安装器都无法更新已经开着的终端**。所以产品文案里"装完请新开一个终端窗口"这句话永远要写。

对照 `install.ps1`：它只 `SetEnvironmentVariable(...,'User')`、**完全不广播**，所以即使用户开新终端也拿不到新 PATH，必须重新登录。MSI 侧加广播是修正方向，反过来也说明 **`install.ps1` 该补上 WM_SETTINGCHANGE**。

### 4. 提权装错账户（会静默装到别人 profile）

per-user 包的目标目录取自**执行令牌**的 profile。域环境里"以其他管理员身份提权"很常见，那样文件会装进管理员账户，登录使用者什么也得不到。安装脚本必须比对控制台用户与当前用户，不一致**硬停**。

---

## 五、分发侧兜底：安装脚本该做什么

`Install-LingXiAgent.ps1`（Windows 侧 `C:\Users\hands\`，可作为 release 附件）的设计原则是——**"msiexec 返回 0"不等于装对了**。它做七件事：

1. 架构检查（x64-only，ARM64 直接拒）；
2. **提权错账户检测**：控制台用户 ≠ 当前用户 → 硬停；
3. **Session 0 检测**：如实告知"注册表和文件都对，但桌面会话需重启 Explorer"，不让人误判为安装失败；
4. **SHA256 校验**：自动抓 `<msi-url>.sha256`，不匹配**拒绝安装**（拦下载截断与替换）；
5. 读 **ARP 注册表**判断已安装版本——**不要用 `Get-CimInstance Win32_Product`**，它会枚举并"校验"机器上每一个 MSI 产品，既慢又可能触发副作用修复；
6. 退出码分类（1602 取消 / 1603 致命 / 1618 并发 / 1619 包损坏 / 3010 需重启）+ 失败时打印安装日志尾部并以非零码退出，便于 CI 判定；
7. **功能性验收**，而不是数文件：
   - 把 `PATH` 削到只剩 `C:\Windows\System32` 后真跑 `lingxiagent --version` 和 `lingxiagent-ops --smoke` —— 这才是"目标机无 Swift 环境"的实证；
   - 更深的 `lingxiagent-ops doctor` 会真实走 AES-256-GCM 保险库（bcrypt/CryptGen）、数据根读写、Provider/MCP/Skills 加载，比 `--version` 有分量得多；
   - PATH 断言问对问题：拼 **Machine + User 两个作用域**去解析命令（= 新终端会看到的），而不是查当前进程的 PATH；缺了就从自己的会话补写并广播（脚本必然跑在正确会话里，这一点比 MSI 更可靠）。

TUI 是否真渲染可以用一个不依赖人的代理指标：进程存活且 `Responding=True`、输出流里有大量 ANSI 转义序列（实测 248 条）。

---

## 六、待修清单（后续开发按这个来，本文不动代码）

| # | 位置 | 要做什么 |
|---|---|---|
| 1 | `.github/workflows/release.yml` build-windows（165-196） | staging 增加 `Runtimes\<ver>\usr\bin\*.dll` **整目录**，不要手写文件清单 |
| 2 | `release.yml:198` + `Scripts/ci-artifact-smoke.sh` | smoke 必须在**拿不到 Swift 的环境**跑，或启动 exe 前把 PATH 削成只有包目录。这是防复发的关键，优先级高于 #1 |
| 3 | `install.ps1` / `Server/agent-site/public/install.ps1`（两份内容相同，改一处要同步） | 拷 exe 的同时拷包内 `*.dll`；补 `WM_SETTINGCHANGE` 广播；建议直接改走 MSI |
| 4 | `.tmp/win-artifact.sh` | 同 #1、#3，本地打包脚本缺同一样东西 |
| 5 | `release.yml:279-280` 注释 | 「解压后直接运行」前提错误，订正 |
| 6 | Sidecars / Node.js | `browser-host/index.mjs` 需要 Node，dumpbin 查不出来；MSI 未跑 `npm install`。三选一：打包 node_modules / 首启再装 / 写进系统要求 |
| 7 | WiX 64 位包声明 | `Bitness="always64"` 撞 ICE80，v7 的正确写法待查证（本次退回中性包，keypath 落在 Wow6432Node） |
| 8 | 版本自报 | `--version` 打 1.0.0 而包是 1.1.0，属 `Scripts/version-consistency-check.sh:7` 已记录的已知缺陷，与本文无关 |

本文不涉及仓库内任何代码修改。现场保留物：Windows 侧 `C:\Users\hands\` 的 `build-msi.ps1`（打包器）、`Install-LingXiAgent.ps1`、`lxpkg\`（`Product.wxs`/`wixproj`/`lxpath.ps1`/`providers.json`/`license.rtf`）、`lxsrc\lxpath.ps1`、`lxfix\pre-files.txt`（补 DLL 前的原始清单）。
