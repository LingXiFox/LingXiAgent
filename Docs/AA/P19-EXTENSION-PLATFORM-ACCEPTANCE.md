# P19 Extension Platform Acceptance

## Deterministic coverage

- `ExtensionPlatformTests/globalProjectSkillsAndCommandsUseProjectPrecedenceWithProvenance`
  - 覆盖 Global/Project Skill 与 Command 发现、确定性排序、Project precedence 和 source provenance。
- `ExtensionPlatformTests/pluginLifecycleIsAtomicAndPersistsStateAcrossRestart`
  - 覆盖 install、enable、disable、update、uninstall、backup 和 restart state restore。
- `ExtensionPlatformTests/incompatiblePluginIsRejectedAndDoesNotReplaceExistingState`
  - 覆盖 schema/Core compatibility fail-closed 和升级前状态不替换。
- `ExtensionPlatformTests/hooksIsolateSuccessFailureAndTimeout`
  - 覆盖结构化 Hook、success、failure、timeout 隔离。
- `ExtensionPlatformTests/undeclaredPluginCapabilityIsDeniedByPermissionEngine`
  - 覆盖未声明 capability 和 Permission Engine 未授权的拒绝路径。
- `ExtensionPlatformTests/mcpStateIsManagedWithoutReplacingMCPRuntime`
  - 覆盖 MCP descriptor 纳管和 enable/disable，不替换既有 MCP Runtime。
- `ExtensionPlatformTests/malformedRegistryIsFailClosedAndOnlyProducesDiagnostics`
  - 覆盖坏扩展不会拖垮 Core，并保留 diagnostics。

## Required gates

| Gate | Result |
| --- | --- |
| `swift build` | PASS |
| `swift test --filter ExtensionPlatformTests` | PASS |
| `swift test --no-parallel` | PASS, 292 tests / 40 suites |
| `swift test` | PASS, 292 tests / 40 suites |
| Parallel stability | PASS |
| Golden replay | PASS, `FullCoreStackV1Tests/fullCoreStackV1` |
| Golden unchanged | PASS |
| `git diff --check` | PASS |
| Trivy vulnerability/misconfiguration/secret scan | PASS, 0 findings |
