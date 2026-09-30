# Browser delivery decision — 2026-09-30

## Decision

Stop the Chrome-style CEF-in-SwiftUI native-parent experiment for the current milestone. Use the existing Playwright dependency with a separately managed visible Chromium browser as the proposed desktop delivery path. Keep GUI/Core integration and iOS GUI work independent of future embedded-browser research.

This supersedes the previous report's proposal to try changing the native embedded browser to Chrome style. It does not claim that all CEF embedding approaches are impossible.

## Verified CEF limitation

The tested SDK maps to CEF commit `682c378`. Its [macOS window-info contract](https://github.com/chromiumembedded/cef/blob/682c378/include/internal/cef_types_mac.h#L140) states that a native parent view forces Alloy. The matching [browser creation implementation](https://github.com/chromiumembedded/cef/blob/682c378/libcef/browser/browser_host_create.cc#L203) disables Chrome style when a parent handle is supplied on macOS, then resets the runtime style to Alloy.

The archived SwiftUI prototype uses `SetAsChild(parent, bounds)`. Setting Chrome style in that same path therefore cannot preserve the Views/Chrome configuration that passed the earlier popup checks. A source-contract check against both pinned files passed. A fresh Chrome-in-SwiftUI binary was **NOT RUN** because that specific route is explicitly unsupported, rather than an unresolved compile or rendering issue.

Official Views/Chrome remains a supported separate-window route. Reparenting its native views or changing the GUI window owner is a different design with unverified lifecycle behavior; it is outside this bounded validation. No patched CEF, private APIs, off-screen streaming renderer, or additional dependencies were introduced.

## Fresh external Chromium check

Signed installed Google Chrome 153.0.8010.53 and existing Playwright 1.63.0 were used with a visible browser, a fresh temporary profile, a localhost fixture, `chromiumSandbox: true`, and the test-only mock-keychain flag. No real login or personal browser profile was used by the test driver.

| Check | Result |
| --- | --- |
| Three consecutive automatic popup/input/submit/close cycles | PASS |
| Main-page automated input and submission | PASS |
| Second automated input with unchanged document ID | PASS |
| `context.close()` and probe process completion | PASS; exit 0 |
| Native user input / user-to-Agent handoff | NOT RUN |
| GUI/Core product permission chain | NOT RUN |
| iOS implementation / GPU / IME | NOT RUN |

The initial native-input attempt could not bind CUA to the isolated Chrome process: CUA selected the already running personal Chrome instance. No input actions were performed in that instance. The native probe then hit its 120-second test deadline and closed its own context. This harness limitation is retained in the evidence; it is not scored as a browser engine failure. The successful second run was explicitly automation-only. Its `agentResumeSameDocument` result field means a second automated edit, not a verified human handoff.

## Delivery implications

- Core should own browser sessions and execute browser actions through the host. The existing `BrowserSessionManager`, `BrowserHostClient`, `BrowserSessionStatus`, and capture query provide an existing base to extend; there is no need to replace the entire framework for this milestone.
- First desktop delivery can open the Agent's actual page in the managed browser window. GUI should display session status and capture on demand, then add explicit pause/resume, cancellation, and user takeover. The current read-only projection does not yet supply those controls.
- A GUI WKWebView navigated to the same URL would be a different document and login state. It must not be presented as the Agent's live page. A live embedded interactive browser is deferred, which is a visible product compromise of this delivery path.
- iOS GUI can proceed with the shared protocol and mock runtime. The proposed first real connection is to a desktop/server Core owning the browser. Local on-device browser-use is a separate capability that has not been validated; this decision does not promise a local Chromium/Node backend on iOS.
- Desktop computer-use remains a separate backend and permission problem; these browser results do not validate it.

No GUI/Core/TUI/sidecar code was changed in this validation. The tracked worktree diff SHA-256 remained `1ca577d1d7ee7a3ee0ad61ec5914e4599da3584643d7da9a711ae61a218d5b10`. Existing work and prior reports were preserved; no commit or push was performed.

[Structured evidence](browser-delivery-feasibility-2026-09-30/verdict.json), logs, screenshot, pinned source files, and reproduction scripts are archived together. Disposable test profiles and scripts were cleaned after verifying that the test processes stopped.
