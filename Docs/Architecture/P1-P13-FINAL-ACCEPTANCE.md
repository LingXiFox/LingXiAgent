# P1-P13 Final Acceptance

Updated: 2026-08-31

## Scope

This is the final P1-P13 acceptance record. No P14 Workflow, Goal, long-term memory, GUI, or remote runtime feature was implemented for this acceptance.

## Accepted

| Gate | Result | Evidence |
|---|---|---|
| Offline Golden replay | Pass | `FullCoreStackV1Tests/fullCoreStackV1` replays the repository cassette with network impossible. It covers three provider steps, built-in tools, MCP discovery/load/call, two concurrent child runs, question/answer, permission denial, restart, and persistence rehydration. |
| VCR containment | Pass | Replay only reads `LINGXI_VCR_CASSETTE_DIR` or the repository Golden; `LINGXI_VCR_OUTPUT` is Record staging only. Replay misses never invoke an upstream transport. |
| VCR fixture hygiene | Pass | Repository Golden manifest and payload are audited for required metadata, private paths, and credential-bearing fields. |
| Child-run durability | Pass | Child Session and initial AgentRun are committed atomically. Terminal run state and result are committed atomically. Regression tests cover injected failure, retry, restart, and parallel child creation. |
| Child model selection | Pass | Blank provider/model/reasoning inputs inherit the resolved endpoint. `provider_id` and `model_id` must be supplied together; complete requests are resolved and policy-checked. |
| Stdio bootstrap | Pass | Interactivity is explicitly controlled by `LINGXI_INTERACTIVE`; stdio does not infer it from unrelated process state. |
| Production boundary | Pass | Production sources contain no VCR/cassette implementation, and Provider HTTP transport remains an injected seam. |
| Credential vault | Pass | `credentials.vault` uses AES-256-GCM with PBKDF2-HMAC-SHA256 passphrase derivation. Legacy v1 plaintext vaults migrate to v2 and retain only an encrypted migration backup. |
| Real Provider acceptance | Pass | Real `gpt-5.6-terra` full-core-stack-v1 Record PASS completed; repository Golden Offline Replay PASS. |

## Verification

| Command or audit | Result |
|---|---|
| `swift test --no-parallel` | Pass: 243 tests, 29 suites. |
| `swift test` | Pass: 243 tests, 29 suites. |
| `swift test --no-parallel --filter 'VCRHarnessTests|FullCoreStackV1Tests/fullCoreStackV1'` | Pass: 19 tests, 2 suites. |
| `git diff --check` | Pass. |
| Trivy filesystem scan: vulnerabilities, misconfigurations, secrets | Pass: 0 findings. |
| Source-pattern audit for TODO/FIXME, `fatalError`, forced casts, forced try | Only static `NSRegularExpression` construction in `SwiftReferenceExtractor`; covered by extractor tests. |
| Hardcoded credential-value pattern audit | No findings. |

Semgrep MCP was unavailable in the connected tool set. The Trivy scan and source-boundary tests above were run instead.

## Known Limits

| Limit | Classification |
|---|---|
| `LINGXI_CREDENTIALS_PASSPHRASE` must be supplied before creating, reading an existing encrypted vault, or migrating a legacy vault | Explicit operator bootstrap requirement. |
| Anthropic OAuth and Builtin Provider metadata verification | P14 formal work. |

## P14 Status

**P14 READY**

The former plaintext-vault blocker is removed. The Final Seal verification table above passed; Provider/OAuth metadata verification is P14 work, not a P14 entry blocker.
