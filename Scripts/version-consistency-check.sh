#!/usr/bin/env bash
# ==============================================================================
#  LingXiAgent product version consistency check
#
#  One constant names the binary; one git tag names the release. This script is
#  where the two are forced to agree, so a release cannot ship while the product
#  still reports an older version (which is what happened at v1.1.0).
#
#  Exit codes: 0 in sync (or tag ahead of nothing to compare with), 1 drift.
#  Set ALLOW_VERSION_DRIFT=1 to downgrade a failure to a warning deliberately.
# ==============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

PRODUCT_VERSION_FILE="Sources/LingXiProtocol/ProductVersion.swift"
failures=0
warns=0

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }

CURRENT="$(sed -nE 's/.*static let current = "([^"]+)".*/\1/p' "${PRODUCT_VERSION_FILE}" | head -n1)"
if [ -z "${CURRENT}" ]; then
    echo "cannot read ProductVersion.current from ${PRODUCT_VERSION_FILE}" >&2
    exit 1
fi
printf 'ProductVersion.current = %s\n' "${CURRENT}"

# --- 1. every consumer must reference the constant, never restate it ----------
declare -a MUST_REFERENCE=(
    "Sources/LingXiTUI/CLIParser.swift|ProductVersion.current"
    "Sources/LingXiTUI/CLIParser.swift|ProductVersion.releaseName"
    "Sources/LingXiCore/App/CoreHost.swift|ProductVersion.current"
    "Sources/LingXiProtocol/ACPProtocol.swift|ProductVersion.current"
    "Sources/LingXiProtocol/RuntimeEvents.swift|ProductVersion.current"
    "Sources/LingXiCore/Modules/ACP/LingXiACPServer.swift|ProductVersion.current"
    "Sources/LingXiCore/Modules/Model/OpenAICompatibleProvider.swift|ProductVersion.userAgent"
    "Sources/LingXiCore/Configuration/ClientFingerprint.swift|ProductVersion.userAgent"
)
for spec in "${MUST_REFERENCE[@]}"; do
    file="${spec%%|*}"; needle="${spec##*|}"
    if grep -qF -- "${needle}" "${file}"; then
        ok "$(basename "${file}"): ${needle}"
    else
        fail "${file} 不再引用 ${needle}"
    fi
done

# A literal `LingXiAgent/<digit>` UA anywhere means someone restated the version.
if matches="$(rg -n 'LingXiAgent/[0-9]' Sources Apps --glob '*.swift' 2>/dev/null)"; then
    while IFS= read -r line; do fail "硬编码 UA 版本: ${line}"; done <<< "${matches}"
else
    ok "no hardcoded LingXiAgent/<version> User-Agent literals"
fi

# --- 2. non-Swift copies must carry the same value ---------------------------
SIDECAR_VERSION="$(sed -nE 's/.*"version": "([^"]+)".*/\1/p' Sidecars/browser-host/package.json | head -n1)"
if [ "${SIDECAR_VERSION}" = "${CURRENT}" ]; then
    ok "Sidecars/browser-host/package.json: ${SIDECAR_VERSION}"
else
    fail "browser-host 版本 ${SIDECAR_VERSION} != ${CURRENT}"
fi

if grep -q '__PRODUCT_VERSION__' Scripts/bundle-mac-app.sh \
   && grep -q 'ProductVersion.swift' Scripts/bundle-mac-app.sh; then
    ok "bundle-mac-app.sh 从 ProductVersion 取版本（没有写死）"
else
    fail "bundle-mac-app.sh 应注入 __PRODUCT_VERSION__，不得再硬编码 CFBundleShortVersionString"
fi

# The lockfile and the manifest are read by different tools; both must carry the value.
LOCK_VERSION="$(sed -nE 's/^  "version": "([^"]+)".*/\1/p' Sidecars/browser-host/package-lock.json | head -n1)"
if [ "${LOCK_VERSION}" = "${CURRENT}" ]; then
    ok "Sidecars/browser-host/package-lock.json: ${LOCK_VERSION}"
else
    fail "package-lock.json 版本 ${LOCK_VERSION} != ${CURRENT}"
fi

# The sidecar reports its own version over the wire; a literal there is a second source of truth.
if matches="$(rg -n 'lingxi-browser-host-[0-9]' Sidecars --glob '!node_modules/**' 2>/dev/null)"; then
    while IFS= read -r line; do fail "Sidecar 硬编码 hostVersion: ${line}"; done <<< "${matches}"
else
    ok "browser-host hostVersion 由 package.json 推导"
fi

# Evaluation summaries are stamped with the product version; same rule.
if grep -qF -- 'releaseTag: "v\(ProductVersion.current)"' Evals/Runner/main.swift; then
    ok "Evals Runner 的 releaseTag 由 ProductVersion 推导"
else
    fail "Evals/Runner/main.swift 应写 releaseTag: \"v\\(ProductVersion.current)\"，不得抄死"
fi

for page in Server/agent-site/public/index.html; do
    # 首页的版本槽位是静态 fallback + 运行时由 GitHub API 覆盖，
    # fallback 必须等于常量，否则就是又造了一个会过期的手写版本号。
    if grep -q ">v${CURRENT}<" "${page}"; then
        ok "$(basename "${page}") 的 release fallback 是 v${CURRENT}"
    else
        fail "${page} 的 release fallback 与 ProductVersion.current (v${CURRENT}) 不一致"
    fi
done

# --- 3. README must not carry retired release claims -------------------------
README="README.md"
if [ -f "${README}" ]; then
    for needle in '不发布 Windows 预编译包' '无发布包' '正式支持计划' 'Windows（实验性' 'Windows (实验性'; do
        if grep -qF -- "${needle}" "${README}"; then
            fail "${README} 仍写着已作废的发布口径：${needle}"
        else
            ok "README 无作废发布口径：${needle}"
        fi
    done
    if bad="$(rg -n '^lingxiagent (auth|acp|review|doctor|exec|resume|mcp|skills|models|task|completion)\b' "${README}" 2>/dev/null)"; then
        while IFS= read -r line; do fail "README 把 ops 子命令写成了 lingxiagent：<line>"; done <<< "${bad}"
    else
        ok "README 的 ops 子命令都指向 lingxiagent-ops"
    fi
    if grep -Eq 'lingxifox\.cn/docs["?)[:space:]]' "${README}"; then
        fail "README 混用了 /docs 与 /docs.html 两套链接"
    else
        ok "README 的文档链接是 canonical /docs.html"
    fi
fi

# --- 4. the tag must not have outrun the constant ----------------------------
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
if [ -z "${LATEST_TAG}" ]; then
    warn "没有可达的 git tag，跳过与 tag 的比较"
else
    TAG_VERSION="${LATEST_TAG#v}"; TAG_VERSION="${TAG_VERSION#V}"
    cmp="$(printf '%s\n%s\n' "${CURRENT}" "${TAG_VERSION}" | sort -V | head -n1)"
    if [ "${CURRENT}" = "${TAG_VERSION}" ]; then
        ok "tag ${LATEST_TAG} == ProductVersion.current"
    elif [ "${cmp}" = "${CURRENT}" ]; then
        fail "已发布 ${LATEST_TAG}，但二进制自报 ${CURRENT}：用户会看到旧版本号"
    else
        warn "ProductVersion.current ${CURRENT} 领先于最新 tag ${LATEST_TAG}（发布前正常）"
    fi
fi

echo
if [ "${failures}" -gt 0 ] && [ "${ALLOW_VERSION_DRIFT:-0}" = "1" ]; then
    echo "version drift detected (${failures}), overridden by ALLOW_VERSION_DRIFT=1"
    exit 0
fi
if [ "${failures}" -gt 0 ]; then
    echo "VERSION DRIFT: ${failures} 项不一致（warning ${warns}）"
    echo "发版流程应当是：打 tag 之前先把 ProductVersion.current 改成同一个值。"
    exit 1
fi
echo "product version in sync (${CURRENT}), warnings: ${warns}"
