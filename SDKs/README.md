# LingXi SDK Workspace

This directory is the local development workspace for LingXi's public Swift SDKs.
Each subdirectory is a **separate Git repository**, deliberately ignored by the
LingXiAgent repository:

| Directory | Repository | License | Purpose |
| --- | --- | --- | --- |
| `LingXiModelSDK/` | <https://github.com/LingXiFox/LingXiModelSDK> | MIT | Model catalog: lookup, capabilities, pricing, limits |
| `LingXiPluginSDK/` | <https://github.com/LingXiFox/LingXiPluginSDK> | MIT | Plugin authoring: manifest, tools, commands, hooks, IPC |

This is not a submodule, not a subtree vendor and not a monorepo package. Three
independent repositories happen to sit in one folder so an editor can open the
whole LingXi surface at once.

## What the main repository actually builds against

`LingXiAgent/Package.swift` consumes both SDKs through their **public GitHub
packages**, exactly as a third party does:

```swift
.package(url: "https://github.com/LingXiFox/LingXiModelSDK.git", from: "0.1.0"),
.package(url: "https://github.com/LingXiFox/LingXiPluginSDK.git", from: "0.1.0")
```

Production builds therefore never read the checkouts in this directory. The
agent is its own first consumer: if `0.1.x` could not be resolved from GitHub,
that is evidence the SDKs are not yet fit to publish to third parties, and the
build fails here rather than on someone else's machine.

`PublicSDKConsumerGateTests` enforces that: no local copy, no committed `path:`
dependency, and the model site advertises the same package URL and minimum
version the manifest requires.

## Editing an SDK alongside the agent

For joint work, use SwiftPM's editable-checkout mechanism — it is local state
and is not committed:

```bash
swift package edit LingXiModelSDK --path SDKs/LingXiModelSDK
swift package edit LingXiPluginSDK --path SDKs/LingXiPluginSDK

# …build and test against the working copies…

swift package unedit LingXiModelSDK
swift package unedit LingXiPluginSDK
swift package update
```

Never point `Package.swift` at `SDKs/…` in a commit: that silently turns the
public distribution path off, and the main repository stops validating it.

## Commits live in their own repository

`git status` in `LingXiAgent` will never show SDK source changes, because those
paths are ignored. Commit each repository separately:

```bash
git -C SDKs/LingXiModelSDK  commit -am "…"
git -C SDKs/LingXiPluginSDK commit -am "…"
git -C .                    commit -am "…"   # LingXiAgent itself
```

A `git add -A` at the repository root does **not** stage the SDKs, and must not
be assumed to have.

## Release order when an SDK gains an API

```text
land and test in the SDK repository
→ tag a release (0.1.x, 0.2.0, …)
→ then raise the minimum version in LingXiAgent/Package.swift
```

An API that has not been published cannot be used by the agent first. That
keeps "the SDK LingXiAgent builds against" identical to "the SDK a third party
can download".
