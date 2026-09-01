# P15 Coding Toolchain Acceptance

**状态：P15 READY**

## Provider Contract Boundary

- `ToolResult` rich internal fields：PASS
- `ModelToolResultProjection` pure provider-neutral projection：PASS
- OpenAI Chat / Responses / Anthropic use projection before wire encoding：PASS
- ToolCallID -> ToolResult.callID canonical correlation：PASS
- Provider external ID mapping remains adapter-local：PASS
- Repository Golden remains unmodified and replays from `cassetteSource=repository`：PASS

## Compatibility

- Legacy persisted `ToolResult` JSON missing P15 fields decodes with safe defaults: PASS
- Context and persistence retain full internal results: PASS
- MCP result handling and subagent correlation are unchanged: PASS
- No production VCR/cassette/replay conditional was added: PASS

## Validation

- `swift build`
- `swift test --filter CodingToolContractTests`
- `swift test --filter ToolResultProjectionTests`
- `swift test --no-parallel`
- `env -u LINGXI_VCR_CASSETTE_DIR -u LINGXI_VCR_OUTPUT LINGXI_VCR_MODE=replay swift test --filter FullCoreStackV1Tests/fullCoreStackV1`
- `swift test --no-parallel`：PASS，264 tests / 34 suites
- `swift test`：PASS
- repository Golden replay：10/10 PASS
- parallel full suite：10/10 PASS
- `git diff --check`
- Trivy vulnerability/misconfiguration/secret scan：0 findings

## Known Limits

- `rg` must be installed in a supported system location; no slow shell grep fallback is used.
- Sandbox guarantees are macOS `sandbox-exec` filesystem/network policy only; no process namespace or resource quota guarantee exists.
- Advanced range/search flags are accepted by the local runtime without changing frozen P14 provider tool schemas. Publishing them as a provider tool contract requires an intentional, versioned provider contract upgrade.
- VCR run aliases are scenario-local. Replay uses unique structural candidates to atomically bind logical child roles to runtime UUIDs before strict RunID comparison; aliases are never wildcarded or stripped.

## Deferred

P16 Agent Behavior and P17 LSP/Codebase Intelligence remain out of scope.
