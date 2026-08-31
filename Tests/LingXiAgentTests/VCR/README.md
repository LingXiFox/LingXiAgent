# Test-only VCR

The VCR harness replaces only `ProviderHTTPTransport`. `AgentRuntime`, `SessionRuntime`, context paging/compaction, tools and permissions, MCP paging/leases, subagents, questions, skills, persistence, DataPlane, Provider adapters, and SSE decoders remain real.

## Modes

- `record`: real Provider transport plus sanitized cassette recording.
- `replay`: cassette only; no upstream transport is constructed.

Replay defaults to `instant`. Set `LINGXI_VCR_TIMING=timed` to reproduce recorded relative event delays. `LINGXI_VCR_CASSETTE_DIR` is the only explicit Replay source; otherwise the repository Golden is used. `LINGXI_VCR_OUTPUT` is record-only.

## Record full-core-stack-v1

Always record into an empty staging directory outside the repository. Never place a key in a file or command argument; inject it only into the test process environment.

Required test inputs:

- `LINGXI_VCR_BASE_URL`
- `LINGXI_VCR_API_KEY`
- `LINGXI_VCR_MODEL`
- `LINGXI_VCR_WIRE_PROTOCOL`: `chatCompletions`, `responses`, or `anthropicMessages`
- `LINGXI_VCR_COMMIT`: current `git rev-parse HEAD`
- `LINGXI_VCR_OUTPUT`: empty staging directory

Run only the scenario:

```sh
LINGXI_VCR_MODE=record swift test --filter FullCoreStackV1Tests
```

The harness never records authorization headers. It normalizes model, AgentRun IDs, Provider response IDs, `item_id`, `call_id`, UUIDs, timestamps, workspace paths, home paths, request IDs, and opaque encrypted content while preserving ID relationships.

## Promotion gate

1. Run the recorder into staging.
2. Run a secret scan over `manifest.json`, `provider.jsonl`, and `interactions.jsonl`.
3. Unset all Provider variables and delete the temporary credential injection.
4. After explicit human approval, promote the three reviewed files into `Cassettes/Scenarios/full-core-stack-v1/`.
5. Disable network access and run `swift test --filter FullCoreStackV1Tests` from a clean temp DataRoot.
6. Promote the cassette only if strict matching consumes every Provider exchange and the full replay passes.

`CassetteMismatch` is raised for wire, model, step, logical run sequence, normalized request, tool schema/state, or question mismatches. The harness never falls through to the next response.
