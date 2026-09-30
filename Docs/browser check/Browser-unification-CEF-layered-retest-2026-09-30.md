# CEF layered retest — 2026-09-30

The native Alloy popup and shutdown failures were reproduced outside the SwiftUI host. The official Views/Chrome path passed automatic popup handling and graceful shutdown in the final controlled run. Chrome-style SwiftUI embedding remains untested, so this is not product-integration acceptance.

| Configuration | Main/input | Native popup/input | Playwright new popup | Graceful process exit |
| --- | --- | --- | --- | --- |
| Official native Alloy | PASS | PASS | FAIL | FAIL |
| SwiftUI native Alloy | PASS | PASS | FAIL | FAIL |
| Official Views/Chrome | PASS | PASS | PASS | PASS in final controlled run |

## Configuration and isolation

- macOS 27.2 (26B5091g), arm64; Xcode-beta and Swift 6.4.
- Official standard CEF SDK: `154.0.32+g682c378+chromium-154.0.8037.58`, downloaded from the [official build service](https://cef-builds.spotifycdn.com/index.html). Archive SHA-1 matched `8147f08ca0a65b21227962c7273fcb3ef7174cae`.
- Existing project Playwright 1.63.0; no product dependency changes.
- Local ad-hoc signing and `codesign --verify --deep --strict` passed. This is not vendor notarization. CEF emitted a validation-category warning for the locally signed process; logs retain it.
- Controlled runs explicitly set `CefSettings.root_cache_path` and `cache_path` to fresh temporary directories; own localhost fixture only, `--use-mock-keychain`, no login or user browser profiles. Renderer accessibility was enabled for native verification.
- Native input and window actions used Codex CUA. Playwright tests connected over CDP to the same visible documents; document IDs remained unchanged across input and submission. Submitted clicks were trusted.

## Native Alloy lifecycle

The official source was first built unchanged. Its CLI `--root-cache-path` and `--cache-path` arguments did not populate the CEF settings; the default-cache warning and transient white popup from that exploratory run are preserved. Later controlled runs added explicit cache settings and lifecycle logging. The popup then displayed and accepted native input. The individual cause of the initial white popup is not established because profile isolation, AX, and observation logging changed together.

In the isolated official native Alloy run, Cmd+Q reached `DoClose` for both main and popup browsers. Neither `OnBeforeClose` nor `CefShutdown` appeared before cleanup, and the main process remained alive for more than ten seconds. SIGTERM cleanup is recorded as a failed graceful exit.

The minimal SwiftUI host reused the official client and native popup behavior. It embedded the browser container through `NSViewRepresentable` in `NSHostingView`. Main and popup input worked. On close, the main window released its SwiftUI content, but neither browser reached `OnBeforeClose`; SIGTERM cleanup was required. This reproduces a failure outside SwiftUI, but does not prove the custom host is free of additional ownership defects.

No synchronous popup-view teardown or Alloy-to-Chrome popup substitution was attempted. Previous failed experiments and crash reports remain unchanged.

## Playwright popup differential

The same input/submit/popup script was used for native Alloy, SwiftUI Alloy, and Views/Chrome.

- Both Alloy configurations passed same-document main input and trusted submission, then timed out during the popup click. No Playwright popup event arrived; the popup target retained an empty URL.
- The official native Alloy protocol log records the popup as `type: other`, `waitingForDebugger: true`. Playwright sent `Runtime.runIfWaitingForDebugger` (command 60), and no matching response arrived before the six-second click timeout. This matches the earlier popup symptom without the SwiftUI host.
- Official Views/Chrome produced a normal popup event, loaded `/popup`, accepted input, and passed trusted submission. Both browser documents were observed in the same context.

The runtime style and hosting API differ between native Alloy and Views/Chrome. These results narrow the failure to the tested Alloy/CDP path; they do not establish a single CEF implementation root cause or a universal Playwright incompatibility.

## Exit differential and evidence limits

The first Views/Chrome native run did not respond promptly to Cmd+Q or its Quit menu. Cmd+W closed both windows and emitted both `OnBeforeClose` callbacks, but shutdown was not observed before SIGTERM cleanup. That failure is preserved rather than discarded.

In the final Views/Chrome Playwright run, after driver disconnect, native Cmd+W closed the popup and main windows. Both `OnBeforeClose` callbacks, `CefShutdown begin`, and `CefShutdown end` were logged; the parent process exited with code **0**. No sample/helper processes remained after cleanup. This is one successful controlled exit, not a reliability stress test.

Chrome-style SwiftUI embedding, IME candidate composition, GPU profiling, and product integration were **NOT RUN**. No performance claim is added by this retest. Results apply to this CEF version, macOS beta, and local signing configuration.

The next bounded experiment is Chrome-style native embedding in SwiftUI, followed by the same popup and shutdown checks. If it fails, the already verified external Chromium/Playwright path remains the fallback. Product migration should wait for that result.

## Artifacts and product scope

[Evidence directory](browser-cef-layered-retest-2026-09-30/results.json) contains structured results, lifecycle/driver logs, popup screenshot, SDK manifest, and a reproduction source ZIP with pristine and modified sample files. `SHA256SUMS` covers the evidence files.

The tracked worktree diff hash before and after the experiment matched:

`1ca577d1d7ee7a3ee0ad61ec5914e4599da3584643d7da9a711ae61a218d5b10`

Only this report and its evidence were added. Existing product changes and previous reports were preserved. No commit or push was performed. Disposable SDK/build/profile/probe files and the local fixture server were removed after evidence verification.
