# P17 Codebase Intelligence

## Scope

P17 adds a bounded, read-only code intelligence layer for Coding Agents. It does not change the protocol, provider contracts, P15 tool semantics, VCR fixtures, or long-term storage.

## Design

`CodeIntelligence` is the single query facade. Every query refreshes the existing `ProjectScanner` and `ProjectPageStore`, so edited, renamed, and removed files update the fallback index before a result is returned.

1. `LSPClient` is the semantic source of truth for Swift when SourceKit-LSP is available.
2. `ProjectSymbolIndex` and `ProjectReferenceIndex` provide deterministic Swift fallback for symbol, definition, reference, and dependency queries.
3. `ContextPager` ranks related source, documentation, and reference pages and enforces an explicit character budget.
4. `ProjectScanner` supplies the on-demand repository map and retains its existing sensitive-path, binary-file, generated-directory, and maximum-file-size guards.

No repository map is injected permanently into a prompt. `repo_map` returns only aggregate file/language/root summaries. `context` returns paths and a bounded character count; the normal pager remains responsible for actual context materialization.

## LSP Lifecycle

`LSPClient` serializes a JSON-RPC stdio connection behind an actor.

- `start(workspace:)` starts the discovered SourceKit-LSP binary, sends `initialize` then `initialized`, and records `ready` only after that handshake succeeds.
- Swift source is opened or changed before position-based requests.
- `workspace/symbol`, definition, references, document symbols, and pull diagnostics are requested through the same connection.
- A failed request, malformed frame, EOF, or process crash stops the transport and marks the client `degraded`.
- A subsequent query retries initialization. If it remains unavailable, the query falls back instead of failing the Agent loop.

SourceKit-LSP discovery uses an explicit `LINGXI_SOURCEKIT_LSP`, `DEVELOPER_DIR`, or standard Xcode paths. The child receives the existing sanitized environment and never receives LingXi secrets.

## Agent Tool

`code_intelligence` is an opt-in built-in tool enabled with `agent.codeIntelligenceEnabled: true`. The default is `false` so frozen Provider requests and Golden replay remain byte-compatible. It is read-only and uses the existing search timeout, permission, output, and structured result path.

Actions:

| Action | Result |
| --- | --- |
| `symbols` | Workspace symbol search, LSP first then project index |
| `definition` | Definition locations for a source position |
| `references` | Incoming reference locations for a source position |
| `document_symbols` | Symbols for one document |
| `diagnostics` | LSP diagnostics when available |
| `repo_map` | Compact file/language/root summary |
| `context` | Ranked paths within `maximum_characters` (maximum 32,768) |

`symbol_lookup`, `find_references`, and `dependency_query` remain unchanged as compatible fallback tools. File/module dependency edges continue to come from `ProjectReferenceIndex` and are expanded by `ContextPager` during retrieval.

## Language Handling

The repository currently has Swift production code and SourceKit-LSP is the configured semantic backend. Unknown languages are scanned safely, remain available to lexical ranking and repository map queries, and return empty semantic symbols/diagnostics rather than erroring or blocking the agent.

## Bounded Retrieval

`ContextPager` already caps the model-side project context with `l1ProjectMaxCharacters`; the P17 tool applies a caller-specified cap before returning a context manifest. Search candidates are ranked using exact/qualified symbol matches, prefix matches, lexical terms, source/document priority, and one-hop indexed reference/dependency pages. L2 is a bounded LRU; L3 is rebuilt incrementally only for changed files.
