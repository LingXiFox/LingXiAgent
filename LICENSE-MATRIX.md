# LingXiAgent License Matrix
# LingXiAgent 许可证适用范围矩阵

Copyright (c) 2026 LingXiFox. This file is the **authoritative** list of SPM
targets and non-SPM paths in this repository together with the license that
governs each of them. `LICENSE`, `LICENSE-CORE`, and `LICENSE-FRONTEND` all
reference this file for their scope; the license text itself lives in those
three files.

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
| `LingXiProtocol` | `Sources/LingXiProtocol` | LCSAL-1.0 | Source: no; binary: no | Wire contracts shared by Core and every frontend. |
| `LingXiPlatform` | `Sources/LingXiPlatform` | LCSAL-1.0 | Source: no; binary: no | OS abstractions (process, file, network, terminal, secure storage, desktop). |
| `LingXiApplication` | `Sources/LingXiApplication` | LCSAL-1.0 | Source: no; binary: no | Application state, reducers, session catalog, streaming projection. |
| `LingXiClient` | `Sources/LingXiClient` | LCSAL-1.0 | Source: no; binary: no | VNext and stdio clients every frontend uses to reach CoreHost. |
| `LingXiCore` | `Sources/LingXiCore` | LCSAL-1.0 | Source: no; binary: no | Agent runtime authority: sessions, runs, tools, providers, MCP, plugins. |
| `CSQLite` | `Sources/CSQLite` | LCSAL-1.0 (binding) | Source: no; binary: no | SQLite3 C shim; upstream sqlite3 is public domain. |
| `LingXiPluginSDK` | `Sources/LingXiPluginSDK` | LCSAL-1.0 | Source: no; binary: no | Plugin authoring SDK. Plugin authors' own code is separately licensed. |
| `LingXiCoreHost` | `Sources/LingXiCoreHost` | LCSAL-1.0 | Source: no; official release binary only (forwarded as-is, non-commercial) | The only shipped process that reads `LINGXI_CREDENTIALS_PASSPHRASE`. |
| `lingxiagent` | `Sources/lingxiagent` | Presentation under PolyForm Noncommercial 1.0.0; embedded Core under LCSAL-1.0 | Source: yes (PolyForm part only); official release binary only (forwarded as-is) | Unified CLI. Presentation layer is PolyForm; the linked Core remains LCSAL. |
| `OpenTUIShim` | `Sources/OpenTUIShim` | Upstream OpenTUI license | Follow upstream | C dylib shim around `Vendor/OpenTUI/`. |
| `LingXiTUIComponents` | `Sources/LingXiTUIComponents` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Rendering primitives shared by TUI surfaces. |
| `LingXiTUI` | `Sources/LingXiTUI` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Reference terminal frontend. |
| `LingXiTUIApp` | `Sources/LingXiTUIApp` | PolyForm Noncommercial 1.0.0 | Source: yes; official release binary only | Executable wrapper for the TUI. |
| `LingXiFrontendKit` | `Apps/LingXiApp/Shared` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | SwiftUI shared component library (Phase 0 gate). |
| `FoxPlugin` | `Plugins/FoxPlugin` | PolyForm Noncommercial 1.0.0 | Source: yes; binary: no (mods are source-only) | Demo plugin; a template for external plugin authors. |
| `LingXiAgentTests` | `Tests/LingXiAgentTests` | Not shipped | n/a | Test target only. |

---

## Non-SPM paths

These directories are also license-scoped but not represented as `Package.swift`
targets. They must not be added as SPM targets without first being entered in
the table above.

| Path | License | Distribution | Notes |
|---|---|---|---|
| `Vendor/OpenTUI/` | Upstream (GPLv3 / Ghostty / MIT — see per-file headers) | Follow upstream | Vendored dynamic library and headers. |
| `Apps/LingXiApp/macOS` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | Xcode SwiftUI macOS app target. |
| `Apps/LingXiApp/iOS` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | Xcode SwiftUI iOS app target. Not an officially supported release surface. |
| `Sidecars/browser-host/` | PolyForm Noncommercial 1.0.0 | Source: yes; mods binary-restricted | Node.js browser host sidecar. |
| `Server/agent-site/`, `Server/models-site/` | PolyForm Noncommercial 1.0.0 (public site content) | Source: yes; static hosting permitted with attribution | Official website static assets. |
| `Server/lingxi-registry/`, `Server/registry/`, `Server/deploy/` | LCSAL-1.0 | No | Backend services (Go) and deployment configuration. |
| `Scripts/`, `install.sh`, `install.ps1` | LCSAL-1.0 | No (build/install infrastructure) | Build, packaging, CI, and installer scripts. |
| `Docs/` | CC-BY-4.0 unless a file says otherwise | Attribution required | Documentation, research notes, and ADRs. |
| `Benchmarks/`, `Evals/Tasks/`, `Evals/Baselines/` | CC0 / public domain where possible | Freely reusable | Evaluation fixtures, task manifests, and baseline result sets. |

---

## Adding a target

When a new SPM target is introduced:

1. Add its row to the SPM-targets table above.
2. Choose either LCSAL-1.0 (core infrastructure / runtime authority) or
   PolyForm Noncommercial 1.0.0 (frontend, presentation, or plugin).
3. If neither fits, add a note explaining the exception and open a discussion
   with @LingXiFox before merging.

`LicenseMatrixDriftTests` will fail until the row is present.
