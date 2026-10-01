#!/usr/bin/env bash
# catalog-drift-check.sh — contract §23: is what is live actually this build?
#
# Read-only. It fetches the published artifacts and compares their digests with
# the repository's. It never writes to a server and never re-deploys anything.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGIN="${ORIGIN:-https://models.lingxifox.cn}"
PUBLIC="${REPO_ROOT}/Server/models-site/public"
PYTHON="${PYTHON:-python3}"
fail() { printf 'DRIFT: %s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
digest() { "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

check_one() { # check_one <path> <repo-file>
    local path="$1" repo="$2" label
    label="$(basename "$path")"
    local live repo_hash
    if ! live="$(curl -fsSL --max-time 60 "${ORIGIN}${path}" | digest)"; then
        fail "无法读取 ${ORIGIN}${path}（线上不可达或未发布）"
    fi
    if [ ! -f "$repo" ]; then
        printf '  %-16s repo 无此文件，线上 %s\n' "$label" "${live:0:12}"
        return 0
    fi
    repo_hash="$(digest < "$repo")"
    if [ "$live" = "$repo_hash" ]; then
        printf '  %-16s 一致 sha256 %s\n' "$label" "${live:0:12}"
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
if marker="$(curl -fsSL --max-time 30 "${ORIGIN}/publication.json" 2>/dev/null)"; then
    live_revision="$(printf '%s' "$marker" | "$PYTHON" -c 'import json,sys;print(json.load(sys.stdin).get("catalogRevision","-"))')"
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
    printf '  %-16s 线上没有该文件（旧发布物，尚未带发布标记）\n' "publication"
fi

[ "$status" -eq 0 ] || fail "线上发布物与仓库构建不一致：请以当前构建重新发布，而不是手工改服务器文件"
printf '线上页面与目录均来自当前仓库构建\n'
