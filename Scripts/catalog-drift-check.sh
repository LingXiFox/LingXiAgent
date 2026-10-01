#!/usr/bin/env bash
# catalog-drift-check.sh — contract §23: is what is live actually this build?
#
# Read-only. It fetches the published artifacts and compares their digests with
# the repository's. It never writes to a server and never re-deploys anything.
#
# Edge caveat: ESA can inject its RUM script (`rum_common.js`) into HTML on some
# nodes, so a raw byte digest of a live page is not comparable to the repository
# file. The injected tag is stripped before hashing; everything else must match
# exactly, otherwise this reports drift rather than hiding it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGIN="${ORIGIN:-https://models.lingxifox.cn}"
PUBLIC="${REPO_ROOT}/Server/models-site/public"
PYTHON="${PYTHON:-python3}"
fail() { printf 'DRIFT: %s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
WORK_DIR="$(mktemp -d /tmp/lingxi-drift.XXXXXX)"
trap 'rm -Rf "$WORK_DIR"' EXIT

digest() { "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# Removes only what the edge adds; the rest of the document stays byte-exact.
normalize() { "$PYTHON" -c '
import re, sys
body = sys.stdin.buffer.read()
body = re.sub(
    rb"<script src=\"https://[0-9A-Za-z]+\.myalicdn\.com/rum_common\.js\"></script>",
    b"", body)
sys.stdout.buffer.write(body)'; }

fetch() { # fetch <path> <outfile> — retries because nodes are not uniform
    local path="$1" out="$2" attempt
    for attempt in 1 2 3; do
        if curl -fsSL --max-time 60 -o "$out" "${ORIGIN}${path}"; then
            [ "$attempt" -gt 1 ] && printf '  (第 %s 次抓取成功)\n' "$attempt"
            return 0
        fi
        sleep 1
    done
    return 1
}

check_one() { # check_one <path> <repo-file>
    local path="$1" repo="$2" label live repo_hash injected
    label="$(basename "$path")"
    if ! fetch "$path" "${WORK_DIR}/live"; then
        fail "无法读取 ${ORIGIN}${path}（线上不可达或未发布）"
    fi
    if [ ! -f "$repo" ]; then
        printf '  %-16s repo 无此文件，线上 %s\n' "$label" "$(digest < "${WORK_DIR}/live" | cut -c1-12)"
        return 0
    fi
    injected="$(grep -c 'rum_common\.js' "${WORK_DIR}/live" || true)"
    live="$(normalize < "${WORK_DIR}/live" | digest)"
    repo_hash="$(digest < "$repo")"
    if [ "$live" = "$repo_hash" ]; then
        if [ "${injected:-0}" -gt 0 ]; then
            printf '  %-16s 一致 sha256 %s（已忽略边缘注入的监控脚本）\n' "$label" "${live:0:12}"
        else
            printf '  %-16s 一致 sha256 %s\n' "$label" "${live:0:12}"
        fi
    else
        printf '  %-16s 不一致 live %s != repo %s\n' "$label" "${live:0:12}" "${repo_hash:0:12}"
        return 1
    fi
}

printf '检查 %s 与仓库构建物是否同源\n' "$ORIGIN"
status=0
check_one /index.html "$PUBLIC/index.html" || status=1
check_one /models.json "$PUBLIC/models.json" || status=1

# The publication marker names the revision the pipeline last committed to serve.
if fetch /publication.json "${WORK_DIR}/publication.json"; then
    live_revision="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("catalogRevision","-"))' "${WORK_DIR}/publication.json")"
    local_revision="$("$PYTHON" -c "
import json,sys
print(json.load(open(sys.argv[1])).get('catalogRevision','-'))" "$PUBLIC/publication.json" 2>/dev/null || echo '-')"
    if [ "$live_revision" = "$local_revision" ]; then
        printf '  %-16s 一致 revision %s\n' "publication" "$live_revision"
    else
        printf '  %-16s 不一致 live %s != repo %s\n' "publication" "$live_revision" "$local_revision"
        status=1
    fi
else
    printf '  %-16s 线上没有该文件（尚未发布新版）\n' "publication"
fi

[ "$status" -eq 0 ] || fail "线上发布物与仓库构建不一致：请以当前构建重新发布，而不是手工改服务器文件"
printf '线上页面与目录均来自当前仓库构建\n'
