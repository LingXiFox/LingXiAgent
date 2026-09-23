# LCSAL 1.1 与 PolyForm 附加条款提案 (DRAFT)

**状态**：提案（proposal）。法律实体变更由 @LingXiFox 定夺；本文件不改变当前
生效的 `LICENSE-CORE`（LCSAL-1.0）与 `LICENSE-FRONTEND`（PolyForm
Noncommercial 1.0.0）条款。经主人批准后，本文件的条款会被合并进 `LICENSE-CORE`
与 `LICENSE-FRONTEND`，版本号一并升级。

**背景**：抽象路线图 `Docs/ROADMAP-V1.1-V2.0.md` §6 原本写的是"Core 为
AGPLv3，SwiftUI 前端为 Apache-2.0"。这与仓库现实（LCSAL-1.0 + PolyForm）不
符。2026-09-23 主人决定 **不切换到 AGPL/Apache**，而是保留 source-available
+ noncommercial 立场并把 LCSAL 升到 1.1，同时在 PolyForm 之上加一条附加条
款。`LicenseMatrixDriftTests` 已经把 target 清单从三份 LICENSE 文件里剥离到
`LICENSE-MATRIX.md`；本提案处理剩下的条款层面差异。

**条款优先级**：中文优先。中英文本冲突时以中文为准。

---

## Part A — LCSAL 1.1 新增/变更条款

以下五条为 **相对 LCSAL-1.0 的差异**。未列出的条款保持 1.0 原文。

### A.1 授权范围（§1 无变化，仅补充）

保留 1.0 中"个人受控的本地计算环境中阅读、学习、研究、本地编译及个人单机非
商业运行"表述。新增一句以与 A.2 呼应：

> 本条授权不排斥 A.2 所定义的"官方 release 产物非商用原样转发例外"。

### A.2 官方 release 产物的非商用原样转发例外（新增）

**中文**

对本项目 [GitHub Releases](https://github.com/LingXiFox/LingXiAgent/releases)
页面上由版权所有者（LingXiFox）亲自发布的产物（`lingxiagent-<version>-<platform>.tar.gz`
或 `.zip`，以及配套的 `sha256` 校验文件），在满足下列全部条件时，允许非
营利原样转发：

1. **未修改**：文件字节与官方产物完全一致；未重打包、未剥离签名、未嵌入
   其它内容；
2. **附许可**：转发页面/包描述必须显式指向本 `LICENSE-CORE` 与仓库根，且
   附带本许可证全文；
3. **非商用**：转发本身不构成任何收费服务、订阅、赞助换礼、或商业产品组
   件；
4. **不误导**：不得使用"LingXi"、"灵犀"或官方站点域名的近似拼写作为转发
   主体名称，以免与官方发布渠道混淆。

**允许**的具体形态包括：Homebrew Tap 与 AUR PKGBUILD 拉取 GitHub Release
URL、镜像站缓存 GitHub Release 资产、社区文档指向官方下载链接、包管理
mirror（如 `deb` mirror、`swift-package-mirror`）自动同步官方产物。

**仍属禁止**：自行 `swift build -c release` 得到的二进制、将本仓库源码
编译进他人产品、修改产物后分发。

**英文**

Artifacts published on the project's GitHub Releases page by the Copyright
Holder may be forwarded unmodified and non-commercially as long as (a) the
bytes are identical to the published release asset, (b) the license text and
a pointer back to this repository accompany every forwarded copy, (c) the
forwarding is not itself a commercial activity, and (d) the forwarding does
not use names confusingly similar to "LingXi", "灵犀", or the official site
domain. Self-compiled binaries remain prohibited from redistribution.

### A.3 Fork 政策（新增）

**中文**

对本项目官方仓库（`github.com/LingXiFox/LingXiAgent`）及其镜像的 fork，
**仅用于向本项目提交 Pull Request**。fork 不得作为分发渠道使用，具体禁止：

1. 在 fork 仓库的 Releases / Packages / Downloads 页面发布自建产物；
2. 在 fork 仓库的 README、Wiki、Issue 中引导他人从 fork 安装本软件；
3. 在 fork 上运行任何"官方风格"的镜像站点、包源或 CDN 服务；
4. 将 fork 名称与官方产品名混淆（如 `LingXiAgent-Official-CN`、
   `LingXiPro-Fork` 之类）。

Fork 若需要发布衍生版本，应明确注明"非官方"、修改产品标识、并单独取得
版权所有者书面同意。

**英文**

Forks of the official repository exist only to submit pull requests upstream.
A fork may not publish its own Releases / Packages / Downloads, may not
redirect users to install from the fork, and may not adopt a name confusingly
similar to the official product. Derivative publication requires explicit
written consent from the Copyright Holder.

### A.4 贡献者 relicense 授权（新增）

**中文**

任何向本项目提交 Pull Request 的贡献者（"贡献者"），就其在该 PR 中提交之
所有代码、文档、测试与其它创作（"贡献"），特此**免费、永久、不可撤销地**
授予版权所有者（LingXiFox）以下权利：

1. **许可类型变更权**：在本项目后续版本（包括 major 版本）中，将贡献以不
   同许可类型发布，包括但不限于将 LCSAL 从 1.x 升级到 1.y 或 2.z、将
   PolyForm Noncommercial 调整为其它合规的非商用或开源协议；
2. **合并 / 拆分权**：将贡献合并进更大的许可域（如整个 Core 或某个前端组
   件），或与其它贡献拆分到不同许可域；
3. **不撤销贡献者本人授权**：贡献者本人仍保有对**自己贡献**的完整著作权，
   可以在其它项目自由使用；本条授权仅约束"本项目如何对外发布"，不约束
   贡献者本人对自身贡献的其它用途。

贡献者提交 PR 即视为接受本条。若贡献者所在雇主 / 学校对贡献拥有知识产权，
贡献者应在提交前获得其许可。

**英文**

Contributors grant the Copyright Holder a perpetual, irrevocable, royalty-free
license to relicense their contributions in future project releases (LCSAL
1.x → 1.y, PolyForm Noncommercial → another compliant noncommercial or open
source license, etc.). Contributors retain full copyright over their own
work and may reuse it elsewhere without restriction.

### A.5 商用定义（新增，白/黑/灰三区）

**中文**

对本许可中"商用 / 商业使用 / commercial use / commercial exploitation"的解释：

- **属于商用（严禁）**：
  1. 对外提供**收费**的 API 代理 / 中继 / Token 转售；
  2. 将本产品作为 SaaS / PaaS / 云托管服务的运行时组件；
  3. 集成进任何**收费**发行版、商业产品、或外包交付物；
  4. 以本产品直接产生营业收入；
  5. **企业内部署**：由**有薪酬**团队在企业生产环境使用本产品的开发、测试、
     运维或运行，无论是否直接产生收入。

- **不属于商用（允许）**：
  1. 个人自用的多设备同步（同一自然人）；
  2. 非营利组织内部使用；
  3. 开源项目内部使用（不含 A.5"属于商用"第 5 项的企业生产部署）；
  4. 无薪酬社区团队使用；
  5. 学术科研使用（不含企业赞助的定向商用研究）；
  6. 个人本地编译后自用体验。

- **灰色带（默认禁止，需事前书面同意）**：
  1. **AI 训练数据集**：将本仓库源码或其派生数据用于训练任何模型，无论
     模型是否商用；
  2. **企业内非生产的个人研究**：员工个人在企业网络下运行但不进入生产流
     水线；
  3. **付费培训 / 工作坊**：以本产品为主要讲授内容并向学员收费；
  4. **媒体出版物**：纸质或数字出版物附带本产品副本（含源码镜像）。

任何落入灰色带的用途，请通过 Issues / 邮件联系 @LingXiFox 获取书面授权；
未获书面同意时按"属于商用"处理。

### A.6 语言优先级（新增）

**中文**

本许可证的中英文本以**中文文本为准**。英文翻译仅供参考，不构成独立授权。
若中英文本存在任何解释冲突，中文优先。

### A.7 适用范围引用式（变更）

1.0 中"Applicable to: `Sources/LingXiCore` ..."硬编码清单全部废止，改由
仓库根 `LICENSE-MATRIX.md` 声明。任何新增 SPM target 必须在矩阵中登记
许可归属，否则 `LicenseMatrixDriftTests` 使 CI Stage 2 构建失败。这是唯一
可以结构性防止矩阵与 target 集合漂移的机制。

---

## Part B — PolyForm Noncommercial 1.0.0 附加条款

保留 PolyForm Noncommercial 1.0.0 官方全文（`LICENSE-FRONTEND` Part 1–10）。
在其**之后**追加本项目补充条款。

### B.1 第三方改版仅限源码形式分发（新增）

**中文**

对 PolyForm Noncommercial 1.0.0 §2 "Copyright License" 之补充：

第三方对本前端（包括但不限于 `Sources/LingXiTUI`、`Sources/LingXiTUIComponents`、
`Sources/LingXiTUIApp`、`Sources/lingxiagent` 表现层、`Apps/LingXiApp/*`）
修改后分发**衍生作品**时，**只能以源码 + 可复现构建脚本形式**分发，不得
分发：

1. 编译后的二进制产物（含 `.app` bundle、`.dmg`、`.pkg`、`AppImage`、
   `.deb`、`.rpm`、`.exe`、`.msi`）；
2. 应用商店上架包（Mac App Store、Microsoft Store、Google Play 等）；
3. 容器镜像（Docker、Podman、OCI）。

**官方 release 二进制**不受本条限制（它们由版权所有者亲自发布，已在 A.2
项下授权转发）。

**理由**：防止他人以 LingXi / 灵犀 名义发布未经审核的"改进版"二进制造成
用户体验、安全或商标层面的混淆。

**英文**

Third parties who modify the frontend may distribute their derivatives only
in source form together with reproducible build scripts. Compiled binaries,
app-store packages, and container images may not be redistributed by third
parties. Official release binaries published by the Copyright Holder are
not subject to this restriction.

### B.2 适用范围引用式（变更，同 A.7）

保留 PolyForm 官方条款不动；将前端适用范围的目录清单交由
`LICENSE-MATRIX.md` 声明。

---

## Part C — 交付路径

1. 主人批准本提案（或指出需要改动的具体条款）；
2. 将 Part A 五条合并进 `LICENSE-CORE`，版本号 `1.0` → `1.1`；同时更新
   `LICENSE` 主文件 Part 1 中的相应条款；
3. 将 Part B 附加条款合并进 `LICENSE-FRONTEND`；同时更新 `LICENSE` 主文件
   Part 2；
4. 更新 `Docs/ROADMAP-V1.1-V2.0.md` §6 措辞为 "LCSAL-1.1 Core + PolyForm
   Noncommercial 1.0.0 Frontend (source-only for third-party mods)"；
5. 在 `LICENSE-MATRIX.md` 中把 `LCSAL-1.0` 全部替换为 `LCSAL-1.1`；
6. 打 `V1.1.0` tag 之前，随版本发布一并归档一份 `docs/legal/CHANGELOG.md`
   记录 1.0 → 1.1 差异。

## Part D — 与 V1.0.0 已发布产物的关系

V1.0.0 已经以 LCSAL-1.0 + PolyForm Noncommercial 1.0.0 的名义分发。LCSAL-1.1
与其**兼容**：新增条款 A.2 / A.3 / A.5 只是把过去"默认禁止"的边界写得更
具体（且 A.2 是**放宽**，不是收紧），不改变 V1.0.0 用户已经获得的授权。A.4
贡献者 relicense 授权**不追溯** V1.0.0 之前已合并的 PR——但可对未来 PR 生
效；主人可决定是否需要在 V1.1 之前向历史贡献者逐一征求确认。
