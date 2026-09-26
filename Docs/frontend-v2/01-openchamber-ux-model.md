# OpenChamber Visual UX Model

Phase 1–2 output. Derived only from operating the running app (window 4045, 1920×1103 pt)
and reading its accessibility tree. No implementation technology is discussed here; this is
a model of *where information lives and when it is allowed to be visible*.

Screenshots and raw AX dumps: `/tmp/oc-study/` (`oc-main-01`, `oc-empty`, `oc-settings`,
`oc-panel-files`, `ax-conversation.txt`, `ax-settings.txt`, `ax-panel-*.txt`).

---

## A. App Shell Anatomy

```
┌─ far-left ─┬──────── centre ─────────────┬─ right dock ─┬ rail ─┐
│ Sidebar    │ Main workspace              │ Tool dock    │ icon  │
│ sessions   │ timeline + composer         │ multi-tab    │ rail  │
│ 264 pt     │ fluid, prose column 720 pt  │ ~340 pt      │ ~40pt │
└────────────┴─────────────────────────────┴──────────────┴───────┘
        top: unified toolbar (session tab + run + project + instance)
        bottom of sidebar: settings / stats / shortcuts / about
```

### Top (unified toolbar)
- **Responsibility**: identity of *what you are looking at* plus global run controls.
- Resident: session title as a tab, session-overflow menu, mini-chat toggle, work-state
  toggle, `运行 / 自动发现`, project actions, `在 Finder 中打开`, open-with-app, and an
  instance chip (`Local`) that also exposes usage and MCP.
- In a conversation the breadcrumb is the session title; in a dock view it becomes the
  project name (`lingxifox`). The toolbar never carries conversation content.
- Commonest action: switch session, start a run.

### Left (sidebar)
- **Responsibility**: session navigation only. Nothing else.
- Structure: icon strip (open session, new session, plan tasks, new multi-run, archive,
  search, select-mode, display-mode) → collapsible groups → `显示更多会话` → footer.
- Two group kinds: `聊天` for chats without a project, and one group per project
  (`~`, with a project menu and its own `新建会话`).
- Session row = title only, one line, truncated. Archive and a session menu appear on the
  row (hover/always in AX, visually quiet). Rows are `draggable` **and** `sortable` —
  manual ordering is a first-class affordance, not a sort-by-field.
- Transient: search results, selection mode.
- Footer carries `设置 / 统计 / 快捷键 / 关于` — app-level things live at the bottom of the
  navigation column, not in the toolbar.

### Centre (main workspace)
- **Responsibility**: the conversation, and the composer. This is the only place that is
  unambiguously the visual centre; everything else is chrome around it.
- The prose column is capped (~720 pt) and left-biased inside a wider pane, so a maximised
  window reads as a document, not as a stretched web page.
- Empty state replaces the timeline with a centred *start block* (see §Empty Workspace).

### Right (tool dock)
- **Responsibility**: everything that is *about* the work but not part of the narrative —
  context accounting, git, changed files, files, terminal, plan, browser, project knowledge.
- It is a **multi-tab dock**, not a single inspector: opening a panel adds a tab
  (`文件 ×`) with its own split and close controls, so two panels can sit side by side.
- Each panel owns its own sub-toolbar (e.g. the files panel gets new-file / new-folder /
  upload / refresh / more, then a search field, then the tree).
- The dock's default panel, `工作状态`, is the run-telemetry stack (see §D).

### Far right (rail)
- ~40 pt, always visible while the dock is open, ten reorderable (`sortable`) entries:
  `上下文 · Git · 拉取请求 · 更改 · 导读 · 文件 · 终端 · 项目知识 · 计划 · 浏览器`,
  plus a `配置面板` button at the bottom.
- **This is the density answer.** Ten secondary tools cost 40 pt of width and zero vertical
  space, so none of them has to be crammed into the conversation or hidden behind a menu.

### Bottom
- No global status bar. Run state is expressed in the toolbar and in the composer's send
  button; per-turn accounting is in the dock. The composer is the bottom-most element of
  the centre column and is *docked*, not floating.

---

## B. Feature → Location table

| Feature | Location | Presentation | Interaction | Visibility rule |
|---|---|---|---|---|
| New session | sidebar icon strip + group header | icon button | click | always |
| Session list | sidebar | one-line rows in groups | click to select | always |
| Reorder session | sidebar | row | drag | always (`draggable`+`sortable`) |
| Archive session | sidebar row | trailing icon | click | row-level, quiet |
| Session menu (rename/delete/fork) | sidebar row | popup | menu | row-level |
| Project switch | empty-state headline + composer chip | popup button | menu | empty state + always |
| Branch / worktree | Git dock panel | panel | — | dock only |
| Changed files / diff | `更改` dock panel | file list + diff | click file | dock only |
| Terminal | `终端` dock panel | embedded terminal | type | dock only |
| File browser | `文件` dock panel | search + tree | click | dock only |
| User message | timeline | tinted rounded block, inset from prose width | rewind / fork / pin / copy | copy+actions on hover |
| Assistant message | timeline | **plain text, no background** | copy / continue-from-here / pin | actions on hover |
| Turn metadata | timeline, above the turn | one quiet text line: `model · mode · duration · time` | — | always |
| Tool call | timeline | **single-line row**: glyph + name + duration + argument preview | click to expand | collapsed by default |
| Read/edit file | timeline | label + `dir / file` path chip | click opens path | collapsed |
| Error / interruption | timeline | full-width tinted banner | — | always while relevant |
| Prompt jump | overlay navigator | list of user prompts | click to scroll | on demand |
| Scroll to bottom | floating over timeline | icon button | click | only when scrolled up |
| Attachment | composer | `+` popup | menu | always |
| Focus mode | composer | toggle | click | always |
| Auto-accept permissions | composer | toggle | click | always |
| Start Goal from next message | composer | toggle | click | always |
| Model | composer, right side | logo + name chip | menu | always |
| Mode (Build/Plan) | composer, right side | coloured text chip | menu | always |
| Voice input | composer | icon | click | always |
| Send / Stop | composer, far right | icon button | click | always; disabled when empty |
| Context usage % | dock `工作状态` | bar + `%` + cost | click → context panel | when a turn exists |
| Provider quota / health | dock `工作状态` | disclosure list, one row per provider, status text | refresh button | always |
| Turn statistics | dock `工作状态` | disclosure of key–value rows | expand/collapse | when a turn exists |
| MCP servers | dock `工作状态` | `4/4` + per-server toggles | toggle | always |
| Context sources | dock `工作状态` | `69 个技能 · 4 个 MCP`, then counts | expand | always |
| Plan / Todo | `计划` dock panel | panel | — | dock only |
| Settings | modal over dimmed shell | 3 columns | ⌘, | transient |

---

## C. Conversation Anatomy

The unit is a **turn**, not a message. A turn renders as:

```
⟨model icon⟩ DeepSeek V4 Flash · build · 8.9s · 8月11日 21:49     ← metadata, no container
  ⟨user block, tinted, narrower than prose⟩   [rewind][fork][pin][copy] on hover
  assistant prose — no background, no card
    ▸ Load Skill        OpenCode
    ▸ Shell Command  0.1s  ls -la ~/.config/opencode/ && echo …
    ▸ Fetch URL        https://opencode.ai/v2/docs/migrate-v1
    Read File  ⟨.config/opencode / opencode.jsonc⟩
  more assistant prose, continuing after the tools
  ⟩ error banner when a step was interrupted
  assistant closing prose
  [copy][…][pin] · 从此回答继续                                    ← turn footer
```

Rules that make this read as one object:
1. **Only the user message gets a background.** Assistant text is bare. This is the single
   biggest reason the timeline does not look like a card wall.
2. **Tool activity is inline in the narrative flow**, at the same left edge as prose, not
   indented into a sub-pane and not boxed. Prose → tools → prose interleaves naturally.
3. **A tool row is one line, collapsed, with the argument truncated.** The duration sits
   next to the tool name as metadata, not as a badge.
4. Turn grouping is achieved by the metadata header line + shared left edge + whitespace,
   **not** by drawing a container around the turn.
5. Long-lived per-message affordances (pin-to-context, fork, rewind) are attached to the
   message, so the timeline itself is the editing surface — there is no separate "history"
   screen.

---

## D. Progressive Disclosure Model

**Always visible**
- Session sidebar, project grouping, composer and its model/mode chips, the far-right rail,
  instance chip, per-provider health.

**Visible on hover**
- Message actions (copy / rewind / fork / pin), session row actions.

**Visible when active**
- `滚动到底部` (only while scrolled away from the bottom), Stop in place of Send,
  pending permission/question surfaces.

**Expandable in place**
- Tool rows (collapsed one-liner → full command + output), every `工作状态` section
  (`用量`, `轮次统计`, `MCP`, `上下文来源` are disclosure headers with the count in the
  header, e.g. `MCP 4/4`).

**Dock only**
- Git, pull requests, changes/diff, files, terminal, browser, project knowledge, plan,
  deep context view.

**Settings only**
- Appearance, keyboard shortcuts, voice, integrations, extensions, provider credentials,
  agent behaviour, commands, plugin management, worktree policy, per-project accent colour
  and icon.

**Not in the main GUI at all**
- Raw runtime diagnostics; they are reachable through the stats footer button, not the
  conversation.

**Conditional by state (the sharpest observation)**
- In the empty workspace the dock drops `上下文 %` and the whole `轮次统计` section, because
  no turn exists yet. It keeps `用量`, `MCP`, `上下文来源`. Panels shed turn-scoped data
  rather than showing zeros.

---

## E. Density Model — why ten tools do not feel crowded

1. **Width is cheap, vertical space is sacred.** Secondary tools pay 40 pt of rail width
   and never enter the timeline.
2. **Typography replaces containers.** Turn metadata, tool rows and key–value stats are
   plain text at three sizes with hairline separators. Backgrounds are reserved for exactly
   three things: the user message, banners, and the composer.
3. **Numbers live on the right, narrative in the centre.** Nothing about tokens, cost,
   latency or cache hit rate is allowed to interrupt reading the answer.
4. **The timeline interleaves rather than groups.** Tools appear where the model used them,
   collapsed to one line, so a 30-tool turn is 30 short lines of a continuous document —
   not 30 cards.
5. **Disclosure headers carry the summary** (`MCP 4/4`, `69 个技能 · 4 个 MCP`, `57.4%
   $0.0363`), so the collapsed state is already informative and expanding is optional.
6. **Truncation is the default for machine text** — commands, URLs, paths — with the full
   value available on expand or in the tooltip (`Help:` on the path chips).
7. **Empty space is allowed.** The empty workspace centres a compact start block and leaves
   the lower half of the window bare; it does not invent filler panels.
8. **State-dependent shedding.** Panels remove sections that have no data instead of
   rendering placeholders.

---

## F. Settings IA

Modal sheet over the dimmed shell (`⌘,`), three columns:

1. **Category rail** with a search field on top and four labelled groups:
   - `OPENCHAMBER` — 通用 / 外观 / 聊天 / 通知 / 会话 / 路由 / 快捷键 / 语音 / 集成 / 扩展 / 用量
   - `工作区` — 项目 / 远程实例 / 外部隧道(测试版) / Git
   - `OPENCODE` — 提供商 / 网页搜索 / 智能体 / 行为 / 命令 / MCP / Plugins
   - `资源库` — 魔法提示词 / 代码片段 / 技能 / 技能目录
2. **Object list** (only when the category is collection-shaped, e.g. 项目 → `总计 1` +
   `添加项目` + the list).
3. **Detail form**: generous single-column width, numbered section headers, `更多信息`
   help affordance per section, inline pickers for enumerations (accent colour swatches,
   icon grid), and empty-state text for unconfigured collections
   (`尚未配置任何操作。`).

Group labels are product-domain labels, not a flat list — the reader learns the product's
boundaries from the settings sidebar itself.

---

## G. What was NOT visually verified

Recorded so it is not mistaken for covered ground:

- **Permission / confirmation / user-question surfaces.** Triggering them requires a live
  run against providers that are currently `Rate limited` / `Session expired`, and would
  spend the user's credit. Not exercised.
- **Running / streaming state** (thinking placement, live progress, Stop affordance while
  generating). Only the completed-turn layout was observed.
- **Subagent / multi-run presentation.** `新建多运行` exists in the sidebar strip but its
  UI was not opened.
- **Narrow-window and light/dark variants.** Captures are at 1920×1103 dark.
- **Diff rendering detail.** The `更改` panel was reachable but the current project
  (`/Users/lingxifox`) is not a git repository, so only its empty state
  (`当前目录不是 Git 仓库`) was observed.
