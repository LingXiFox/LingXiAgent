# P17 Codebase Intelligence Acceptance

## Deterministic Coverage

- `CodeIntelligenceTests/lspProvidesSemanticResultsAndRecoversAfterCrash`
  - Exercises workspace symbols, definition, document symbols, diagnostics, LSP crash degradation, and the next-query recovery path.
- `CodeIntelligenceTests/indexFallbackTracksMutationReferencesAndBoundedContext`
  - Verifies unavailable-LSP fallback, definition, references, incremental symbol replacement after mutation, and context budget enforcement.
- `CodeIntelligenceTests/repoMapAndUnknownLanguageDegradeWithoutFailure`
  - Verifies the compact repo map and graceful unknown-language behavior.
- `CodeIntelligenceTests/agentUsesBoundedCodeContextBeforeMutation`
  - Runs the Agent loop through `code_intelligence`, then a workspace mutation, proving structured context retrieval reaches an Agent modification flow.
- Existing `SymbolIndexTests`, `ReferenceIndexTests`, and `ProjectContextTests`
  - Cover stable indexing, file/module/symbol dependency edges, ranking, deletion, isolation, and L2/L3 budget bounds.

## Required Gates

| Gate | Result |
| --- | --- |
| `swift build` | PASS |
| P17 specialist tests | PASS |
| `swift test --no-parallel` | PASS |
| `swift test` | PASS |
| Parallel stability | PASS |
| Golden replay | PASS |
| Golden unchanged | PASS |
| `git diff --check` | PASS |
| Trivy vulnerability/misconfiguration/secret scan | PASS, 0 findings |
