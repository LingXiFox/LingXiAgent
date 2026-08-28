# LingXiFox 与 upstream 分离

## Method

This classification uses read-only Git evidence:

- fork baseline tag `lingxi-baseline-20260819` resolves to `2db90f74d` (`fix: settle busy sessions after managed OpenCode restart (#3002)`);
- `git diff upstream/main...HEAD` reports 198 changed files, 11,574 additions and 912 deletions at research time;
- current branch history contains 105 commits after the baseline.

It does not label every surrounding upstream feature as downstream merely because it exists in this checkout.

## Confirmed LingXi modifications

| Area | Evidence | Classification |
| --- | --- | --- |
| downstream product identity/release/build workflows | `afd6b754a`, `60bec91e`, `RELEASE_BASE.md`, remote macOS scripts | LINGXI MODIFICATION |
| Sub2API quota provider and account scoping | `8e733a91c`, `26373096a`, `8ef8fa27`, `packages/web/server/lib/quota/providers/sub2api.js` | LINGXI MODIFICATION |
| custom provider API protocols and z.ai quota change | `1d853a9b`, `b010c4df` | LINGXI MODIFICATION |
| safe custom themes and theme assets | `fb4dcc2c`, `theme-runtime` changes/tests | LINGXI MODIFICATION |
| Electron workspace background | `d2cf43a6`, `9a957a73`, `background-appearance.mjs` | LINGXI MODIFICATION |
| patch graph / branch health / release tags | `51689e7b`, added Git UI/server files | LINGXI MODIFICATION |
| agent-activity presentation and motion | `f77e17df`, `b3ee036f` and added UI files | LINGXI MODIFICATION |
| documentation, guards and skills | downstream README, AGENTS/workflows | LINGXI MODIFICATION |

## Do not over-classify

The range also contains upstream merges. Features visible in HEAD but not directly attributable to a downstream-only commit/file should be marked `UPSTREAM OPENCHAMBER` only after checking ancestry/blame for the precise symbol. This includes much of Session sync, Relay, server lifecycle and existing Settings UI. `UNKNOWN` is safer than treating a merged upstream patch as LingXi work.

## Practical rule for the remaining research

For a capability in this document set:

- label `LINGXI MODIFICATION` only when the net diff and/or a downstream commit identifies it;
- label `UPSTREAM OPENCHAMBER` only when its ancestor evidence is clear;
- otherwise label `UNKNOWN` rather than guessing.
