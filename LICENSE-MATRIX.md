# LingXiAgent License Matrix
# LingXiAgent 许可证适用范围矩阵

Copyright (c) 2026 LingXiFox. This file is the **authoritative** list of SPM targets and
non-SPM paths in this repository together with the license that governs each of them.
`LICENSE`, `LICENSE-CORE` and `LICENSE-FRONTEND` reference this file for their scope; the
license text itself lives in those files.

The three license texts are unchanged from 1.x. This matrix was rebuilt for 2.0 on
2026-10-19 (Phase 0.1) and now registers only what actually exists in this working tree;
the 1.x rows were removed rather than carried over, because 2.0 starts from a clean
foundation and declares targets incrementally.

The Chinese text of any legal clause prevails over the English translation in case of
conflict.

Tracks in use:

| Track | Text file | Applies to |
|---|---|---|
| LCSAL-1.1 | `LICENSE-CORE` | Agent runtime authority, hosts, shared protocol contracts, platform layer |
| PolyForm Noncommercial 1.0.0 | `LICENSE-FRONTEND` | Presentation surfaces and **official** plugins |
| CC-BY-4.0 | — | `Docs/` |
| CC0 / public domain | — | `Evals/Tasks/`, `Evals/Baselines/` fixtures where possible |

---

## SPM targets (`Package.swift`)

| Target | Path | License | Third-party redistribution | Notes |
|---|---|---|---|---|
| `LingXiKernel` | `Sources/LingXiKernel` | LCSAL-1.1 | Source: no; binary: no | Minimal agent kernel: loop, single context, run state, durable event log. Contains no provider, no tool implementation and no plugin loading code — that absence is enforced by the L0 gate, not by convention. |
| `LingXiCoreHost` | `Sources/LingXiCoreHost` | LCSAL-1.1 | Source: no; official release binary only (forwarded as-is, non-commercial) | The shipped Core process. Once the credential store lands it will be the only process that reads the credentials passphrase. |
| `LingXiKernelTests` | `Tests/LingXiKernelTests` | Not shipped | n/a | Test target only. |
| `LingXiPluginABIC` | `Sources/LingXiPluginABIC` | MIT (`LICENSE-ABI`) | Yes, verbatim | The C half of the ABI: the header plus one translation unit. Separate because a Swift target cannot export C structs and `@convention(c)` needs them. |
| `LingXiPluginABI` | `Sources/LingXiPluginABI` | MIT (`LICENSE-ABI`) | Yes, verbatim | The published plugin contract: the C header plus the Core↔Host wire types. Open on purpose — a closed ABI header would leave community authors reading a licence that forbids what they are doing. Declared by the owner on 2026-10-20. |
| `LingXiPluginHost` | `Sources/LingXiPluginHost` | LCSAL-1.1 | Source: no; official release binary only (forwarded as-is, non-commercial) | The generic `dlopen` host. Contains no plugin code and no vendor knowledge; one process per plugin. |
| `LingXiPluginRuntime` | `Sources/LingXiPluginRuntime` | LCSAL-1.1 | Source: no; binary: no | Core-side supervisor: registry, process lifecycle, IPC client, and the adapters that present plugin capabilities through kernel ports. It is the only module that knows a plugin exists. |
| `LingXiContextProbe` | `Plugins/LingXiContextProbe` | PolyForm Noncommercial 1.0.0 | Source: no; binary: no | Official example plugin used by the L2 contract tests: one `contextPrepare` hook that rewrites the request. Third-party authors write against the same ABI and the same manifest. |
| `LingXiCProbe` | `Plugins/LingXiCProbe` | PolyForm Noncommercial 1.0.0 | Source: no; binary: no | The same capability written in plain C, so the ABI is proven cross-language rather than asserted. |
| `DeepSeekProvider` | `Plugins/DeepSeekProvider` | PolyForm Noncommercial 1.0.0 | Source: no; binary: no | First real provider plugin. DeepSeek Responses API over SSE, normalized to the provider wire events; cassette replay for offline tests. |
| `ContractTests` | `ContractTests` | Not shipped | n/a | L2 contract gate: real Host process, real `dlopen`, real fault injection. |

---

## Non-SPM paths

These paths are license-scoped but not represented as `Package.swift` targets. They must not
be added as targets without first being entered in the table above.

| Path | License | Distribution | Notes |
|---|---|---|---|
| `Docs/` | CC-BY-4.0 unless a file says otherwise | Attribution required | Design documents, decisions and the regression ledger. |
| `Examples/` | — | — | Placeholder only; it becomes license-scoped when a plugin example target is added. |
| `Scripts/` | LCSAL-1.1 | No (development tooling) | Build, CI and provider smoke/recording scripts. |
| `Package.swift`, `.swift-version`, `.gitignore`, `.gitattributes` | LCSAL-1.1 | No (build infrastructure) | Follows the Core track, as in 1.x. |
| `LICENSE`, `LICENSE-CORE`, `LICENSE-FRONTEND`, `LICENSE-ABI`, `LICENSE-MATRIX.md` | — | — | The licensing documents themselves. |

---

## Intended but not yet declared

Listing a target here has **no** licensing effect and must not be treated as registered; it
exists so the phase plan does not silently invent a track later. Each of these gets moved
into the SPM table in the same commit that adds it to `Package.swift`.

| Planned target | Expected track | Phase |
|---|---|---|
| `LingXiPlatform` (Darwin process, file, terminal, secure storage) | LCSAL-1.1 | 2 |
| Further official plugins under `Plugins/` | PolyForm Noncommercial 1.0.0 | 2-3 |
| Frontend protocol and TUI targets | PolyForm Noncommercial 1.0.0 | 4 |

`LingXiPluginABI`, `LingXiPluginHost`, `LingXiPluginRuntime` and the first example plugin were
declared in the SPM table during Phase 2, together with the `ContractTests` target that
`Project-Conventions.md` §二 mandates.

### Official plugins versus third-party plugins

The distinction the 2.0 product needs is between *our* plugins and *anyone else's*:

- **Official plugins** live in this repository, are registered in the SPM table above, and
  ship under PolyForm Noncommercial 1.0.0 like the frontends.
- **Third-party plugins** are not part of this repository at all. Their source and binary
  licensing belongs to their authors; LingXiAgent only specifies the `.lxap` bundle
  requirements, the C ABI conformance and the signature policy for loading them. This matrix
  must never claim a license over them.
- The **plugin ABI header and example projects** are the one gray area: they are our
  copyright, but a noncommercial-only track would make commercial third-party authoring
  impossible. This is `Project-Conventions.md` 第八章's open item and needs the owner's
  decision before the first plugin target is declared.

---

## Adding a target

1. Add its row to the SPM-targets table above, in the same commit that touches `Package.swift`.
2. Choose the track that fits: LCSAL-1.1 for runtime authority and infrastructure, PolyForm
   Noncommercial 1.0.0 for presentation and official plugins. Anything else needs a note
   explaining the exception and a discussion with @LingXiFox before merging.
3. Do not edit the license texts to fit a new target; the texts are fixed and the matrix
   assigns scope.

Drift guard: `L0_licenseMatrixMatchesDeclaredTargets` in `Tests/LingXiKernelTests/GatesTests.swift`
fails when the set of targets in `Package.swift` diverges from the SPM-targets table above. In
1.x this guard ran as `LicenseMatrixDriftTests` across three platforms; 2.0 is single-platform,
so one check is enough.
