# Appearance 与 UI

OpenChamber UI is React shared across web, Electron, mobile and VS Code surface-specific layouts. It is not a reusable native macOS visual layer.

## Current appearance data

| Preference | Owner/storage | Notes |
| --- | --- | --- |
| dark/light and visual preferences | OpenChamber settings + UI persistence | UI preference, not Agent data |
| custom themes | `~/.config/openchamber/themes/<name>.json` or `<dir>/theme.json` | server validates/serves theme assets |
| wallpaper assets | directory theme `assets/` via validated route | server rejects traversal, URL, symlink escape, non-PNG/JPEG and >12 MiB |
| desktop background images | Electron managed assets / runtime-scoped setting | local Electron-only function |
| typography/code theme/animation | UI tokens/settings where applicable | client presentation |
| terminal colors | client sends active appearance to terminal create/update | platform presentation, not business state |

Source: `opencode/theme-runtime.js`, `OpenChamberVisualSettings.tsx`, `packages/electron/background-appearance.mjs`, `terminal/DOCUMENTATION.md`.

## Separation

Appearance settings do not control OpenCode Session/Agent/provider semantics. The only expected cross-boundary effect is terminal color environment/query response and desktop local wallpaper protocol. Theme assets are served through an explicit allowlisted route rather than generic file serving.

## LingXiFox changes

The fork adds appearance schema/safe theme assets and Desktop workspace background infrastructure. Git evidence: `fb4dcc2c5` (`feat(theme)`), `d2cf43a6a` (`feat(desktop)`), `9a957a739` (`fix(desktop)`); added files include `packages/electron/background-appearance.mjs` and `packages/ui/src/hooks/useDesktopBackgroundAppearance.ts`. Treat these as `LINGXI MODIFICATION`, not upstream facts.

The fork also adds motion foundation and semantic agent activity visuals (`f77e17df0`, `b3ee036f4`), including `useAgentActivity`, `useStabilizedAgentActivity`, orb/presentation helpers and `StateSwap` UI. These consume existing status signals; they do not add a separate Agent runtime.
