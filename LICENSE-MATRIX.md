# LingXiAgent License Matrix
# LingXiAgent 许可证适用范围矩阵

Copyright (c) 2026 LingXiFox. This file is the **authoritative** list of SPM
targets and non-SPM paths in this repository together with the license that
governs each of them. `LICENSE`, `LICENSE-CORE`, `LICENSE-FRONTEND`, and
`LICENSE-SDK` all reference this file for their scope; the license text itself
lives in those files.

The Chinese text of any legal clause prevails over the English translation in
case of conflict.

CI guard: `LicenseMatrixDriftTests` (Stage 2, macOS + Linux + Windows) fails
the build when the set of SPM targets declared in `Package.swift` diverges
from the set listed under "SPM targets" below. Adding a new target without a
license row is a build failure, not a review note.

---

## SPM targets (`Package.swift`)

| Target | Path | License | Third-party redistribution | Notes |
|---|---|---|---|---|
| `LingXiProtocol` | `Sources/LingXiProtocol` | LCSAL-1.1 | Source: no; binary: no | Wire contracts shared by Core and every frontend. |
| `LingXiPlatform` | `Sources/LingXiPlatform` | LCSAL-1.1 | Source: no; binary: no | OS abstractions (process, file, network, terminal, secure storage, desktop). |
| `LingXiApplication` | `Sources/LingXiApplication` | LCSAL-1.1 | Source: no; binary: no | Application state, reducers, session catalog, streaming projection. |
| `LingXiClient` | `Sources/LingXiClient` | LCSAL-1.1 | Source: no; binary: no | VNext and stdio clients every frontend uses to reach CoreHost. |
| `LingXiCore` | `Sources/LingXiCore` | LCSAL-1.1 | Source: no; binary: no | Agent runtime authority: sessions, runs, tools, providers, MCP, plugins. |
| `CSQLite` | `Sources/CSQLite` | LCSAL-1.1 (binding) | Source: no; binary: no | SQLite3 C shim; upstream sqlite3 is public domain. |
| `LingXiPluginSDK` | `Sources/LingXiPluginSDK` | MIT (`LICENSE-SDK`) | Source: yes; binary: yes — including inside closed-source plugins | Plugin authoring SDK. Foundation-only by gate (`PluginSDKDependencyGateTests`); it carries no Core, Session, Permission or P/E implementation. Plugin authors' own code is separately licensed. |
| `LingXiModelSDK` | `Sources/LingXiModelSDK` | MIT (`LICENSE-SDK`) | Source: yes; binary: yes — including inside closed-source products | Public model-catalog SDK: the developer interface for `models.lingxifox.cn/models.json`. Depends on Foundation only, never on the Agent runtime. Commercial use, third-party agent/app integration, modification, source and binary redistribution, and closed-source linking are all permitted; the only obligation is keeping the copyright and license notice. |
| `LingXiCoreHost` | `Sources/LingXiCoreHost` | LCSAL-1.1 | Source: no; official release binary only (forwarded as-is, non-commercial) | The only shipped process that reads `LINGXI_CREDENTIALS_PASSPHRASE`. |
| `lingxiagent` | `Sources/lingxiagent` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Interactive terminal presentation frontend (strictly decoupled from Core). |

| `lingxiagent-ops` | `Sources/lingxiagent-ops` | LCSAL-1.1 | Source: no; official release binary only (forwarded as-is) | Operations and diagnostics CLI (links Core for offline administration). |
| `OpenTUIShim` | `Sources/OpenTUIShim` | Upstream OpenTUI license | Follow upstream | C dylib shim around `Vendor/OpenTUI/`. |
| `LingXiTUIComponents` | `Sources/LingXiTUIComponents` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Rendering primitives shared by TUI surfaces. |
| `LingXiTUI` | `Sources/LingXiTUI` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Reference terminal frontend. |
| `LingXiTUIApp` | `Sources/LingXiTUIApp` | PolyForm Noncommercial 1.0.0 | Source: yes; official release binary only | Executable wrapper for the TUI. |
| `LingXiWebUI` | `Sources/LingXiWebUI` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Browser frontend and the `serve` HTTP/SSE host that drives the shared frontend contract. |
| `LingXiFrontendKit` | `Apps/macOS/FrontendKit` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | SwiftUI component library for the macOS GUI. Not platform-neutral: three DesignSystem files import AppKit ungated. |
| `LingXiMacApp` | `Apps/macOS` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | macOS native executable entry point. |
| `FoxPlugin` | `Plugins/FoxPlugin` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Demo plugin; a template for external plugin authors. |
| `LingXiModelSDKTests` | `Tests/LingXiModelSDKTests` | Not shipped | n/a | Test target only; its dependency closure is the SDK alone, which is what makes the web-example compile gate possible. |
| `LingXiPluginSDKTests` | `Tests/LingXiPluginSDKTests` | Not shipped | n/a | Plugin SDK contract, snapshot and documentation-example gates; its dependency closure is the SDK alone. |
| `LingXiAgentTests` | `Tests/LingXiAgentTests` | Not shipped | n/a | Test target only. |
| `LingXiWireContractTests` | `ContractTests/LingXiWireContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiFrontendContractTests` | `ContractTests/LingXiFrontendContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiPlatformContractTests` | `ContractTests/LingXiPlatformContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiIPCRobustnessContractTests` | `ContractTests/LingXiIPCRobustnessContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiTaskLifecycleContractTests` | `ContractTests/LingXiTaskLifecycleContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiCapabilityContractTests` | `ContractTests/LingXiCapabilityContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiTraceContractTests` | `ContractTests/LingXiTraceContractTests` | Not shipped | n/a | Contract test target only. |
| `LingXiEvalRunner` | `Evals/Runner` | PolyForm Noncommercial 1.0.0 | Source: yes; official release binary only | Independent evaluation runner decoupled from Core. |

---

## Non-SPM paths

These directories are also license-scoped but not represented as `Package.swift`
targets. They must not be added as SPM targets without first being entered in
the table above.

| Path | License | Distribution | Notes |
|---|---|---|---|
| `Vendor/OpenTUI/` | Upstream (GPLv3 / Ghostty / MIT — see per-file headers) | Follow upstream | Vendored dynamic library and headers. |
| `Apps/macOS/LingXiMacApp.xcodeproj` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | Xcode project that builds and previews the macOS GUI. Not an SPM path: it links `LingXiFrontendKit` as a package product instead of compiling the sources itself. |
| `Apps/iOS/` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | iOS entry point source only. No build system currently compiles it, and `LingXiFrontendKit` is macOS-only, so it is not a supported release surface. |
| `Sidecars/browser-host/` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | Node.js browser host sidecar. |
| `Server/agent-site/`, `Server/models-site/` | PolyForm Noncommercial 1.0.0 (public site content) | Source: yes; static hosting permitted with attribution | Official website static assets. |
| `Server/deploy/` | LCSAL-1.1 | No | Deployment configuration (Caddy). The Go registry service and its data were retired with the unified model registry. |
| `Scripts/`, `install.sh`, `install.ps1` | LCSAL-1.1 | No (build/install infrastructure) | Build, packaging, CI, and installer scripts. |
| `Docs/` | CC-BY-4.0 unless a file says otherwise | Attribution required | Documentation, research notes, and ADRs. |
| `Benchmarks/`, `Evals/Tasks/`, `Evals/Baselines/` | CC0 / public domain where possible | Freely reusable | Evaluation fixtures, task manifests, and baseline result sets. |

---

## Adding a target

When a new SPM target is introduced:

1. Add its row to the SPM-targets table above.
2. Choose the track that fits: LCSAL-1.1 (core infrastructure / runtime
   authority), PolyForm Noncommercial 1.0.0 (frontend, presentation, or plugin),
   or MIT (`LICENSE-SDK`) for the public developer SDKs — the surfaces intended
   for third-party and commercial consumption (`LingXiModelSDK`, `LingXiPluginSDK`).
3. Anything else needs a note explaining the exception and a discussion with
   @LingXiFox before merging.

`LicenseMatrixDriftTests` will fail until the row is present.
