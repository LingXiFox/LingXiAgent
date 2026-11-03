# ADR-0001：插件 ABI 的许可轨道

状态：已采纳（主人 2026-10-20 拍板）

## 背景

`LICENSE-MATRIX.md` 把 `LingXiPluginABI`（C 头文件 + Core↔Host 契约类型）标为「Expected track: open」，
并写明这是**声明第一个插件 target 之前必须由主人决定**的事项；`Project-Conventions.md` 第八章记录过本狐的
建议，`Docs/README.md` 把它列为待拍板第 1 条。仓库里其余 Core 代码走 LCSAL-1.1（非商业、不可再分发），
官方插件走 PolyForm Noncommercial 1.0.0。

## 选项

1. MIT，为新 target 新开一条轨道。
2. PolyForm Noncommercial 1.0.0，与官方插件同轨，不动授权范围。
3. 暂不声明 target，头文件先作为 Host 的内部文件存在，决策推迟到开发者文档阶段。

## 选择

**选项 1：MIT，单独一条轨道**，法律文本落在 `LICENSE-ABI`，只覆盖 `Sources/LingXiPluginABI`。

## 理由与代价

- 设计文档要求「官方与社区共用同一套能力注册契约」。PolyForm 会直接禁止商业作者使用这份 ABI，
  与既定目标冲突；README 的原始顾虑正是这一条。
- 代价：新增一条许可轨道，`Project-Conventions.md` 第八章需登记；许可矩阵漂移门禁（L0）要求
  矩阵行与 `Package.swift` 的 target 声明**同一提交**落地。
- 不改变插件本身的许可：官方插件仍在 PolyForm 轨道，MIT 只覆盖「写插件需要的接口定义」。

## 可逆性

可逆但代价高：一旦有第三方按 MIT 取用头文件，收回会伤及已在用的作者。因此本决定视为长期承诺。

## 落地状态

本 ADR 记录决定本身，**尚未**声明 target。`LingXiPluginABI` 的 target 与矩阵行随插件闭环一起提交
（当前在 `wip/phase2-plugin-host` 分支的在制品里）。
