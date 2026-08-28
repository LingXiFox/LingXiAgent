# 功能 inventory

分类：`OPENCHAMBER OWNED`、`OPENCODE WRAPPER`、`MIXED`、`UI ONLY`、`PLATFORM ONLY`、`UNKNOWN`。所有 OpenCode 调用均经 Runtime SDK/`/api` proxy，除非另有说明。

| Feature | 用户看到什么 / 解决什么 | UI owner | State owner / 持久化 | OpenCode role | Class | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Chat / Composer | 建立会话、输入 prompt、附件和 slash command | `components/chat`, Composer | sync child store; drafts localStorage | 创建/发送/读 Session、Message、Part | MIXED | `sync/session-ui-store.ts`, `attachment-files.ts` |
| Streaming / reasoning / tools | 实时回答、thinking、工具卡片 | `components/chat/message/parts` | sync part bucket | SSE Part events | OPENCODE WRAPPER | `sync-context.tsx`, `event-reducer.ts` |
| Permission / question | 审批工具、回答 Agent 问题 | chat permission/question UI | OpenCode pending state; policy in settings | asks/replies are OpenCode | MIXED | `permission-auto-accept/runtime.js` |
| Session navigation | sidebar、archive、folders、搜索、recent | `SessionSidebar` | global cache + directory stores; folders browser/server state | Session list/mutation | MIXED | `useGlobalSessionsStore.ts`, `session-actions.ts` |
| Session Goal | 目标、自动续跑、预算和完成提醒 | Goal button/row/dialog | Session metadata + `goals/<session>.md` | `prompt_async`, Session reads/writes | OPENCHAMBER OWNED | `session-goal/runtime.js` |
| Session recap/suggestion | 最后一轮摘要和建议 | recap spacer/chip | Session metadata `.assist` | reads last OpenCode exchange; direct small-model call | OPENCHAMBER OWNED | `session-assist/runtime.js` |
| Multi-run / Fusion | 多模型并行比较、合并结果 | `components/multirun` | UI/store plus created Sessions | multiple OpenCode Sessions | MIXED | `components/multirun/` |
| Agent execution | 选择 agent/model/variant，观察 busy/idle | composer/work status | selection store and Session events | Agent loop/status comes from OpenCode | OPENCODE WRAPPER | `selection-store.ts`, `session-runtime.js` |
| Models/providers | 登录、OAuth、配置 provider、选 model | `sections/providers` | OpenCode config/auth files; UI config store | OpenCode provider/catalog/auth APIs | MIXED | `opencode/routes.js`, `providers.js` |
| Usage in chat | tokens、cost、context usage | work status/header/usage | assistant Message fields, UI display setting | OpenCode data source | OPENCODE WRAPPER | `components/chat/work-status`, `sync` docs |
| Provider quotas | 订阅额度、余额、时间窗口 | usage/quota UI | in-memory fetch result; provider credential stores | independent provider APIs | OPENCHAMBER OWNED | `lib/quota/` |
| Agents settings | agent markdown/config editing | `sections/agents` | OpenCode config files | OpenCode loads agent runtime | OPENCODE WRAPPER | `config-entity-routes.js` |
| Commands | slash command management | `sections/commands` | OpenCode config files | OpenCode resolves/executes commands | OPENCODE WRAPPER | `config-entity-routes.js` |
| MCP | server list/edit/runtime state | `sections/mcp` | OpenCode config files | OpenCode starts/uses MCP | OPENCODE WRAPPER | `config-entity-routes.js` |
| Skills / prompts / resources | skills editor/catalog, snippets | `sections/skills`, snippets | OpenCode skill roots/config; catalog config | OpenCode loads skills/prompts | MIXED | `skill-routes.js`, `skills-catalog/` |
| Plugins | plugin configuration | `sections/plugins` | OpenCode config | OpenCode plugin lifecycle | OPENCODE WRAPPER | `opencode/shared.js` |
| Behaviors | system prompt optimization and preferences | behavior sections | OpenChamber settings; generated plugin | injected only into managed OpenCode | OPENCHAMBER OWNED | `system-prompt/runtime.js` |
| Projects/workspaces | project labels, notes, todo, plan, worktrees | project sections/sidebar | OpenChamber project config; Git workspace | Session directory binds to OpenCode | MIXED | `project-context/`, `projects/` |
| Git / diff / worktrees | diff review, branches, commits/rebase/merge | GitView/DiffView | server Git service; UI git cache | none for core Git ops | OPENCHAMBER OWNED | `lib/git/service.js` |
| Files | tree/editor/read/write/upload/reveal | FilesView | server file APIs; view state | no OpenCode dependency | OPENCHAMBER OWNED | `lib/fs/routes.js` |
| Terminal | interactive PTY and tabs | TerminalView | server PTY/scrollback; UI tab state | no OpenCode dependency | OPENCHAMBER OWNED | `lib/terminal/runtime.js` |
| Preview/browser control | preview server/browser panel/agent page control | browser components | browser broker / Electron panel | agent tool may call OpenChamber API | OPENCHAMBER OWNED | `browser-control/`, `agent-tool/` |
| GitHub integration | issue/PR context, checks, review actions | GitHub dialogs/PR view | OpenChamber auth/config | optional prompt context only | OPENCHAMBER OWNED | `lib/github/` |
| Notifications | web push, APNs, desktop notices | notification settings | subscriptions/token stores | triggered from OpenCode events | MIXED | `notifications/runtime.js` |
| Voice/dictation | speech input/output | voice/dictation UI | local state, server dictation/TTS | independent | MIXED | `voice-store.ts`, `dictation/`, `tts/` |
| Remote instances | choose direct/SSH/relay host | `RemoteInstancesPage` | runtime endpoint configuration | endpoint exposes OpenCode through server | OPENCHAMBER OWNED | `runtime-switch.ts`, `client-auth/` |
| External tunnel | Cloudflare/ngrok public exposure | TunnelSettings | server settings/profiles | none | OPENCHAMBER OWNED | `tunnels/` |
| Private Relay / pairing | QR pairing and off-LAN control | onboarding/remote UI | client token + pairing/relay identity files | transports API to OpenChamber, then proxy | OPENCHAMBER OWNED | `relay/`, `client-auth/` |
| Updater | check/download/apply updates | update UI | platform updater state | none | PLATFORM ONLY / server glue | `openchamber-routes.js`, Electron `main.mjs` |
| General / Appearance / Chat / Notifications / Sessions / Shortcuts / Voice settings | preferences | `sections/openchamber/OpenChamberPage.tsx` | `settings.json`, plus local UI state | usually none | MIXED | `settings-runtime.js`, `persistence.ts` |
| Integrations / Usage / Projects / Remote / Tunnel / Git settings | configuration pages | sections directories | per-domain stores/files | varies by row above | MIXED | `components/sections/` |

## Settings coverage

Actual OpenChamber settings component files include `DefaultsSettings`, `OpenChamberVisualSettings`, `OpenCodeCliSettings`, `NotificationSettings`, `SessionRetentionSettings`, `KeyboardShortcutsSettings`, `VoiceSettings`, `GitSettings`, `GitHubSettings`, `DesktopNetworkSettings`, `TunnelSettings`, `PasskeySettings`, `AppLinkSecuritySettings`, `OpenChamberToolsSettings` and the Agents/Behavior/Commands/MCP/Plugins/Projects/Providers/Skills/Usage/Remote Instances sections. Evidence: `packages/ui/src/components/sections/{openchamber,agents,behavior,commands,mcp,plugins,projects,providers,remote-instances,skills,usage}`.

“Resources / Prompts” are not one confirmed standalone Settings page in the inspected source. Snippets are managed under `config-entity-routes.js`; skills have their own routes and catalog. Additional OpenCode resources are `UNKNOWN / NEEDS FURTHER VERIFICATION`.
